-- BizPilot setup PART 13 of 23. Run parts in order.
begin;
create or replace function public.market_product(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pr public.products; lid uuid;
begin
  lid := app.listing_of(p_id);
  if lid is null then return null; end if;
  select * into pr from public.products where id = lid;
  return app.product_card(lid) || jsonb_build_object(
    'description', pr.description, 'images', to_jsonb(pr.online_images), 'attributes', pr.attributes,
    'business_type', (select category from public.businesses where id = pr.business_id),
    'store_id', pr.business_id,
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
                           order by (p2.category_id is not distinct from pr.category_id) desc, p2.online_since desc limit 8) x), '[]'::jsonb));
end $$;
create or replace function public.market_products_by_ids(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(app.product_card(x)), '[]'::jsonb)
    from (select distinct app.listing_of(i) x from unnest(p_ids[1:100]) i) t where x is not null
$$;
create or replace function public.market_store_cards(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(app.store_card(i)), '[]'::jsonb) from unnest(p_ids[1:100]) i where app.store_is_live(i)
$$;
create or replace function app.market_price(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  it jsonb; pr public.products; lst public.products; s public.stores; bid uuid; lid uuid;
  qty numeric; avail numeric; price numeric; lines jsonb := '[]'::jsonb; errs jsonb := '[]'::jsonb;
  sub numeric := 0; disc numeric := 0; fee numeric := 0; z public.store_delivery_zones; pm public.market_promotions;
  method text := coalesce(nullif(p ->> 'delivery_method', ''), 'delivery'); v_code text; n int := 0;
  merged jsonb;
begin
  if jsonb_typeof(p -> 'items') <> 'array' or jsonb_array_length(p -> 'items') = 0 then
    return jsonb_build_object('errors', jsonb_build_array(jsonb_build_object('code', 'cart_empty')));
  end if;
  if jsonb_array_length(p -> 'items') > 50 then perform app.raise('too_many_items'); end if;
  select jsonb_agg(jsonb_build_object('product_id', pid, 'quantity', q)) into merged from (
    select (x ->> 'product_id')::uuid pid, sum(coalesce((x ->> 'quantity')::numeric, 0)) q
      from jsonb_array_elements(p -> 'items') x group by 1 order by 1) t;
  for it in select * from jsonb_array_elements(merged) loop
    n := n + 1;
    select * into pr from public.products where id = (it ->> 'product_id')::uuid;
    lid := app.listing_of(pr.id);
    if pr.id is null or lid is null then
      errs := errs || jsonb_build_object('code', 'product_unavailable', 'product_id', it ->> 'product_id');
      continue;
    end if;
    if bid is null then bid := pr.business_id;
    elsif bid <> pr.business_id then perform app.raise('one_seller_per_order'); end if;
    if exists (select 1 from public.products c where c.variant_of = pr.id and c.status = 'active' and not c.admin_hidden) then
      errs := errs || jsonb_build_object('code', 'choose_option', 'product_id', pr.id, 'name', pr.name);
      continue;
    end if;
    select * into lst from public.products where id = lid;
    qty := (it ->> 'quantity')::numeric;
    if qty is null or qty <= 0 or qty > 999 or (not pr.allow_fraction and qty <> trunc(qty)) then
      errs := errs || jsonb_build_object('code', 'invalid_quantity', 'product_id', pr.id, 'name', pr.name);
      continue;
    end if;
    avail := greatest(pr.qty_on_hand - app.reserved_qty(pr.id), 0);
    if qty > avail then
      errs := errs || jsonb_build_object('code', 'insufficient_stock', 'product_id', pr.id, 'name', pr.name,
                                         'available', avail);
    end if;
    price := pr.selling_price;
    lines := lines || jsonb_build_object('product_id', pr.id, 'listing_id', lid, 'name', lst.name,
      'variant_label', case when pr.id <> lid then coalesce(pr.variant_label, pr.name) end, 'sku', pr.sku,
      'image_path', coalesce(pr.online_images[1], lst.online_images[1]), 'unit_price', price, 'quantity', qty,
      'unit', pr.base_unit, 'available', avail, 'line_total', app.money(pr.business_id, qty * price), 'sort', n);
    sub := sub + app.money(pr.business_id, qty * price);
  end loop;
  if bid is null then
    return jsonb_build_object('lines', lines, 'errors', errs);
  end if;
  select * into s from public.stores where business_id = bid;
  if method = 'pickup' then
    if not s.pickup_enabled then errs := errs || jsonb_build_object('code', 'pickup_not_available'); end if;
  elsif method = 'delivery' then
    if nullif(p ->> 'zone_id', '') is null then
      if exists (select 1 from public.store_delivery_zones where business_id = bid and active) then
        errs := errs || jsonb_build_object('code', 'zone_required');
      else
        errs := errs || jsonb_build_object('code', 'delivery_not_available');
      end if;
    else
      select * into z from public.store_delivery_zones where id = (p ->> 'zone_id')::uuid and business_id = bid and active;
      if not found then errs := errs || jsonb_build_object('code', 'zone_required');
      else fee := z.fee; end if;
    end if;
  else
    errs := errs || jsonb_build_object('code', 'invalid_delivery_method');
  end if;
  v_code := upper(nullif(btrim(coalesce(p ->> 'promo_code', '')), ''));
  if v_code is not null then
    select * into pm from public.market_promotions
     where business_id = bid and code = v_code and active
       and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())
       and (max_uses is null or used_count < max_uses);
    if not found or not app.has_feature(bid, 'promotions') then
      errs := errs || jsonb_build_object('code', 'promo_invalid');
    elsif sub < pm.min_order then
      errs := errs || jsonb_build_object('code', 'promo_min_order', 'min_order', pm.min_order);
    else
      disc := case when pm.kind = 'percent' then app.money(bid, sub * pm.value / 100) else least(pm.value, sub) end;
    end if;
  end if;
  if sub < s.min_order_amount then
    errs := errs || jsonb_build_object('code', 'below_minimum_order', 'min_order', s.min_order_amount);
  end if;
  return jsonb_build_object('business_id', bid, 'store', app.store_card(bid), 'lines', lines,
    'subtotal', sub, 'discount', disc, 'delivery_fee', fee, 'total', sub - disc + fee,
    'promo_id', pm.id, 'promo_code', pm.code, 'zone_name', z.name, 'delivery_eta', z.eta,
    'delivery_method', method, 'errors', errs);
