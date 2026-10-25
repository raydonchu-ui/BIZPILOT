-- BizPilot setup PART 16 of 19. Run parts in order.
begin;
create or replace function public.admin_set_config(p_key text, p_value jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if p_key not in ('trial', 'grace_days', 'renewal_notice_days', 'payment_instructions', 'support_contact', 'ai', 'marketplace') then
    perform app.raise('invalid_config_key');
  end if;
  if p_key = 'marketplace' then
    if jsonb_typeof(p_value) <> 'object'
       or coalesce((p_value ->> 'commission_pct')::numeric, 0) not between 0 and 50
       or coalesce((p_value ->> 'online_fee_pct')::numeric, 0) not between 0 and 20
       or coalesce((p_value ->> 'unpaid_order_minutes')::int, 30) not between 10 and 1440
       or coalesce((p_value ->> 'confirm_hours')::int, 48) not between 1 and 240
       or coalesce((p_value ->> 'max_open_cod_per_phone')::int, 3) not between 1 and 50 then
      perform app.raise('invalid_config_value');
    end if;
    insert into public.app_config (key, value, is_public) values ('marketplace', p_value, true)
    on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
  else
    update public.app_config set value = p_value, updated_at = now(), updated_by = auth.uid() where key = p_key;
  end if;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.config_changed', 'config', p_key, p_value);
end $$;
create or replace function app.admin_audit(act text, ent text, ent_id text, bid uuid, det jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details) values (bid, auth.uid(), act, ent, ent_id, det)
$$;
create or replace function public.admin_market_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return jsonb_build_object(
    'stores_published', (select count(*) from public.stores where status = 'published'),
    'stores_total', (select count(*) from public.stores),
    'stores_pending_verification', (select count(*) from public.stores where verification = 'pending'),
    'stores_suspended', (select count(*) from public.stores where status = 'suspended'),
    'listings', (select count(*) from public.products where online_published and status = 'active' and variant_of is null),
    'listings_hidden', (select count(*) from public.products where admin_hidden),
    'orders_30d', (select count(*) from public.market_orders where created_at > now() - interval '30 days'),
    'gmv_30d', (select coalesce(sum(total), 0) from public.market_orders where status = 'delivered' and delivered_at > now() - interval '30 days'),
    'open_reports', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'report'),
    'open_disputes', (select count(*) from public.market_reports where status in ('open', 'reviewing') and kind = 'dispute'),
    'refund_pending', (select count(*) from public.market_orders where payment_status = 'refund_pending'),
    'flagged_orders', (select count(*) from public.market_orders where flagged),
    'payment_issues', (select count(*) from public.online_payments where (mismatch or needs_refund) and refunded_at is null and resolution_note is null),
    'owed_to_sellers', (select coalesce(sum(b), 0) from (select sum(amount) b from public.market_ledger group by business_id) t where b > 0),
    'owed_by_sellers', (select coalesce(-sum(b), 0) from (select sum(amount) b from public.market_ledger group by business_id) t where b < 0));
