-- BizPilot setup PART 18 of 20. Run parts in order.
begin;
create or replace function public.market_order_report_payment(p_order uuid, p_token text, p_reference text)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; ref text := nullif(left(btrim(coalesce(p_reference, '')), 120), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if o.payment_method <> 'momo_direct' or o.payment_status <> 'cod_pending'
     or o.status not in ('pending', 'confirmed', 'processing', 'dispatched') then
    perform app.raise('invalid_order_status');
  end if;
  if ref is null or length(ref) < 4 then perform app.raise('reference_required'); end if;
  update public.market_orders set buyer_payment_ref = ref, buyer_payment_reported_at = now() where id = o.id;
  insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
  values (o.id, o.business_id, 'payment', 'reported: ' || ref, 'customer', auth.uid());
  insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
  values (o.business_id, 'market_payment_reported', 'warning', jsonb_build_object('number', o.number, 'amount', o.total),
          '/app/orders/' || o.id, 'orders.manage', 'payment_reported:' || o.id || ':' || ref) on conflict do nothing;
end $$;
create or replace function public.market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
  reason text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), ''); sid uuid; rid uuid;
  goods numeric; refund numeric; method text := coalesce(p ->> 'method', p ->> 'cod_method', '');
  ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
begin
  select * into o from public.market_orders where id = p_order for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(o.business_id, 'orders.manage');
  if p_action = 'confirm' then
    if o.status <> 'pending' then perform app.raise('invalid_order_status'); end if;
    if o.payment_method = 'online' and o.payment_status <> 'paid' then perform app.raise('order_not_paid'); end if;
    update public.market_orders set status = 'confirmed', confirmed_at = now(), expires_at = null where id = o.id;
    update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
  elsif p_action = 'processing' then
    if o.status <> 'confirmed' then perform app.raise('invalid_order_status'); end if;
    update public.market_orders set status = 'processing' where id = o.id;
  elsif p_action = 'dispatch' then
    if o.status not in ('confirmed', 'processing') then perform app.raise('invalid_order_status'); end if;
    update public.market_orders set status = 'dispatched', dispatched_at = now() where id = o.id;
  elsif p_action = 'payment_received' then
    if o.payment_method not in ('cod', 'momo_direct') or o.payment_status <> 'cod_pending'
       or o.status not in ('pending', 'confirmed', 'processing', 'dispatched') then
      perform app.raise('invalid_order_status');
    end if;
    if method not in ('cash', 'mtn_momo', 'orange_money') then perform app.raise('payment_method_required'); end if;
    update public.market_orders set payment_status = 'seller_confirmed', cod_method = method, cod_collected_amount = o.total,
           payment_confirmed_at = now(), payment_confirmed_by = auth.uid(), payment_reference = coalesce(ref, o.buyer_payment_ref)
     where id = o.id;
  elsif p_action = 'deliver' then
    if o.status not in ('confirmed', 'processing', 'dispatched') then perform app.raise('invalid_order_status'); end if;
    if o.payment_method in ('cod', 'momo_direct') then
      if o.payment_status = 'seller_confirmed' then method := o.cod_method; end if;
      if method not in ('cash', 'mtn_momo', 'orange_money') then perform app.raise('payment_method_required'); end if;
      sid := app.market_order_to_sale(o.id, method, coalesce(ref, o.payment_reference, o.buyer_payment_ref, 'Order ' || o.number));
      if o.delivery_fee > 0 then
        insert into public.cash_movements (business_id, kind, to_account_id, amount, note, client_ref, created_by)
        values (o.business_id, 'deposit', app.account_for_method(o.business_id, method), o.delivery_fee,
                'Delivery fee ' || o.number, null, auth.uid());
      end if;
      update public.market_orders set payment_status = 'cod_collected', cod_collected_amount = o.total, cod_method = method,
             cod_collected_at = coalesce(payment_confirmed_at, now()), cod_collected_by = coalesce(payment_confirmed_by, auth.uid()),
             payment_confirmed_at = coalesce(payment_confirmed_at, now()), payment_confirmed_by = coalesce(payment_confirmed_by, auth.uid()),
             payment_reference = coalesce(payment_reference, ref)
       where id = o.id;
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', -o.commission_amount, 'Commission ' || o.number, auth.uid());
      end if;
    else
      if o.payment_status <> 'paid' then perform app.raise('order_not_paid'); end if;
      sid := app.market_order_to_sale(o.id, 'other', 'BizPilot Market ' || o.number);
      insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
      values (o.business_id, o.id, 'order_payment', o.total, 'Online payment ' || o.number, auth.uid());
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', -o.commission_amount, 'Commission ' || o.number, auth.uid());
      end if;
      if o.online_fee_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'processing_fee', -o.online_fee_amount, 'Payment processing ' || o.number, auth.uid());
      end if;
    end if;
    update public.market_orders set status = 'delivered', delivered_at = now(), delivered_by = auth.uid(), sale_id = sid,
           delivery_proof_note = nullif(left(btrim(coalesce(p ->> 'proof_note', '')), 300), ''),
           delivery_proof_path = case when split_part(coalesce(p ->> 'proof_path', ''), '/', 1) = o.business_id::text then p ->> 'proof_path' end,
           received_by = nullif(left(btrim(coalesce(p ->> 'received_by', '')), 80), ''), expires_at = null
     where id = o.id;
  elsif p_action in ('reject', 'cancel') then
    if reason is null then perform app.raise('reason_required'); end if;
    if o.payment_status = 'seller_confirmed' then
      update public.market_orders set payment_status = 'refund_pending' where id = o.id;
    end if;
    perform app.market_cancel(o.id, 'seller', reason);
  elsif p_action = 'refunded' then
    if o.status <> 'cancelled' or o.payment_status <> 'refund_pending' or o.payment_method = 'online' then
      perform app.raise('invalid_order_status');
    end if;
    update public.market_orders set payment_status = 'refunded', refunded_at = now(), refund_amount = o.total,
           refund_reference = coalesce(ref, 'Refund ' || o.number) where id = o.id;
  elsif p_action = 'refund' then
    if o.status <> 'delivered' then perform app.raise('invalid_order_status'); end if;
    if reason is null then perform app.raise('reason_required'); end if;
    perform app.require_perm(o.business_id, 'sales.refund');
    goods := (select total - returned_total from public.sales where id = o.sale_id);
    refund := goods;
    rid := public.create_sale_return(o.sale_id, jsonb_build_object('reason', reason,
      'restock', coalesce((p ->> 'restock')::boolean, true),
      'lines', (select jsonb_agg(jsonb_build_object('sale_line_id', sl.id, 'base_quantity', sl.base_quantity - sl.returned_base_qty))
                  from public.sale_lines sl where sl.sale_id = o.sale_id and sl.base_quantity > sl.returned_base_qty),
      'refund', jsonb_build_object('amount', refund, 'method', case when o.payment_method = 'online' then 'other' else o.cod_method end,
                                   'reference', 'Refund ' || o.number)));
    if o.payment_method = 'online' then
      insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
      values (o.business_id, o.id, 'refund', -(refund + o.delivery_fee) + o.commission_amount + o.online_fee_amount,
              'Refund ' || o.number, auth.uid());
      update public.market_orders set status = 'refunded', payment_status = 'refund_pending', refund_amount = refund + o.delivery_fee,
             flagged = true, flag_reason = 'refund_after_delivery' where id = o.id;
    else
      if o.commission_amount > 0 then
        insert into public.market_ledger (business_id, order_id, kind, amount, note, created_by)
        values (o.business_id, o.id, 'commission', o.commission_amount, 'Commission reversed ' || o.number, auth.uid());
      end if;
      update public.market_orders set status = 'refunded', payment_status = 'refunded', refund_amount = refund,
             refunded_at = now(), refund_reference = 'Refund ' || o.number where id = o.id;
    end if;
  elsif p_action in ('message', 'note') then
    if msg is null then perform app.raise('message_required'); end if;
  else
    perform app.raise('invalid_action');
  end if;
  if p_action in ('message', 'note') then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user, visible_to_customer)
    values (o.id, o.business_id, p_action, msg, 'seller', auth.uid(), p_action = 'message');
  elsif p_action = 'payment_received' then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'payment', 'confirmed: ' || method, 'seller', auth.uid());
  elsif p_action not in ('reject', 'cancel') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'status', (select status from public.market_orders where id = o.id), coalesce(msg, reason), 'seller', auth.uid());
  end if;
  perform app.audit(o.business_id, 'order.' || p_action, 'market_order', o.id::text,
                    jsonb_build_object('number', o.number, 'reason', reason, 'method', nullif(method, '')));
  return (select to_jsonb(x) from public.market_orders x where x.id = o.id);
