-- BizPilot setup PART 14 of 19. Run parts in order.
begin;
create or replace function app.refresh_store_rating(bid uuid) returns void
language sql security definer set search_path = public as $$
  update public.stores set
    rating_avg = coalesce((select round(avg(rating), 2) from public.market_reviews where business_id = bid and status = 'visible'), 0),
    rating_count = (select count(*) from public.market_reviews where business_id = bid and status = 'visible')
  where business_id = bid
$$;
create or replace function public.market_submit_review(p_order uuid, p_token text, p_product uuid, p_rating int, p_comment text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.market_orders; l public.market_order_lines; rid uuid;
begin
  o := app.order_for_customer(p_order, p_token);
  if o.status <> 'delivered' then perform app.raise('review_requires_delivery'); end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then perform app.raise('invalid_rating'); end if;
  select * into l from public.market_order_lines where order_id = o.id and product_id = p_product limit 1;
  if not found then perform app.raise('not_found'); end if;
  begin
    insert into public.market_reviews (business_id, order_id, product_id, listing_id, user_id, author_name, rating, comment)
    values (o.business_id, o.id, p_product, coalesce(l.listing_id, p_product), auth.uid(),
            split_part(o.customer_name, ' ', 1), p_rating, nullif(left(btrim(coalesce(p_comment, '')), 1000), ''))
    returning id into rid;
  exception when unique_violation then
    perform app.raise('already_reviewed');
  end;
  perform app.refresh_store_rating(o.business_id);
  return rid;
end $$;
create or replace function public.market_report(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare tt text := p ->> 'target_type'; tid uuid := nullif(p ->> 'target_id', '')::uuid; bid uuid; o public.market_orders;
        rid uuid; k text := 'report'; contact text := nullif(left(btrim(coalesce(p ->> 'contact', '')), 120), '');
begin
  perform app.rate_limit('report_ip:' || app.client_ip(), 10, 3600);
  if tt = 'product' then select business_id into bid from public.products where id = app.listing_of(tid);
  elsif tt = 'store' then select business_id into bid from public.stores where business_id = tid;
  elsif tt = 'order' then
    o := app.order_for_customer(tid, p ->> 'token');
    bid := o.business_id; k := 'dispute';
  else perform app.raise('invalid_request'); end if;
  if bid is null then perform app.raise('not_found'); end if;
  if auth.uid() is null and contact is null and tt <> 'order' then perform app.raise('contact_required'); end if;
  insert into public.market_reports (kind, target_type, target_id, business_id, order_id, reason, details, reporter_user_id, reporter_contact)
  values (k, tt, tid, bid, o.id, p ->> 'reason', nullif(left(btrim(coalesce(p ->> 'details', '')), 2000), ''), auth.uid(), contact)
  returning id into rid;
  if k = 'dispute' then
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user)
    values (o.id, o.business_id, 'dispute', p ->> 'reason', 'customer', auth.uid());
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_dispute', 'critical', jsonb_build_object('number', o.number, 'reason', p ->> 'reason'),
            '/app/orders/' || o.id, 'orders.manage');
  end if;
  return rid;
end $$;
create or replace function app.reserved_slug(s text) returns boolean language sql immutable as $$
  select lower(s) = any (array['admin', 'app', 'api', 'market', 'marketplace', 's', 'login', 'signup', 'account', 'cart',
    'checkout', 'order', 'orders', 'help', 'support', 'bizpilot', 'store', 'stores', 'pay', 'auth', 'www', 'shop'])