end $$;
create or replace function public.admin_market_stores(p_search text default null, p_status text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select s.business_id, s.slug, s.name, s.city, s.status, s.verification, s.verification_note, s.suspended_reason,
           s.rating_avg, s.rating_count, s.published_at, s.created_at, b.name business_name, b.status business_status,
           (select u.email from public.business_members m join auth.users u on u.id = m.user_id
             where m.business_id = b.id and m.role = 'owner' and m.active) owner_email,
           (select count(*) from public.products p where p.business_id = s.business_id and p.online_published and p.variant_of is null) listings,
           (select count(*) from public.market_orders o where o.business_id = s.business_id and o.created_at > now() - interval '30 days') orders_30d,
           (select count(*) from public.market_reports r where r.business_id = s.business_id and r.status in ('open', 'reviewing')) open_reports,
           (select coalesce(sum(amount), 0) from public.market_ledger l where l.business_id = s.business_id) balance
      from public.stores s join public.businesses b on b.id = s.business_id
     where (p_status is null or s.status = p_status or (p_status = 'pending_verification' and s.verification = 'pending'))
       and (p_search is null or s.name ilike app.like_term(p_search) or s.slug ilike app.like_term(p_search) or b.name ilike app.like_term(p_search))
     order by (s.verification = 'pending') desc, s.created_at desc limit 200) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_store_update(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare s public.stores; reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.require_platform_admin();
  select * into s from public.stores where business_id = p_business for update;
  if not found then perform app.raise('not_found'); end if;
  if p ? 'status' then
    if p ->> 'status' not in ('draft', 'published', 'suspended') then perform app.raise('invalid_request'); end if;
    if p ->> 'status' = 'suspended' and reason is null then perform app.raise('reason_required'); end if;
    update public.stores set status = p ->> 'status',
           suspended_reason = case when p ->> 'status' = 'suspended' then reason end,
           published_at = case when p ->> 'status' = 'published' then coalesce(published_at, now()) else published_at end
     where business_id = p_business;
  end if;
  if p ? 'verification' then
    if p ->> 'verification' not in ('unverified', 'pending', 'verified', 'rejected') then perform app.raise('invalid_request'); end if;
    if p ->> 'verification' = 'rejected' and reason is null then perform app.raise('reason_required'); end if;
    update public.stores set verification = p ->> 'verification', verification_note = coalesce(reason, verification_note)
     where business_id = p_business;
  end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_store_status', case when p ->> 'status' = 'suspended' or p ->> 'verification' = 'rejected' then 'critical' else 'info' end,
          jsonb_build_object('status', coalesce(p ->> 'status', s.status), 'verification', coalesce(p ->> 'verification', s.verification),
                             'reason', reason), '/app/store', 'store.manage');
  perform app.admin_audit('admin.store_updated', 'store', p_business::text, p_business, p);