end $$;
create or replace function public.market_quote(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return app.market_price(p);
end $$;
create or replace function app.market_cancel(p_order uuid, p_actor text, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.market_orders;
begin
  select * into o from public.market_orders where id = p_order for update;
  if o.status not in ('pending', 'confirmed', 'processing', 'dispatched') then perform app.raise('order_not_cancellable'); end if;
  update public.stock_reservations set released_at = now()
   where order_id = o.id and released_at is null and consumed_at is null;
  if o.promo_id is not null then
    update public.market_promotions set used_count = greatest(used_count - 1, 0) where id = o.promo_id;
  end if;
  update public.market_orders set status = 'cancelled', cancelled_at = now(), cancelled_by = p_actor,
         cancel_reason = p_reason, expires_at = null,
         payment_status = case when payment_status = 'paid' then 'refund_pending'
                               when payment_status in ('awaiting_payment', 'failed', 'cod_pending') then 'void'
                               else payment_status end,
         flagged = flagged or payment_status = 'paid',
         flag_reason = case when payment_status = 'paid' then 'refund_after_cancellation' else flag_reason end
   where id = o.id;
  insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
  values (o.id, o.business_id, 'status', 'cancelled', p_reason, p_actor, auth.uid());
  if p_actor <> 'seller' and not (o.payment_method = 'online' and o.payment_status <> 'paid') then
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_order_cancelled', 'warning',
            jsonb_build_object('number', o.number, 'reason', p_reason), '/app/orders/' || o.id, 'orders.manage');
  end if;
end $$;
create or replace function app.market_expire() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select id, payment_method from public.market_orders
            where status = 'pending' and expires_at < now()
              and payment_status in ('awaiting_payment', 'failed', 'cod_pending')
            order by expires_at limit 50 for update skip locked loop
    perform app.market_cancel(r.id, 'system',
      case when r.payment_method = 'online' then 'payment_not_completed' else 'not_confirmed_in_time' end);
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.market_place_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); cfg jsonb := app.market_config(); q jsonb; e jsonb; s public.stores; b public.businesses;
  cref uuid := nullif(p ->> 'client_ref', '')::uuid; tok text := nullif(p ->> 'access_token', '');
  existing public.market_orders; oid uuid; num text; cname text; cphone text; cemail text; addr jsonb;
  pay text := p ->> 'payment_method'; cid uuid; l jsonb; exp timestamptz; comm numeric; fee numeric;
