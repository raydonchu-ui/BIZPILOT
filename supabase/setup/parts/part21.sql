-- BizPilot setup PART 21 of 24. Run parts in order.
begin;
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
    'zones', coalesce((select jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'eta', z.eta, 'regions', z.regions, 'localities', z.localities) order by z.sort, z.name)
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
create or replace function public.store_save_zones(p_business uuid, p_zones jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare z jsonb; keep uuid[] := '{}'; zid uuid; n int := 0; areas_regions text[]; areas_localities text[];
begin
  perform app.require_perm(p_business, 'store.manage');
  if jsonb_typeof(p_zones) <> 'array' or jsonb_array_length(p_zones) > 40 then perform app.raise('invalid_request'); end if;
  for z in select * from jsonb_array_elements(p_zones) loop
    n := n + 1;
    if coalesce(btrim(z ->> 'name'), '') = '' then perform app.raise('zone_name_required'); end if;
    if coalesce((z ->> 'fee')::numeric, 0) < 0 then perform app.raise('invalid_amount'); end if;
    zid := nullif(z ->> 'id', '')::uuid;
    areas_regions := case when z ? 'regions' then coalesce(array(select jsonb_array_elements_text(z -> 'regions')), '{}'::text[]) end;
    areas_localities := case when z ? 'localities' then coalesce(array(select jsonb_array_elements_text(z -> 'localities')), '{}'::text[]) end;
    if zid is not null and exists (select 1 from public.store_delivery_zones where id = zid and business_id = p_business) then
      update public.store_delivery_zones set name = btrim(z ->> 'name'), fee = app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
             eta = nullif(btrim(coalesce(z ->> 'eta', '')), ''), active = coalesce((z ->> 'active')::boolean, true), sort = n,
             regions = coalesce(areas_regions, regions), localities = coalesce(areas_localities, localities)
       where id = zid;
    else
      insert into public.store_delivery_zones (business_id, name, fee, eta, active, sort, regions, localities)
      values (p_business, btrim(z ->> 'name'), app.money(p_business, coalesce((z ->> 'fee')::numeric, 0)),
              nullif(btrim(coalesce(z ->> 'eta', '')), ''), coalesce((z ->> 'active')::boolean, true), n,
              coalesce(areas_regions, '{}'::text[]), coalesce(areas_localities, '{}'::text[]))
      returning id into zid;
    end if;
    keep := keep || zid;
  end loop;
  delete from public.store_delivery_zones where business_id = p_business and not (id = any (keep));
  perform app.audit(p_business, 'store.zones_updated', 'store', p_business::text, jsonb_build_object('zones', n));
  return n;
end $$;
alter table public.market_orders
  add column if not exists receipt_status text not null default 'none'
    check (receipt_status in ('none', 'awaiting', 'confirmed', 'disputed', 'resolved')),
  add column if not exists receipt_due_at timestamptz,
  add column if not exists receipt_confirmed_at timestamptz,
  add column if not exists receipt_confirmed_by text check (receipt_confirmed_by in ('customer'));
alter table public.market_order_events drop constraint if exists market_order_events_kind_check;
alter table public.market_order_events add constraint market_order_events_kind_check
  check (kind in ('status', 'message', 'payment', 'note', 'dispute', 'receipt'));
alter table public.market_reports drop constraint if exists market_reports_target_type_check;
alter table public.market_reports add constraint market_reports_target_type_check
  check (target_type in ('product', 'store', 'order', 'review'));
alter table public.market_reviews add column if not exists edited_at timestamptz;
create or replace function app.order_receipt_start() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'delivered' and old.status <> 'delivered' then
    if new.receipt_status = 'none' then new.receipt_status := 'awaiting'; end if;
    new.receipt_due_at := coalesce(new.receipt_due_at, now() + interval '3 days');
  end if;
  return new;
end $$;
drop trigger if exists market_orders_receipt on public.market_orders;
create trigger market_orders_receipt before update of status on public.market_orders
  for each row execute function app.order_receipt_start();
create or replace function app.market_report_receipt() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'dispute' or new.order_id is null then return new; end if;
  if new.status in ('open', 'reviewing') then
    update public.market_orders set receipt_status = 'disputed' where id = new.order_id;
  elsif not exists (select 1 from public.market_reports r where r.order_id = new.order_id and r.id <> new.id
                    and r.kind = 'dispute' and r.status in ('open', 'reviewing')) then
    if new.status = 'resolved' then
      update public.market_orders set receipt_status = 'resolved' where id = new.order_id and receipt_status = 'disputed';
    elsif new.status = 'dismissed' then
      update public.market_orders set receipt_status = case when receipt_confirmed_at is not null then 'confirmed'
                                                            when receipt_due_at is not null then 'awaiting' else 'none' end
       where id = new.order_id and receipt_status = 'disputed';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists market_reports_receipt on public.market_reports;
create trigger market_reports_receipt after insert or update of status on public.market_reports
  for each row execute function app.market_report_receipt();
create or replace function app.review_gate(o public.market_orders) returns text
language sql stable set search_path = public as $$
  select case
    when o.status <> 'delivered' then 'review_requires_delivery'
    when o.receipt_status = 'disputed' then 'review_blocked_by_problem'
    when o.receipt_status = 'awaiting' and o.receipt_due_at > now() then 'review_requires_receipt'
    else null end
$$;
create or replace function public.market_order_customer_action(p_order uuid, p_token text, p_action text, p_text text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p_text, '')), 1000), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  perform app.rate_limit('order_msg:' || o.id, 30, 3600);
  if p_action = 'cancel' then
    if o.status <> 'pending' or o.payment_status = 'seller_confirmed' then perform app.raise('order_not_cancellable'); end if;
    perform app.market_cancel(o.id, 'customer', coalesce(msg, 'cancelled_by_customer'));
  elsif p_action = 'received' then
    if o.status <> 'delivered' or o.receipt_status not in ('awaiting', 'resolved', 'confirmed') then
      perform app.raise('invalid_order_status');
    end if;
    if o.receipt_status = 'confirmed' then return; end if;
    update public.market_orders set receipt_status = 'confirmed', receipt_confirmed_at = now(), receipt_confirmed_by = 'customer'
     where id = o.id;
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'receipt', 'delivered', 'received_confirmed', 'customer', auth.uid());
    insert into public.notifications (business_id, type, severity, params, link, required_perm)
    values (o.business_id, 'market_receipt', 'info', jsonb_build_object('number', o.number), '/app/orders/' || o.id, 'orders.manage');
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
    'receipt_status', o.receipt_status, 'receipt_due_at', o.receipt_due_at, 'receipt_confirmed_at', o.receipt_confirmed_at,
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
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id),
       'review', (select jsonb_build_object('id', r.id, 'rating', r.rating, 'comment', r.comment, 'created_at', r.created_at,
                    'edited_at', r.edited_at, 'can_edit', r.edited_at is null and r.created_at > now() - interval '48 hours')
                  from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending' and o.payment_status <> 'seller_confirmed',
    'can_pay', false,
    'can_report_payment', o.payment_method = 'momo_direct' and o.payment_status = 'cod_pending'
       and o.status in ('pending', 'confirmed', 'processing', 'dispatched'),
    'can_confirm_receipt', o.status = 'delivered' and o.receipt_status in ('awaiting', 'resolved'),
    'can_report_problem', o.receipt_status <> 'confirmed',
    'can_review', app.review_gate(o) is null,
    'signed_in_owner', coalesce(o.customer_user_id = auth.uid(), false));