$$;
create or replace function public.store_slug_available(p_slug text, p_business uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(btrim(p_slug)) ~ '^[a-z0-9]([a-z0-9-]{1,38})[a-z0-9]$' and not app.reserved_slug(btrim(p_slug))
     and not exists (select 1 from public.stores where lower(slug) = lower(btrim(p_slug))
                     and (p_business is null or business_id <> p_business))
$$;
create or replace function public.store_save(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.stores; b public.businesses; v_slug text; custom boolean;
begin
  perform app.require_perm(p_business, 'store.manage');
  select * into b from public.businesses where id = p_business;
  select * into s from public.stores where business_id = p_business for update;
  custom := app.has_feature(p_business, 'store_customization');
  if p ? 'slug' or s.business_id is null then
    v_slug := lower(btrim(coalesce(p ->> 'slug', '')));
    if v_slug = '' then
      v_slug := trim(both '-' from left(regexp_replace(lower(b.name), '[^a-z0-9]+', '-', 'g'), 36));
      if length(v_slug) < 3 then v_slug := 'store-' || left(replace(p_business::text, '-', ''), 6); end if;
      while not public.store_slug_available(v_slug, p_business) loop
        v_slug := left(v_slug, 33) || '-' || substr(md5(random()::text), 1, 4);
      end loop;
    end if;
    if not public.store_slug_available(v_slug, p_business) then perform app.raise('slug_unavailable'); end if;
  end if;
  if (p ? 'cover_path' and nullif(p ->> 'cover_path', '') is not null or p ? 'brand_color' and nullif(p ->> 'brand_color', '') is not null)
     and not custom then
    perform app.raise('feature_not_in_plan', jsonb_build_object('feature', 'store_customization'));
  end if;
  if p ? 'name' and length(btrim(coalesce(p ->> 'name', ''))) < 2 then perform app.raise('store_name_required'); end if;
  if p ? 'phone' and nullif(p ->> 'phone', '') is not null and app.norm_phone(p ->> 'phone') is null then perform app.raise('invalid_phone'); end if;
  if p ? 'whatsapp' and nullif(p ->> 'whatsapp', '') is not null and app.norm_phone(p ->> 'whatsapp') is null then perform app.raise('invalid_phone'); end if;
  if p ? 'email' and nullif(p ->> 'email', '') is not null and not app.valid_email(p ->> 'email') then perform app.raise('invalid_email'); end if;
  if (p ? 'logo_path' and split_part(coalesce(p ->> 'logo_path', p_business::text), '/', 1) <> p_business::text)
     or (p ? 'cover_path' and split_part(coalesce(p ->> 'cover_path', p_business::text), '/', 1) <> p_business::text) then
    perform app.raise('invalid_image');
  end if;
  if p ? 'online_payment_enabled' and (p ->> 'online_payment_enabled')::boolean
     and not coalesce((app.market_config() ->> 'online_payments_enabled')::boolean, false) then
    perform app.raise('online_payments_not_available');
  end if;
  if s.business_id is null then
    insert into public.stores (business_id, slug, name, city, phone, whatsapp, email, address)
    values (p_business, v_slug, coalesce(nullif(btrim(p ->> 'name'), ''), b.name), coalesce(nullif(p ->> 'city', ''), b.city),
            app.norm_phone(coalesce(nullif(p ->> 'phone', ''), b.phone)), app.norm_phone(coalesce(nullif(p ->> 'whatsapp', ''), b.phone)),
            coalesce(nullif(p ->> 'email', ''), b.email), coalesce(nullif(p ->> 'address', ''), b.address))
    returning * into s;
    perform app.audit(p_business, 'store.created', 'store', p_business::text, jsonb_build_object('slug', v_slug));
  end if;
  update public.stores set
    slug = coalesce(v_slug, slug),
    name = case when p ? 'name' then btrim(p ->> 'name') else name end,
    tagline = case when p ? 'tagline' then nullif(btrim(p ->> 'tagline'), '') else tagline end,
    description = case when p ? 'description' then nullif(btrim(p ->> 'description'), '') else description end,
    logo_path = case when p ? 'logo_path' then nullif(p ->> 'logo_path', '') else logo_path end,
    cover_path = case when p ? 'cover_path' then nullif(p ->> 'cover_path', '') else cover_path end,
    brand_color = case when p ? 'brand_color' then nullif(p ->> 'brand_color', '') else brand_color end,
    city = case when p ? 'city' then nullif(btrim(p ->> 'city'), '') else city end,
    region = case when p ? 'region' then nullif(btrim(p ->> 'region'), '') else region end,
    address = case when p ? 'address' then nullif(btrim(p ->> 'address'), '') else address end,
    phone = case when p ? 'phone' then app.norm_phone(p ->> 'phone') else phone end,
    whatsapp = case when p ? 'whatsapp' then app.norm_phone(p ->> 'whatsapp') else whatsapp end,
    email = case when p ? 'email' then nullif(lower(btrim(p ->> 'email')), '') else email end,
    show_phone = coalesce((p ->> 'show_phone')::boolean, show_phone),
    show_whatsapp = coalesce((p ->> 'show_whatsapp')::boolean, show_whatsapp),
    show_email = coalesce((p ->> 'show_email')::boolean, show_email),
    show_address = coalesce((p ->> 'show_address')::boolean, show_address),
    facebook_url = case when p ? 'facebook_url' then nullif(btrim(p ->> 'facebook_url'), '') else facebook_url end,
    instagram_url = case when p ? 'instagram_url' then nullif(btrim(p ->> 'instagram_url'), '') else instagram_url end,
    tiktok_url = case when p ? 'tiktok_url' then nullif(btrim(p ->> 'tiktok_url'), '') else tiktok_url end,
    opening_hours = case when jsonb_typeof(p -> 'opening_hours') = 'object' and length((p -> 'opening_hours')::text) < 2000
                         then p -> 'opening_hours' else opening_hours end,
    hours_note = case when p ? 'hours_note' then nullif(btrim(p ->> 'hours_note'), '') else hours_note end,
    delivery_note = case when p ? 'delivery_note' then nullif(btrim(p ->> 'delivery_note'), '') else delivery_note end,
    pickup_enabled = coalesce((p ->> 'pickup_enabled')::boolean, pickup_enabled),
    pickup_note = case when p ? 'pickup_note' then nullif(btrim(p ->> 'pickup_note'), '') else pickup_note end,
    cod_enabled = coalesce((p ->> 'cod_enabled')::boolean, cod_enabled),
    online_payment_enabled = coalesce((p ->> 'online_payment_enabled')::boolean, online_payment_enabled),
    min_order_amount = coalesce(nullif(p ->> 'min_order_amount', '')::numeric, min_order_amount)
  where business_id = p_business returning * into s;
  if s.status = 'published' and not (s.cod_enabled or s.online_payment_enabled) then
    perform app.raise('payment_method_required');
  end if;
  perform app.audit(p_business, 'store.updated', 'store', p_business::text, p - 'description' - 'opening_hours');
  return to_jsonb(s);
end $$;
create or replace function public.store_save_zones(p_business uuid, p_zones jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare z jsonb; keep uuid[] := '{}'; zid uuid; n int := 0;
begin
  perform app.require_perm(p_business, 'store.manage');
  if jsonb_typeof(p_zones) <> 'array' or jsonb_array_length(p_zones) > 40 then perform app.raise('invalid_request'); end if;
  for z in select * from jsonb_array_elements(p_zones) loop
    n := n + 1;
    if coalesce(btrim(z ->> 'name'), '') = '' then perform app.raise('zone_name_required'); end if;
    if coalesce((z ->> 'fee')::numeric, 0) < 0 then perform app.raise('invalid_amount'); end if;
    zid := nullif(z ->> 'id', '')::uuid;
    if zid is not null and exists (select 1 from public.store_delivery_zones where id = zid and business_id = p_business) then
      update public.store_delivery_zones set name = btrim(z ->> 'name'), fee = app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
             eta = nullif(btrim(coalesce(z ->> 'eta', '')), ''), active = coalesce((z ->> 'active')::boolean, true), sort = n
       where id = zid;
    else
      insert into public.store_delivery_zones (business_id, name, fee, eta, active, sort)
      values (p_business, btrim(z ->> 'name'), app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
              nullif(btrim(coalesce(z ->> 'eta', '')), ''), coalesce((z ->> 'active')::boolean, true), n)
      returning id into zid;
    end if;
    keep := keep || zid;
  end loop;
  delete from public.store_delivery_zones where business_id = p_business and not (id = any (keep));
  perform app.audit(p_business, 'store.zones_updated', 'store', p_business::text, jsonb_build_object('zones', n));
  return n;
end $$;
create or replace function public.store_readiness(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.stores; listed int; zones int;
begin
  if not app.can_read(p_business) then perform app.raise('permission_denied'); end if;
  select * into s from public.stores where business_id = p_business;
  select count(*) into listed from public.products where business_id = p_business and online_published and status = 'active' and variant_of is null;
  select count(*) into zones from public.store_delivery_zones where business_id = p_business and active;
  return jsonb_build_object(
    'store_created', s.business_id is not null,
    'profile', coalesce(s.business_id is not null and s.name is not null and (s.phone is not null or s.whatsapp is not null), false),
    'logo', s.logo_path is not null,
    'products', listed > 0, 'listed', listed,
    'payment', coalesce(s.cod_enabled or s.online_payment_enabled, false),
    'delivery', coalesce(s.pickup_enabled, false) or zones > 0,
    'published', coalesce(s.status = 'published', false), 'status', s.status, 'slug', s.slug,
    'verification', s.verification, 'suspended_reason', s.suspended_reason);
end $$;
create or replace function public.store_set_published(p_business uuid, p_publish boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.stores; r jsonb;
begin
  perform app.require_perm(p_business, 'store.manage');
  select * into s from public.stores where business_id = p_business for update;
  if not found then perform app.raise('store_not_created'); end if;
  if s.status = 'suspended' then perform app.raise('store_suspended', jsonb_build_object('reason', s.suspended_reason)); end if;
  if p_publish then
    r := public.store_readiness(p_business);
    if not ((r ->> 'profile')::boolean and (r ->> 'products')::boolean and (r ->> 'payment')::boolean and (r ->> 'delivery')::boolean) then
      perform app.raise('store_not_ready', r);
    end if;
    update public.stores set status = 'published', published_at = coalesce(published_at, now()) where business_id = p_business;
  else
    update public.stores set status = 'draft' where business_id = p_business;
  end if;
  perform app.audit(p_business, case when p_publish then 'store.published' else 'store.unpublished' end, 'store', p_business::text);
  return public.store_readiness(p_business);
end $$;
create or replace function public.store_request_verification(p_business uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_perm(p_business, 'store.manage');
  update public.stores set verification = 'pending', verification_note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
   where business_id = p_business and verification in ('unverified', 'rejected');
  if not found then perform app.raise('verification_not_available'); end if;
  perform app.audit(p_business, 'store.verification_requested', 'store', p_business::text);
end $$;
create or replace function public.products_set_online(p_business uuid, p_ids uuid[], p_online boolean) returns int
language plpgsql security definer set search_path = public as $$
declare i uuid; n int := 0;
begin
  perform app.require_perm(p_business, 'products.manage');
  if coalesce(array_length(p_ids, 1), 0) > 500 then perform app.raise('invalid_request'); end if;
  foreach i in array p_ids loop
    update public.products set online_published = p_online
     where id = i and business_id = p_business and variant_of is null and status = 'active' and online_published <> p_online;
    if found then n := n + 1; end if;
  end loop;
  perform app.audit(p_business, case when p_online then 'listing.published' else 'listing.unpublished' end, 'product', null,
                    jsonb_build_object('count', n));
  return n;
end $$;
create or replace function public.promo_save(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare pid uuid := nullif(p ->> 'id', '')::uuid; v_code text := upper(btrim(coalesce(p ->> 'code', '')));
begin
  perform app.require_perm(p_business, 'store.manage');
  perform app.require_feature(p_business, 'promotions');
  if v_code !~ '^[A-Z0-9_-]{3,20}$' then perform app.raise('invalid_promo_code'); end if;
  if coalesce(p ->> 'kind', '') not in ('percent', 'fixed') or coalesce(nullif(p ->> 'value', '')::numeric, 0) <= 0
     or (p ->> 'kind' = 'percent' and (p ->> 'value')::numeric > 90) then
    perform app.raise('invalid_amount');
  end if;
  if pid is null then
    begin
      insert into public.market_promotions (business_id, code, description, kind, value, min_order, starts_at, ends_at, max_uses, active, created_by)
      values (p_business, v_code, nullif(btrim(coalesce(p ->> 'description', '')), ''), p ->> 'kind', (p ->> 'value')::numeric,
              coalesce(nullif(p ->> 'min_order', '')::numeric, 0), nullif(p ->> 'starts_at', '')::timestamptz,
              nullif(p ->> 'ends_at', '')::timestamptz, nullif(p ->> 'max_uses', '')::int, coalesce((p ->> 'active')::boolean, true), auth.uid())
      returning id into pid;
    exception when unique_violation then perform app.raise('promo_code_exists'); end;
  else
    update public.market_promotions set description = nullif(btrim(coalesce(p ->> 'description', '')), ''), kind = p ->> 'kind',
           value = (p ->> 'value')::numeric, min_order = coalesce(nullif(p ->> 'min_order', '')::numeric, 0),
           starts_at = nullif(p ->> 'starts_at', '')::timestamptz, ends_at = nullif(p ->> 'ends_at', '')::timestamptz,
           max_uses = nullif(p ->> 'max_uses', '')::int, active = coalesce((p ->> 'active')::boolean, true)
     where id = pid and business_id = p_business;
    if not found then perform app.raise('not_found'); end if;
  end if;
  perform app.audit(p_business, 'promotion.saved', 'promotion', pid::text, p);
  return pid;
end $$;
create or replace function public.market_review_reply(p_review uuid, p_reply text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reviews;
begin
  select * into r from public.market_reviews where id = p_review;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(r.business_id, 'store.manage');
  update public.market_reviews set seller_reply = nullif(left(btrim(coalesce(p_reply, '')), 1000), ''), replied_at = now() where id = p_review;
end $$;
create or replace function app.market_order_to_sale(p_order uuid, p_method text, p_reference text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  o public.market_orders; st public.business_settings; sid uuid; num text; l record; mv public.stock_movements;
  net_sum numeric; goods numeric; alloc numeric; alloc_left numeric; n int; i int := 0; v_net numeric; tax numeric;
  tax_sum numeric := 0; cost_sum numeric := 0;
begin
  select * into o from public.market_orders where id = p_order;
  select * into st from public.business_settings where business_id = o.business_id;
  update public.stock_reservations set consumed_at = now() where order_id = o.id and released_at is null and consumed_at is null;
  num := app.next_number(o.business_id, 'sale', 'S-');
  insert into public.sales (business_id, number, client_ref, customer_id, sold_at, notes, created_by)
  values (o.business_id, num, o.id, o.customer_id, now(), 'Online order ' || o.number, auth.uid())
  returning id into sid;
  perform 1 from public.products where id in (select product_id from public.market_order_lines where order_id = o.id) order by id for update;
  select coalesce(sum(line_total), 0), count(*) into net_sum, n from public.market_order_lines where order_id = o.id;
  goods := net_sum - o.discount;
  alloc_left := o.discount;
  for l in select * from public.market_order_lines where order_id = o.id order by sort, id loop
    i := i + 1;
    if i = n then alloc := alloc_left;
    elsif net_sum > 0 then alloc := least(alloc_left, app.money(o.business_id, o.discount * l.line_total / net_sum));
    else alloc := 0; end if;
    alloc_left := alloc_left - alloc;
    v_net := l.line_total - alloc;
    tax := case when st.tax_enabled then app.money(o.business_id, v_net * st.tax_rate / (100 + st.tax_rate)) else 0 end;
    perform app.consume_batches(l.product_id, l.quantity);
    mv := app.apply_movement(o.business_id, l.product_id, 'sale', -l.quantity, null, 'sale', sid, num, 'Online order ' || o.number);
    insert into public.sale_lines (sale_id, business_id, product_id, unit_id, unit_name, unit_factor, quantity, base_quantity,
      list_price, unit_price, line_discount, sale_discount_alloc, net_amount, tax_amount, cost_unit_base, cost_amount, sort)
    values (sid, o.business_id, l.product_id, null, (select base_unit from public.products where id = l.product_id), 1,
      l.quantity, l.quantity, l.unit_price, l.unit_price, 0, alloc, v_net, tax, mv.unit_cost, -mv.value, i);
    tax_sum := tax_sum + tax;
    cost_sum := cost_sum - mv.value;
  end loop;
  update public.sales set subtotal = net_sum, list_total = net_sum, line_discount_total = 0, sale_discount = o.discount,
         total = goods, tax_total = tax_sum, cost_total = cost_sum where id = sid;
  if goods > 0 then
    perform app.insert_payment(o.business_id, 'sale_payment', p_method, goods, now(), p_reference, 'Online order ' || o.number,
                               null, o.customer_id, null, sid);
  end if;
  perform app.rebalance_customer(o.customer_id, sid);
  perform app.audit(o.business_id, 'sale.created', 'sale', sid::text,
    jsonb_build_object('number', num, 'total', goods, 'paid', goods, 'online_order', o.number));
  return sid;
end $$;
create or replace function public.market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
  reason text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), ''); sid uuid; rid uuid;
  goods numeric; refund numeric;
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
  elsif p_action = 'deliver' then
    if o.status not in ('confirmed', 'processing', 'dispatched') then perform app.raise('invalid_order_status'); end if;
    if o.payment_method = 'cod' then
      if coalesce(p ->> 'cod_method', '') not in ('cash', 'mtn_momo', 'orange_money') then perform app.raise('payment_method_required'); end if;
      sid := app.market_order_to_sale(o.id, p ->> 'cod_method', 'COD ' || o.number);
      if o.delivery_fee > 0 then
        insert into public.cash_movements (business_id, kind, to_account_id, amount, note, client_ref, created_by)
        values (o.business_id, 'deposit', app.account_for_method(o.business_id, p ->> 'cod_method'), o.delivery_fee,
                'Delivery fee ' || o.number, null, auth.uid());
      end if;
      update public.market_orders set payment_status = 'cod_collected', cod_collected_amount = o.total, cod_method = p ->> 'cod_method',
             cod_collected_at = now(), cod_collected_by = auth.uid() where id = o.id;
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
    perform app.market_cancel(o.id, 'seller', reason);
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
      'refund', jsonb_build_object('amount', refund, 'method', case when o.payment_method = 'cod' then o.cod_method else 'other' end,
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
  elsif p_action not in ('reject', 'cancel') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'status', (select status from public.market_orders where id = o.id), coalesce(msg, reason), 'seller', auth.uid());
  end if;
  perform app.audit(o.business_id, 'order.' || p_action, 'market_order', o.id::text,
                    jsonb_build_object('number', o.number, 'reason', reason));
  return (select to_jsonb(x) from public.market_orders x where x.id = o.id);
end $$;
commit;