end $$;
create or replace function public.admin_market_listings(p_search text default null, p_hidden_only boolean default false,
  p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.name, p.brand, p.selling_price, p.online_images[1] image, p.admin_hidden, p.admin_hidden_reason, p.online_since,
           s.name store_name, s.slug store_slug, s.business_id,
           (select count(*) from public.market_reports r where r.target_type = 'product' and r.target_id = p.id and r.status in ('open', 'reviewing')) open_reports
      from public.products p join public.stores s on s.business_id = p.business_id
     where p.variant_of is null and (p.online_published or p.admin_hidden)
       and (not p_hidden_only or p.admin_hidden)
       and (p_search is null or p.name ilike app.like_term(p_search) or s.name ilike app.like_term(p_search))
     order by p.online_since desc nulls last limit least(p_limit, 200) offset greatest(p_offset, 0)) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_hide_product(p_product uuid, p_hidden boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare pr public.products;
begin
  perform app.require_platform_admin();
  if p_hidden and coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  update public.products set admin_hidden = p_hidden, admin_hidden_reason = case when p_hidden then btrim(p_reason) end
   where id = p_product returning * into pr;
  if not found then perform app.raise('not_found'); end if;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (pr.business_id, case when p_hidden then 'market_listing_hidden' else 'market_listing_restored' end,
          case when p_hidden then 'critical' else 'info' end,
          jsonb_build_object('product', pr.name, 'reason', p_reason), '/app/products/' || pr.id, 'products.manage');
  perform app.admin_audit(case when p_hidden then 'admin.listing_hidden' else 'admin.listing_restored' end, 'product', p_product::text,
                          pr.business_id, jsonb_build_object('name', pr.name, 'reason', p_reason));
end $$;
create or replace function public.admin_market_reports(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select r.*, s.name store_name, s.slug store_slug,
           case r.target_type when 'product' then (select name from public.products where id = r.target_id)
                              when 'store' then s.name
                              when 'order' then (select number from public.market_orders where id = r.target_id) end target_name,
           (select email from auth.users where id = r.reporter_user_id) reporter_email
      from public.market_reports r left join public.stores s on s.business_id = r.business_id
     where p_status is null or r.status = p_status or (p_status = 'open' and r.status = 'reviewing')
     order by r.created_at desc limit 200) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_report_update(p_report uuid, p_status text, p_resolution text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reports;
begin
  perform app.require_platform_admin();
  if p_status not in ('open', 'reviewing', 'resolved', 'dismissed') then perform app.raise('invalid_request'); end if;
  update public.market_reports set status = p_status, resolution = coalesce(nullif(btrim(coalesce(p_resolution, '')), ''), resolution),
         handled_by = auth.uid(), handled_at = now() where id = p_report returning * into r;
  if not found then perform app.raise('not_found'); end if;
  if r.kind = 'dispute' and r.order_id is not null and p_status in ('resolved', 'dismissed') then
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (r.order_id, r.business_id, 'dispute', p_status, r.resolution, 'admin', auth.uid());
  end if;
  perform app.admin_audit('admin.report_' || p_status, 'market_report', p_report::text, r.business_id,
                          jsonb_build_object('resolution', p_resolution));
end $$;
create or replace function public.admin_market_orders(p_filter text default 'attention', p_search text default null,
  p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select o.id, o.number, o.status, o.payment_method, o.payment_status, o.total, o.created_at, o.customer_name, o.customer_phone,
           o.flagged, o.flag_reason, s.name store_name, s.slug store_slug, o.business_id,
           exists (select 1 from public.market_reports r where r.order_id = o.id and r.status in ('open', 'reviewing')) open_dispute
      from public.market_orders o join public.stores s on s.business_id = o.business_id
     where (p_filter = 'all'
            or (p_filter = 'attention' and (o.flagged or o.payment_status = 'refund_pending'
                 or exists (select 1 from public.market_reports r where r.order_id = o.id and r.status in ('open', 'reviewing'))))
            or (p_filter = 'online' and o.payment_method = 'online')
            or (p_filter = 'refund_pending' and o.payment_status = 'refund_pending'))
       and (p_search is null or o.number ilike app.like_term(p_search) or o.customer_phone ilike app.like_term(p_search)
            or o.customer_name ilike app.like_term(p_search) or s.name ilike app.like_term(p_search))
     order by o.created_at desc limit least(p_limit, 200) offset greatest(p_offset, 0)) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_order(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.market_orders;
begin
  perform app.require_platform_admin();
  select * into o from public.market_orders where id = p_order;
  if not found then perform app.raise('not_found'); end if;
  return to_jsonb(o) - 'access_token_hash' || jsonb_build_object(
    'store', app.store_card(o.business_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) order by l.sort), '[]'::jsonb) from public.market_order_lines l where l.order_id = o.id),
    'events', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at, e.id), '[]'::jsonb) from public.market_order_events e where e.order_id = o.id),
    'payments', (select coalesce(jsonb_agg(to_jsonb(p) - 'link' order by p.created_at), '[]'::jsonb) from public.online_payments p where p.order_id = o.id),
    'reports', (select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at), '[]'::jsonb) from public.market_reports r where r.order_id = o.id));