end $$;
create or replace function public.market_order_view(p_order uuid, p_token text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; s public.stores;
begin
  perform app.market_expire();
  o := app.order_for_customer(p_order, p_token);
  select * into s from public.stores where business_id = o.business_id;
  return jsonb_build_object(
    'id', o.id, 'number', o.number, 'status', o.status, 'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'created_at', o.created_at, 'confirmed_at', o.confirmed_at, 'dispatched_at', o.dispatched_at, 'delivered_at', o.delivered_at,
    'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason, 'cancelled_by', o.cancelled_by,
    'expires_at', case when o.status = 'pending' then o.expires_at end,
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_email', o.customer_email,
    'delivery_method', o.delivery_method, 'zone_name', o.zone_name, 'delivery_eta', o.delivery_eta, 'address', o.address,
    'notes', o.notes, 'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
    'currency', o.currency, 'promo_code', o.promo_code, 'refund_amount', o.refund_amount, 'refunded_at', o.refunded_at,
    'buyer_payment_ref', o.buyer_payment_ref, 'buyer_payment_reported_at', o.buyer_payment_reported_at,
    'payment_confirmed_at', o.payment_confirmed_at, 'paid_with', o.cod_method,
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path, 'city', s.city,
       'phone', case when s.show_phone then s.phone end, 'whatsapp', case when s.show_whatsapp then s.whatsapp end,
       'email', case when s.show_email then s.email end,
       'address', case when o.delivery_method = 'pickup' or s.show_address then s.address end,
       'pickup_note', case when o.delivery_method = 'pickup' then s.pickup_note end,
       'return_policy', s.return_policy,
       'momo', case when o.payment_method = 'momo_direct' then jsonb_build_object(
          'mtn_number', s.momo_mtn_number, 'mtn_name', s.momo_mtn_name,
          'orange_number', s.momo_orange_number, 'orange_name', s.momo_orange_name, 'note', s.payment_note) end),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'listing_id', l.listing_id, 'name', l.name,
       'variant_label', l.variant_label, 'image_path', l.image_path, 'unit_price', l.unit_price, 'quantity', l.quantity,
       'line_total', l.line_total,
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending' and o.payment_status <> 'seller_confirmed',
    'can_pay', false,
    'can_report_payment', o.payment_method = 'momo_direct' and o.payment_status = 'cod_pending'
       and o.status in ('pending', 'confirmed', 'processing', 'dispatched'),
    'can_review', o.status = 'delivered',
    'signed_in_owner', auth.uid() is not null and o.customer_user_id = auth.uid());