begin
  if cref is null then perform app.raise('invalid_request'); end if;
  if uid is null and (tok is null or length(tok) < 32 or length(tok) > 128) then perform app.raise('invalid_request'); end if;
  select * into existing from public.market_orders where client_ref = cref;
  if found then
    if existing.customer_user_id is distinct from uid and existing.access_token_hash is distinct from app.sha256(coalesce(tok, '')) then
      perform app.raise('invalid_request');
    end if;
    return jsonb_build_object('order_id', existing.id, 'number', existing.number, 'total', existing.total,
      'payment_method', existing.payment_method, 'payment_status', existing.payment_status, 'duplicate', true);
  end if;
  if not coalesce((cfg ->> 'enabled')::boolean, true) then perform app.raise('marketplace_closed'); end if;
  perform app.rate_limit('order_ip:' || app.client_ip(), 120, 3600);
  if uid is not null then perform app.rate_limit('order_user:' || uid, 20, 3600); end if;
  perform app.market_expire();
  cname := btrim(coalesce(p #>> '{customer,name}', ''));
  cphone := app.norm_phone(p #>> '{customer,phone}');
  cemail := nullif(lower(btrim(coalesce(p #>> '{customer,email}', ''))), '');
  if length(cname) < 2 or length(cname) > 80 then perform app.raise('customer_name_required'); end if;
  if cphone is null then perform app.raise('invalid_phone'); end if;
  perform app.rate_limit('order_phone:' || cphone, 10, 3600);
  if cemail is not null and not app.valid_email(cemail) then perform app.raise('invalid_email'); end if;
  if exists (select 1 from public.market_blocklist where (kind = 'phone' and value = cphone)
             or (kind = 'email' and value = cemail) or (kind = 'user' and value = uid::text)) then
    perform app.raise('checkout_blocked');
  end if;
  if pay not in ('cod', 'online') then perform app.raise('invalid_payment_method'); end if;
  perform 1 from public.products where id in (select (x ->> 'product_id')::uuid from jsonb_array_elements(p -> 'items') x)
   order by id for update;
  q := app.market_price(p);
  if uid is not null and nullif(q ->> 'business_id', '') is not null and app.is_member((q ->> 'business_id')::uuid) then
    perform app.raise('cannot_order_from_own_store');
  end if;
  if jsonb_array_length(q -> 'errors') > 0 then
    perform app.raise('checkout_invalid', jsonb_build_object('errors', q -> 'errors'));
  end if;
  select * into s from public.stores where business_id = (q ->> 'business_id')::uuid;
  select * into b from public.businesses where id = s.business_id;
  if pay = 'cod' then
    if not s.cod_enabled then perform app.raise('payment_method_not_available'); end if;
    if (select count(*) from public.market_orders where business_id = s.business_id and customer_phone = cphone
         and payment_method = 'cod' and status in ('pending', 'confirmed', 'processing', 'dispatched'))
       >= coalesce((cfg ->> 'max_open_cod_per_phone')::int, 3) then
      perform app.raise('too_many_open_orders');
    end if;
  else
    if not (s.online_payment_enabled and coalesce((cfg ->> 'online_payments_enabled')::boolean, false)) then
      perform app.raise('payment_method_not_available');
    end if;
    if (q ->> 'total')::numeric < 100 then perform app.raise('online_minimum_amount', jsonb_build_object('min', 100)); end if;
  end if;
  if q ->> 'delivery_method' = 'delivery' then
    addr := jsonb_build_object('city', btrim(coalesce(p #>> '{address,city}', '')), 'area', nullif(btrim(coalesce(p #>> '{address,area}', '')), ''),
      'line', nullif(btrim(coalesce(p #>> '{address,line}', '')), ''), 'landmark', nullif(btrim(coalesce(p #>> '{address,landmark}', '')), ''));
    if length(addr ->> 'city') < 2 or coalesce(addr ->> 'line', addr ->> 'area', '') = '' then perform app.raise('address_required'); end if;
    if length(addr::text) > 800 then perform app.raise('invalid_request'); end if;
  end if;
  exp := now() + case when pay = 'online' then make_interval(mins => coalesce((cfg ->> 'unpaid_order_minutes')::int, 30))
                      else make_interval(hours => coalesce((cfg ->> 'confirm_hours')::int, 48)) end;
  comm := coalesce((cfg ->> 'commission_pct')::numeric, 0);
  fee := case when pay = 'online' then coalesce((cfg ->> 'online_fee_pct')::numeric, 0) else 0 end;
  select id into cid from public.customers where business_id = s.business_id and phone = cphone and status = 'active' limit 1;
  if cid is null then
    insert into public.customers (business_id, name, phone, email, address, source, user_id, created_by)
    values (s.business_id, cname, cphone, cemail, nullif(concat_ws(', ', addr ->> 'line', addr ->> 'area', addr ->> 'city'), ''),
            'online', uid, uid)
    returning id into cid;
  else
    update public.customers set email = coalesce(email, cemail), user_id = coalesce(user_id, uid) where id = cid;
  end if;
  num := app.next_number(s.business_id, 'order', 'ORD-');
  insert into public.market_orders (business_id, number, client_ref, customer_user_id, access_token_hash, customer_id,
    customer_name, customer_phone, customer_email, delivery_method, zone_id, zone_name, delivery_eta, address, notes,
    subtotal, discount, delivery_fee, total, currency, promo_id, promo_code, payment_method, payment_status,
    commission_pct, commission_amount, online_fee_pct, online_fee_amount, expires_at)
  values (s.business_id, num, cref, uid, case when tok is not null then app.sha256(tok) end, cid,
    cname, cphone, cemail, q ->> 'delivery_method', nullif(p ->> 'zone_id', '')::uuid, q ->> 'zone_name', q ->> 'delivery_eta',
    addr, nullif(left(btrim(coalesce(p ->> 'notes', '')), 500), ''),
    (q ->> 'subtotal')::numeric, (q ->> 'discount')::numeric, (q ->> 'delivery_fee')::numeric, (q ->> 'total')::numeric,
    b.currency, nullif(q ->> 'promo_id', '')::uuid, q ->> 'promo_code', pay,
    case when pay = 'online' then 'awaiting_payment' else 'cod_pending' end,
    comm, app.money(s.business_id, ((q ->> 'subtotal')::numeric - (q ->> 'discount')::numeric) * comm / 100),
    fee, app.money(s.business_id, (q ->> 'total')::numeric * fee / 100), exp)
  returning id into oid;
  for l in select * from jsonb_array_elements(q -> 'lines') loop
    insert into public.market_order_lines (order_id, business_id, product_id, listing_id, name, variant_label, sku, image_path,
      unit_price, quantity, line_total, sort)
    values (oid, s.business_id, (l ->> 'product_id')::uuid, (l ->> 'listing_id')::uuid, l ->> 'name', l ->> 'variant_label',
      l ->> 'sku', l ->> 'image_path', (l ->> 'unit_price')::numeric, (l ->> 'quantity')::numeric,
      (l ->> 'line_total')::numeric, (l ->> 'sort')::int);
    insert into public.stock_reservations (business_id, product_id, order_id, quantity, expires_at)
    values (s.business_id, (l ->> 'product_id')::uuid, oid, (l ->> 'quantity')::numeric, exp);
  end loop;
  if nullif(q ->> 'promo_id', '') is not null then
    update public.market_promotions set used_count = used_count + 1 where id = (q ->> 'promo_id')::uuid;
  end if;
  insert into public.market_order_events (order_id, business_id, kind, status, actor, actor_user)
  values (oid, s.business_id, 'status', 'pending', 'customer', uid);
  if pay = 'cod' then
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (s.business_id, 'market_order_new', 'info',
            jsonb_build_object('number', num, 'amount', (q ->> 'total')::numeric, 'customer', cname), '/app/orders/' || oid, 'orders.manage');
  end if;
  if uid is not null and coalesce((p ->> 'save_address')::boolean, false) and addr is not null
     and (select count(*) from public.customer_addresses where user_id = uid) < 10
     and not exists (select 1 from public.customer_addresses where user_id = uid and lower(city) = lower(addr ->> 'city')
                     and coalesce(lower(line), '') = coalesce(lower(addr ->> 'line'), '')) then
    insert into public.customer_addresses (user_id, recipient_name, phone, city, area, line, landmark, is_default)
    values (uid, cname, cphone, addr ->> 'city', addr ->> 'area', addr ->> 'line', addr ->> 'landmark',
            not exists (select 1 from public.customer_addresses where user_id = uid));
  end if;
  return jsonb_build_object('order_id', oid, 'number', num, 'total', (q ->> 'total')::numeric,
    'payment_method', pay, 'payment_status', case when pay = 'online' then 'awaiting_payment' else 'cod_pending' end,
    'duplicate', false);
end $$;
create or replace function app.order_for_customer(p_order uuid, p_token text, p_lock boolean default false)
returns public.market_orders language plpgsql security definer set search_path = public as $$
declare o public.market_orders;
begin
  if p_lock then select * into o from public.market_orders where id = p_order for update;
  else select * into o from public.market_orders where id = p_order; end if;
  if not found or not ((auth.uid() is not null and o.customer_user_id = auth.uid())
                       or (coalesce(p_token, '') <> '' and o.access_token_hash = app.sha256(p_token))) then
    perform app.raise('not_found');
  end if;
  return o;
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
    'expires_at', case when o.status = 'pending' and o.payment_method = 'online' then o.expires_at end,
    'customer_name', o.customer_name, 'customer_phone', o.customer_phone, 'customer_email', o.customer_email,
    'delivery_method', o.delivery_method, 'zone_name', o.zone_name, 'delivery_eta', o.delivery_eta, 'address', o.address,
    'notes', o.notes, 'subtotal', o.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', o.total,
    'currency', o.currency, 'promo_code', o.promo_code, 'refund_amount', o.refund_amount, 'refunded_at', o.refunded_at,
    'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path, 'city', s.city,
       'phone', case when s.show_phone then s.phone end, 'whatsapp', case when s.show_whatsapp then s.whatsapp end,
       'email', case when s.show_email then s.email end,
       'address', case when o.delivery_method = 'pickup' or s.show_address then s.address end,
       'pickup_note', case when o.delivery_method = 'pickup' then s.pickup_note end),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'listing_id', l.listing_id, 'name', l.name,
       'variant_label', l.variant_label, 'image_path', l.image_path, 'unit_price', l.unit_price, 'quantity', l.quantity,
       'line_total', l.line_total,
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending',
    'can_pay', o.payment_method = 'online' and o.status = 'pending' and o.payment_status in ('awaiting_payment', 'failed'),
    'can_review', o.status = 'delivered',
    'signed_in_owner', auth.uid() is not null and o.customer_user_id = auth.uid());
end $$;
create or replace function public.market_my_orders(p_limit int default 30, p_offset int default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  perform app.market_expire();
  return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'number', o.number, 'status', o.status,
      'payment_method', o.payment_method, 'payment_status', o.payment_status, 'total', o.total, 'created_at', o.created_at,
      'store', jsonb_build_object('slug', s.slug, 'name', s.name, 'logo_path', s.logo_path),
      'items', (select count(*) from public.market_order_lines l where l.order_id = o.id),
      'first_image', (select l.image_path from public.market_order_lines l where l.order_id = o.id order by l.sort limit 1))
      order by o.created_at desc)
    from (select * from public.market_orders where customer_user_id = uid order by created_at desc
           limit least(p_limit, 100) offset greatest(p_offset, 0)) o
    join public.stores s on s.business_id = o.business_id), '[]'::jsonb);
end $$;
create or replace function public.market_claim_orders(p_orders jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); x jsonb; n int := 0;
begin
  if uid is null then perform app.raise('not_authenticated'); end if;
  if jsonb_typeof(p_orders) <> 'array' or jsonb_array_length(p_orders) > 50 then perform app.raise('invalid_request'); end if;
  for x in select * from jsonb_array_elements(p_orders) loop
    update public.market_orders set customer_user_id = uid
     where id = (x ->> 'id')::uuid and customer_user_id is null and access_token_hash = app.sha256(coalesce(x ->> 'token', ''));
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;
create or replace function public.market_order_customer_action(p_order uuid, p_token text, p_action text, p_text text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p_text, '')), 1000), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if p_action = 'cancel' then
    if o.status <> 'pending' then perform app.raise('order_not_cancellable'); end if;
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
commit;