end $$;
create or replace function public.admin_market_order_action(p_order uuid, p_action text, p jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare o public.market_orders; msg text := nullif(left(btrim(coalesce(p ->> 'message', '')), 1000), '');
        ref text := nullif(left(btrim(coalesce(p ->> 'reference', '')), 120), '');
begin
  perform app.require_platform_admin();
  select * into o from public.market_orders where id = p_order for update;
  if not found then perform app.raise('not_found'); end if;
  if p_action = 'note' then
    if msg is null then perform app.raise('message_required'); end if;
    insert into public.market_order_events (order_id, business_id, kind, message, actor, actor_user, visible_to_customer)
    values (o.id, o.business_id, 'message', msg, 'admin', auth.uid(), coalesce((p ->> 'visible')::boolean, true));
  elsif p_action = 'cancel' then
    if msg is null then perform app.raise('reason_required'); end if;
    perform app.market_cancel(o.id, 'admin', msg);
  elsif p_action = 'refund_done' then
    if o.payment_status <> 'refund_pending' then perform app.raise('invalid_order_status'); end if;
    if ref is null then perform app.raise('reference_required'); end if;
    update public.market_orders set payment_status = 'refunded', refunded_at = now(), refund_reference = ref,
           refund_amount = coalesce(refund_amount, total), flagged = false, flag_reason = null where id = o.id;
    update public.online_payments set needs_refund = false, refunded_at = now(), refund_reference = ref
     where order_id = o.id and status = 'successful' and refunded_at is null and (needs_refund or not mismatch);
    insert into public.market_order_events (order_id, business_id, kind, status, message, actor, actor_user)
    values (o.id, o.business_id, 'payment', 'refunded', 'refund_sent', 'admin', auth.uid());
  elsif p_action = 'clear_flag' then
    update public.market_orders set flagged = false, flag_reason = null where id = o.id;
  else
    perform app.raise('invalid_action');
  end if;
  perform app.admin_audit('admin.order_' || p_action, 'market_order', o.id::text, o.business_id,
                          jsonb_build_object('number', o.number, 'message', msg, 'reference', ref));
end $$;
create or replace function public.admin_market_payments(p_filter text default 'attention') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select p.id, p.kind, p.status, p.amount, p.amount_received, p.trans_id, p.medium, p.payer_name, p.mismatch, p.needs_refund,
           p.refunded_at, p.refund_reference, p.resolution_note, p.created_at, p.verified_at, p.plan_code, p.billing_period,
           o.number order_number, o.id order_id, b.name business_name
      from public.online_payments p join public.businesses b on b.id = p.business_id
      left join public.market_orders o on o.id = p.order_id
     where p_filter = 'all' or (p_filter = 'attention' and (p.mismatch or p.needs_refund) and p.refunded_at is null and p.resolution_note is null)
     order by p.created_at desc limit 200) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_payment_resolve(p_payment uuid, p_action text, p_note text, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare pay public.online_payments; o public.market_orders;
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  select * into pay from public.online_payments where id = p_payment for update;
  if not found or pay.status <> 'successful' then perform app.raise('not_found'); end if;
  if p_action = 'accept' and pay.mismatch then
    update public.online_payments set mismatch = false, resolution_note = p_note where id = pay.id;
    if pay.kind = 'subscription' then
      perform app.activate_fapshi_subscription(pay.id);
    else
      select * into o from public.market_orders where id = pay.order_id for update;
      if o.status = 'pending' and o.payment_status in ('awaiting_payment', 'failed') then
        update public.market_orders set payment_status = 'paid', expires_at = null, flagged = false, flag_reason = null where id = o.id;
        update public.stock_reservations set expires_at = null where order_id = o.id and released_at is null and consumed_at is null;
      else
        update public.online_payments set needs_refund = true where id = pay.id;
      end if;
    end if;
  elsif p_action = 'refunded' then
    if coalesce(btrim(p_reference), '') = '' then perform app.raise('reference_required'); end if;
    update public.online_payments set needs_refund = false, refunded_at = now(), refund_reference = btrim(p_reference),
           resolution_note = p_note where id = pay.id;
  else
    perform app.raise('invalid_action');
  end if;
  perform app.admin_audit('admin.payment_' || p_action, 'online_payment', pay.id::text, pay.business_id,
                          jsonb_build_object('note', p_note, 'reference', p_reference, 'trans_id', pay.trans_id));
end $$;
create or replace function public.admin_market_balances() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t order by t.balance desc) from (
    select s.business_id, s.name store_name, s.slug, s.phone, s.whatsapp,
           coalesce((select sum(amount) from public.market_ledger l where l.business_id = s.business_id), 0) balance,
           (select coalesce(sum(total), 0) from public.market_orders o where o.business_id = s.business_id and o.payment_method = 'online'
             and o.payment_status = 'paid' and o.status in ('pending', 'confirmed', 'processing', 'dispatched')) held_undelivered,
           (select max(created_at) from public.market_ledger l where l.business_id = s.business_id and l.kind = 'payout') last_payout_at
      from public.stores s
     where exists (select 1 from public.market_ledger l where l.business_id = s.business_id)
        or exists (select 1 from public.market_orders o where o.business_id = s.business_id and o.payment_method = 'online')) t), '[]'::jsonb);