end $$;
create or replace function public.market_order_customer_action(p_order uuid, p_token text, p_action text, p_text text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p_text, '')), 1000), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if p_action = 'cancel' then
    if o.status <> 'pending' or o.payment_status = 'seller_confirmed' then perform app.raise('order_not_cancellable'); end if;
    perform app.market_cancel(o.id, 'customer', coalesce(msg, 'cancelled_by_customer'));
  elsif p_action = 'message' then
    if msg is null then perform app.raise('message_required'); end if;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'message', msg, 'customer', auth.uid());
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (o.business_id, 'market_message', 'info', jsonb_build_object('number', o.number), '/app/orders/' || o.id,
            'orders.manage', 'market_message:' || o.id || ':' || date_trunc('hour', now())) on conflict do nothing;
  else
    perform app.raise('invalid_action');
  end if;
end $$;
create or replace function app.product_card(p_listing uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', p.id, 'name', p.name, 'brand', p.brand,
    'image', p.online_images[1], 'unit', p.base_unit,
    'price', o.min_price, 'max_price', o.max_price, 'compare_at_price',
      case when p.compare_at_price > o.min_price then p.compare_at_price end,
    'available', least(o.available, 99), 'options', o.n,
    'category', c.name, 'subcategory', p.subcategory,
    'condition', p.condition, 'sold', p.single_item and coalesce(o.available, 0) <= 0,
    'rating_avg', r.avg, 'rating_count', coalesce(r.n, 0),
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'city', s.city, 'verified', s.verification = 'verified',
                                'logo_path', s.logo_path))
  from public.products p
  join public.stores s on s.business_id = p.business_id
  left join public.categories c on c.id = p.category_id
  cross join lateral (select min(x.price) min_price, max(x.price) max_price, sum(x.available) available, count(*) n
                        from app.listing_options(p.id) x) o
  left join lateral (select round(avg(rating), 1) avg, count(*) n from public.market_reviews
                      where listing_id = p.id and status = 'visible') r on true
  where p.id = p_listing