end $$;
create or replace function public.market_submit_review(p_order uuid, p_token text, p_product uuid, p_rating int, p_comment text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare o public.market_orders; l public.market_order_lines; r public.market_reviews; rid uuid;
        txt text := nullif(left(btrim(coalesce(p_comment, '')), 1000), '');
begin
  o := app.order_for_customer(p_order, p_token, true);
  if app.review_gate(o) is not null then perform app.raise(app.review_gate(o)); end if;
  if p_rating is null or p_rating < 1 or p_rating > 5 then perform app.raise('invalid_rating'); end if;
  select * into l from public.market_order_lines where order_id = o.id and product_id = p_product limit 1;
  if not found then perform app.raise('not_found'); end if;
  select * into r from public.market_reviews where order_id = o.id and product_id = p_product;
  if found then
    if r.edited_at is not null then perform app.raise('already_reviewed'); end if;
    if r.created_at < now() - interval '48 hours' then perform app.raise('review_edit_closed'); end if;
    update public.market_reviews set rating = p_rating, comment = txt, edited_at = now() where id = r.id;
    rid := r.id;
  else
    begin
      insert into public.market_reviews (business_id, order_id, product_id, listing_id, user_id, author_name, rating, comment)
      values (o.business_id, o.id, p_product, coalesce(l.listing_id, p_product), auth.uid(),
              split_part(o.customer_name, ' ', 1), p_rating, txt)
      returning id into rid;
    exception when unique_violation then
      perform app.raise('already_reviewed');
    end;
  end if;
  perform app.refresh_store_rating(o.business_id);
  return rid;
end $$;
create or replace function app.order_for_customer(p_order uuid, p_token text, p_lock boolean default false)
returns public.market_orders language plpgsql security definer set search_path = public as $$
declare o public.market_orders;
begin
  if p_lock then select * into o from public.market_orders where id = p_order for update;
  else select * into o from public.market_orders where id = p_order; end if;
  if not found or not (
       coalesce(o.customer_user_id = auth.uid(), false)
       or (coalesce(p_token, '') <> '' and coalesce(o.access_token_hash = app.sha256(p_token), false))) then
    perform app.raise('not_found');
  end if;
  return o;
end $$;
create or replace function public.market_report(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare tt text := p ->> 'target_type'; tid uuid := nullif(p ->> 'target_id', '')::uuid; bid uuid; oid uuid; o public.market_orders;
        rid uuid; k text := 'report'; contact text := nullif(left(btrim(coalesce(p ->> 'contact', '')), 120), '');
begin
  perform app.rate_limit('report_ip:' || app.client_ip(), 10, 3600);
  if tt = 'product' then select business_id into bid from public.products where id = app.listing_of(tid);
  elsif tt = 'store' then select business_id into bid from public.stores where business_id = tid;
  elsif tt = 'review' then select business_id, order_id into bid, oid from public.market_reviews where id = tid;
  elsif tt = 'order' then
    o := app.order_for_customer(tid, p ->> 'token');
    if o.receipt_status = 'confirmed' then perform app.raise('receipt_already_confirmed'); end if;
    bid := o.business_id; oid := o.id; k := 'dispute';
  else perform app.raise('invalid_request'); end if;
  if bid is null then perform app.raise('not_found'); end if;
  if auth.uid() is null and contact is null and tt <> 'order' then perform app.raise('contact_required'); end if;
  insert into public.market_reports (kind, target_type, target_id, business_id, order_id, reason, details, reporter_user_id, reporter_contact)
  values (k, tt, tid, bid, oid, p ->> 'reason', nullif(left(btrim(coalesce(p ->> 'details', '')), 2000), ''), auth.uid(), contact)
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
create or replace function app.payment_text_ok(t text) returns boolean
language sql immutable as $$
  select t is null or t !~* '(\mpin\M|\motp\M|password|mot de passe|code secret|secret code|passcode|one.time code|code a usage unique|wallet pass)'
$$;
alter table public.stores
  add column if not exists momo_mtn_enabled boolean not null default false,
  add column if not exists momo_orange_enabled boolean not null default false,
  add column if not exists momo_mtn_instructions text,
  add column if not exists momo_orange_instructions text,
  add column if not exists momo_proof_required boolean not null default false,
  add column if not exists momo_settings_updated_at timestamptz;
update public.stores set
  momo_mtn_enabled = momo_direct_enabled and momo_mtn_number is not null,
  momo_orange_enabled = momo_direct_enabled and momo_orange_number is not null
where not momo_mtn_enabled and not momo_orange_enabled;
alter table public.stores drop constraint if exists stores_momo_mtn_instructions_check;
alter table public.stores add constraint stores_momo_mtn_instructions_check
  check (momo_mtn_instructions is null or (length(momo_mtn_instructions) <= 300 and app.payment_text_ok(momo_mtn_instructions)));
alter table public.stores drop constraint if exists stores_momo_orange_instructions_check;
alter table public.stores add constraint stores_momo_orange_instructions_check
  check (momo_orange_instructions is null or (length(momo_orange_instructions) <= 300 and app.payment_text_ok(momo_orange_instructions)));
create or replace function public.store_save_payments(p_business uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  mtn text := nullif(right(regexp_replace(coalesce(p ->> 'momo_mtn_number', ''), '\D', '', 'g'), 9), '');
  ora text := nullif(right(regexp_replace(coalesce(p ->> 'momo_orange_number', ''), '\D', '', 'g'), 9), '');
  mtn_on boolean := coalesce((p ->> 'momo_mtn_enabled')::boolean, mtn is not null);
  ora_on boolean := coalesce((p ->> 'momo_orange_enabled')::boolean, ora is not null);
  wanted boolean := coalesce((p ->> 'momo_direct_enabled')::boolean, false);
  mtn_ins text := nullif(left(btrim(coalesce(p ->> 'momo_mtn_instructions', '')), 300), '');
  ora_ins text := nullif(left(btrim(coalesce(p ->> 'momo_orange_instructions', '')), 300), '');
  enabled boolean;
begin
  perform app.require_perm(p_business, 'store.manage');
  if not exists (select 1 from public.stores where business_id = p_business) then perform app.raise('store_not_found'); end if;
  if (mtn is not null and mtn !~ '^6[0-9]{8}$') or (ora is not null and ora !~ '^6[0-9]{8}$') then perform app.raise('invalid_phone'); end if;
  if (mtn_on and mtn is null) or (ora_on and ora is null) then perform app.raise('momo_number_required'); end if;
  if not app.payment_text_ok(mtn_ins) or not app.payment_text_ok(ora_ins) then perform app.raise('payment_secret_not_allowed'); end if;
  enabled := wanted and (mtn_on or ora_on);
  if wanted and not enabled then perform app.raise('momo_number_required'); end if;
  update public.stores set
    momo_direct_enabled = enabled,
    momo_mtn_enabled = enabled and mtn_on, momo_orange_enabled = enabled and ora_on,
    momo_mtn_number = mtn, momo_orange_number = ora,
    momo_mtn_name = nullif(left(btrim(coalesce(p ->> 'momo_mtn_name', '')), 80), ''),
    momo_orange_name = nullif(left(btrim(coalesce(p ->> 'momo_orange_name', '')), 80), ''),
    momo_mtn_instructions = mtn_ins, momo_orange_instructions = ora_ins,
    momo_proof_required = coalesce((p ->> 'momo_proof_required')::boolean, momo_proof_required),
    payment_note = nullif(left(btrim(coalesce(p ->> 'payment_note', '')), 300), ''),
    return_policy = nullif(left(btrim(coalesce(p ->> 'return_policy', '')), 1500), ''),
    neighborhood = nullif(left(btrim(coalesce(p ->> 'neighborhood', '')), 80), ''),
    service_area = nullif(left(btrim(coalesce(p ->> 'service_area', '')), 200), ''),
    cod_enabled = coalesce((p ->> 'cod_enabled')::boolean, cod_enabled),
    online_payment_enabled = false, momo_settings_updated_at = now(), updated_at = now()
   where business_id = p_business;
  perform app.audit(p_business, 'store.payments', 'store', p_business::text,
    jsonb_build_object('momo_direct', enabled, 'mtn', enabled and mtn_on, 'orange', enabled and ora_on,
                       'proof_required', coalesce((p ->> 'momo_proof_required')::boolean, false)));
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
    'receipt_status', o.receipt_status, 'receipt_due_at', o.receipt_due_at, 'receipt_confirmed_at', o.receipt_confirmed_at,
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
          'mtn', case when s.momo_mtn_enabled and s.momo_mtn_number is not null then jsonb_build_object(
             'number', s.momo_mtn_number, 'name', s.momo_mtn_name, 'instructions', s.momo_mtn_instructions) end,
          'orange', case when s.momo_orange_enabled and s.momo_orange_number is not null then jsonb_build_object(
             'number', s.momo_orange_number, 'name', s.momo_orange_name, 'instructions', s.momo_orange_instructions) end,
          'note', s.payment_note, 'proof_required', s.momo_proof_required,
          'source', 'seller_entered') end),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'listing_id', l.listing_id, 'name', l.name,
       'variant_label', l.variant_label, 'image_path', l.image_path, 'unit_price', l.unit_price, 'quantity', l.quantity,
       'line_total', l.line_total,
       'reviewed', exists (select 1 from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id),
       'review', (select jsonb_build_object('id', r.id, 'rating', r.rating, 'comment', r.comment, 'created_at', r.created_at,
                    'edited_at', r.edited_at, 'can_edit', r.edited_at is null and r.created_at > now() - interval '48 hours')
                  from public.market_reviews r where r.order_id = o.id and r.product_id = l.product_id))
       order by l.sort) from public.market_order_lines l where l.order_id = o.id), '[]'::jsonb),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'message', e.message,
       'actor', e.actor, 'created_at', e.created_at) order by e.created_at, e.id)
       from public.market_order_events e where e.order_id = o.id and e.visible_to_customer), '[]'::jsonb),
    'can_cancel', o.status = 'pending' and o.payment_status <> 'seller_confirmed',
    'can_pay', false,
    'can_report_payment', o.payment_method = 'momo_direct' and o.payment_status = 'cod_pending'
       and o.status in ('pending', 'confirmed', 'processing', 'dispatched'),
    'can_confirm_receipt', o.status = 'delivered' and o.receipt_status in ('awaiting', 'resolved'),
    'can_report_problem', o.receipt_status <> 'confirmed',
    'can_review', app.review_gate(o) is null,
    'signed_in_owner', coalesce(o.customer_user_id = auth.uid(), false));
end $$;
commit;