end $$;
create or replace function public.admin_market_ledger(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(to_jsonb(l) || jsonb_build_object('order_number', o.number) order by l.created_at desc)
    from (select * from public.market_ledger where business_id = p_business order by created_at desc limit 300) l
    left join public.market_orders o on o.id = l.order_id), '[]'::jsonb);
end $$;
create or replace function public.admin_market_record_payout(p_business uuid, p_amount numeric, p_method text, p_reference text,
  p_note text default null, p_kind text default 'payout') returns bigint
language plpgsql security definer set search_path = public as $$
declare lid bigint;
begin
  perform app.require_platform_admin();
  if p_kind not in ('payout', 'adjustment') then perform app.raise('invalid_request'); end if;
  if p_amount is null or p_amount = 0 or (p_kind = 'payout' and p_amount < 0) then perform app.raise('invalid_amount'); end if;
  if coalesce(btrim(p_reference), '') = '' then perform app.raise('reference_required'); end if;
  if p_kind = 'adjustment' and coalesce(btrim(p_note), '') = '' then perform app.raise('reason_required'); end if;
  if not exists (select 1 from public.stores where business_id = p_business) then perform app.raise('not_found'); end if;
  insert into public.market_ledger (business_id, kind, amount, method, reference, note, created_by)
  values (p_business, p_kind, case when p_kind = 'payout' then -abs(p_amount) else p_amount end, nullif(p_method, ''),
          btrim(p_reference), nullif(btrim(coalesce(p_note, '')), ''), auth.uid())
  returning id into lid;
  insert into public.notifications (business_id, type, severity, params, link, required_perm)
  values (p_business, 'market_payout', 'success', jsonb_build_object('amount', abs(p_amount), 'reference', p_reference, 'kind', p_kind),
          '/app/payments', 'cash.manage');
  perform app.admin_audit('admin.' || p_kind || '_recorded', 'market_ledger', lid::text, p_business,
                          jsonb_build_object('amount', p_amount, 'method', p_method, 'reference', p_reference, 'note', p_note));
  return lid;
end $$;
create or replace function public.admin_market_block(p_kind text, p_value text, p_reason text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v text; bid uuid;
begin
  perform app.require_platform_admin();
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  v := case p_kind when 'phone' then app.norm_phone(p_value) when 'email' then lower(btrim(p_value))
                   when 'user' then app.try_uuid(p_value)::text end;
  if v is null then perform app.raise('invalid_request'); end if;
  insert into public.market_blocklist (kind, value, reason, created_by) values (p_kind, v, btrim(p_reason), auth.uid())
  on conflict (kind, value) do update set reason = excluded.reason returning id into bid;
  perform app.admin_audit('admin.contact_blocked', 'market_blocklist', bid::text, null, jsonb_build_object('kind', p_kind, 'reason', p_reason));
  return bid;
end $$;
create or replace function public.admin_market_unblock(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  delete from public.market_blocklist where id = p_id;
  perform app.admin_audit('admin.contact_unblocked', 'market_blocklist', p_id::text, null, null);
end $$;
create or replace function public.admin_market_hide_review(p_review uuid, p_hidden boolean, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r public.market_reviews;
begin
  perform app.require_platform_admin();
  update public.market_reviews set status = case when p_hidden then 'hidden' else 'visible' end,
         hidden_reason = case when p_hidden then p_reason end where id = p_review returning * into r;
  if not found then perform app.raise('not_found'); end if;
  perform app.refresh_store_rating(r.business_id);
  perform app.admin_audit(case when p_hidden then 'admin.review_hidden' else 'admin.review_restored' end, 'market_review',
                          p_review::text, r.business_id, jsonb_build_object('reason', p_reason));
end $$;
create or replace function public.admin_market_reviews(p_search text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select r.id, r.rating, r.comment, r.author_name, r.status, r.hidden_reason, r.created_at, p.name product_name, s.name store_name
      from public.market_reviews r join public.products p on p.id = r.product_id join public.stores s on s.business_id = r.business_id
     where p_search is null or r.comment ilike app.like_term(p_search) or s.name ilike app.like_term(p_search) or p.name ilike app.like_term(p_search)
     order by r.created_at desc limit 200) t), '[]'::jsonb);
end $$;
commit;