$$;
create or replace function public.market_search(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  v_type text := nullif(p ->> 'type', '');
  v_cat text := nullif(btrim(coalesce(p ->> 'category', '')), '');
  v_store text := nullif(lower(p ->> 'store'), '');
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  minp numeric := nullif(p ->> 'min_price', '')::numeric;
  maxp numeric := nullif(p ->> 'max_price', '')::numeric;
  minr numeric := nullif(p ->> 'min_rating', '')::numeric;
  instock boolean := coalesce((p ->> 'in_stock')::boolean, false);
  v_delivery boolean := coalesce((p ->> 'delivery')::boolean, false);
  v_cond text := nullif(p ->> 'condition', '');
  v_sort text := coalesce(nullif(p ->> 'sort', ''), 'relevance');
  size int := least(greatest(coalesce((p ->> 'page_size')::int, 24), 1), 60);
  pg int := greatest(coalesce((p ->> 'page')::int, 1), 1);
  res jsonb;
begin
  if q is not null and length(q) > 80 then q := left(q, 80); end if;
  with base as (
    select pr.id, pr.name, pr.online_since, o.min_price, o.available,
           coalesce(r.avg, 0) rating,
           case when q is null then 0
                when lower(pr.name) = lower(q) then 3
                when pr.name ilike app.like_term(q) then 2 else 1 end rel
      from public.products pr
      join public.stores s on s.business_id = pr.business_id and s.status = 'published'
      join public.businesses b on b.id = pr.business_id and b.status = 'active'
      left join public.categories c on c.id = pr.category_id
      cross join lateral (select min(x.price) min_price, sum(x.available) available from app.listing_options(pr.id) x) o
      left join lateral (select avg(rating) avg from public.market_reviews mr where mr.listing_id = pr.id and mr.status = 'visible') r on true
     where pr.online_published and pr.status = 'active' and not pr.admin_hidden and pr.variant_of is null
       and app.listing_within_limit(pr.business_id, pr.online_since, pr.id)
       and not (pr.single_item and coalesce(o.available, 0) <= 0)
       and (q is null or pr.name ilike app.like_term(q) or pr.brand ilike app.like_term(q)
            or pr.description ilike app.like_term(q) or c.name ilike app.like_term(q)
            or pr.subcategory ilike app.like_term(q) or s.name ilike app.like_term(q))
       and (v_type is null or b.category = v_type)
       and (v_cat is null or lower(c.name) = lower(v_cat) or lower(pr.subcategory) = lower(v_cat))
       and (v_store is null or lower(s.slug) = v_store)
       and (v_city is null or s.city ilike app.like_term(v_city) or s.region ilike app.like_term(v_city)
            or s.neighborhood ilike app.like_term(v_city))
       and (minp is null or o.min_price >= minp)
       and (maxp is null or o.min_price <= maxp)
       and (minr is null or coalesce(r.avg, 0) >= minr)
       and (not instock or o.available > 0)
       and (not v_delivery or exists (select 1 from public.store_delivery_zones z where z.business_id = s.business_id and z.active))
       and (v_cond is null or pr.condition = v_cond)
  ), ranked as (
    select id, row_number() over (
             order by case when v_sort = 'relevance' then rel end desc nulls last,
                      case when v_sort = 'price_asc' then min_price end asc nulls last,
                      case when v_sort = 'price_desc' then min_price end desc nulls last,
                      case when v_sort = 'rating' then rating end desc nulls last,
                      case when v_sort = 'newest' then online_since end desc nulls last,
                      (available > 0) desc, online_since desc, id) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base),
    'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.product_card(r.id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;
create or replace function public.market_product(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr public.products; lid uuid; words text[]; term text;
begin
  lid := app.listing_of(p_id);
  if lid is null then return null; end if;
  select * into pr from public.products where id = lid;
  words := array(select w from regexp_split_to_table(lower(pr.name), '[^[:alnum:]]+') w where length(w) >= 2 limit 2);
  term := array_to_string(words, '%');
  return app.product_card(lid) || jsonb_build_object(
    'description', pr.description, 'images', to_jsonb(pr.online_images), 'attributes', pr.attributes,
    'business_type', (select category from public.businesses where id = pr.business_id),
    'store_id', pr.business_id, 'single_item', pr.single_item,
    'options', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label, 'price', o.price,
                          'compare_at_price', case when o.compare_at > o.price then o.compare_at end,
                          'available', least(o.available, 99), 'attributes', o.attributes, 'allow_fraction', o.allow_fraction)
                          order by o.label nulls first) from app.listing_options(lid) o), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                          'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                         from (select * from public.market_reviews where listing_id = lid and status = 'visible'
                                order by created_at desc limit 20) r), '[]'::jsonb),
    'related', coalesce((select jsonb_agg(app.product_card(x.id)) from (
                          select p2.id from public.products p2 where p2.business_id = pr.business_id and p2.id <> lid
                             and p2.online_published and p2.status = 'active' and not p2.admin_hidden and p2.variant_of is null
                           order by (p2.category_id is not distinct from pr.category_id) desc, p2.online_since desc limit 8) x), '[]'::jsonb),
    'other_sellers', case when coalesce(term, '') = '' then '[]'::jsonb else coalesce((select jsonb_agg(app.product_card(x.id) order by x.price) from (
                          select p3.id, (select min(o.price) from app.listing_options(p3.id) o) price
                            from public.products p3 join public.stores s3 on s3.business_id = p3.business_id and s3.status = 'published'
                            join public.businesses b3 on b3.id = p3.business_id and b3.status = 'active'
                           where p3.business_id <> pr.business_id and p3.online_published and p3.status = 'active'
                             and not p3.admin_hidden and p3.variant_of is null
                             and app.listing_within_limit(p3.business_id, p3.online_since, p3.id)
                             and lower(p3.name) like '%' || term || '%'
                           limit 12) x), '[]'::jsonb) end);
end $$;
create or replace function public.market_store(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; b public.businesses; custom boolean;
begin
  select * into s from public.stores where lower(slug) = lower(btrim(p_slug));
  if not found then return null; end if;
  select * into b from public.businesses where id = s.business_id;
  if s.status <> 'published' or b.status <> 'active' then
    return jsonb_build_object('slug', s.slug, 'name', s.name, 'unavailable', true);
  end if;
  custom := app.has_feature(s.business_id, 'store_customization');
  return jsonb_build_object(
    'business_id', s.business_id, 'slug', s.slug, 'name', s.name, 'tagline', s.tagline, 'description', s.description,
    'logo_path', s.logo_path, 'cover_path', case when custom then s.cover_path end,
    'brand_color', case when custom then s.brand_color end,
    'business_type', b.category, 'city', s.city, 'region', s.region, 'neighborhood', s.neighborhood, 'service_area', s.service_area,
    'address', case when s.show_address then s.address end,
    'phone', case when s.show_phone then s.phone end,
    'whatsapp', case when s.show_whatsapp then s.whatsapp end,
    'email', case when s.show_email then s.email end,
    'facebook_url', s.facebook_url, 'instagram_url', s.instagram_url, 'tiktok_url', s.tiktok_url,
    'opening_hours', s.opening_hours, 'hours_note', s.hours_note, 'delivery_note', s.delivery_note,
    'pickup_enabled', s.pickup_enabled, 'pickup_note', s.pickup_note, 'cod_enabled', s.cod_enabled,
    'online_payment_enabled', false,
    'momo_direct_enabled', s.momo_direct_enabled and coalesce(s.momo_mtn_number, s.momo_orange_number) is not null,
    'momo_networks', array_remove(array[case when s.momo_direct_enabled and s.momo_mtn_number is not null then 'mtn' end,
                                        case when s.momo_direct_enabled and s.momo_orange_number is not null then 'orange' end], null),
    'payment_note', s.payment_note, 'return_policy', s.return_policy,
    'min_order_amount', s.min_order_amount, 'currency', b.currency,
    'verified', s.verification = 'verified', 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
    'joined', s.published_at,
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'eta', z.eta) order by z.sort, z.name)
                       from public.store_delivery_zones z where z.business_id = s.business_id and z.active), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', t.name, 'products', t.n) order by t.sort, t.name) from (
                     select c.name, min(c.sort_order) sort, count(*) n from public.products pr join public.categories c on c.id = pr.category_id
                      where pr.business_id = s.business_id and pr.online_published and pr.status = 'active' and not pr.admin_hidden
                        and pr.variant_of is null group by c.name) t), '[]'::jsonb),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('rating', r.rating, 'comment', r.comment, 'author', r.author_name,
                     'product', pr.name, 'reply', r.seller_reply, 'created_at', r.created_at) order by r.created_at desc)
                   from (select * from public.market_reviews where business_id = s.business_id and status = 'visible'
                          order by created_at desc limit 10) r join public.products pr on pr.id = r.product_id), '[]'::jsonb));
end $$;
commit;
