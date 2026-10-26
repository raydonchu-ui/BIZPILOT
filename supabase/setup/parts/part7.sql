-- BizPilot setup PART 7 of 20. Run parts in order.
begin;
create or replace function public.admin_respond_support(p_request uuid, p_status text, p_response text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  update public.support_requests set status = p_status,
    admin_response = coalesce(nullif(p_response, ''), admin_response),
    responded_by = auth.uid(), responded_at = now()
  where id = p_request;
  insert into public.audit_logs (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'admin.support_updated', 'support_request', p_request::text, jsonb_build_object('status', p_status));
end $$;
create or replace function public.admin_add_platform_admin(p_email text)
returns void language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform app.require_platform_admin();
  select id into uid from auth.users where lower(email) = lower(btrim(p_email)) and email_confirmed_at is not null;
  if uid is null then perform app.raise('user_not_found'); end if;
  insert into public.platform_admins (user_id, note) values (uid, 'added by ' || auth.uid()) on conflict do nothing;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (auth.uid(), 'admin.admin_added', 'user', uid::text);
end $$;
create or replace function public.admin_ai_usage()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  return coalesce((select jsonb_agg(t) from (
    select date_trunc('day', created_at)::date as day, count(*) as queries,
           count(*) filter (where status = 'completed') as completed,
           count(*) filter (where status = 'failed') as failed,
           count(*) filter (where status = 'fallback') as fallback,
           coalesce(sum(input_tokens), 0) as input_tokens, coalesce(sum(output_tokens), 0) as output_tokens,
           count(distinct business_id) as businesses
    from public.ai_queries where created_at > now() - interval '30 days'
    group by 1 order by 1 desc) t), '[]'::jsonb);
end $$;
create or replace function public.grant_support_access(p_business uuid, p_hours int, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  perform app.require_perm(p_business, 'settings.manage');
  if coalesce(btrim(p_reason), '') = '' then perform app.raise('reason_required'); end if;
  insert into public.support_access_grants (business_id, granted_by, reason, expires_at)
  values (p_business, auth.uid(), btrim(p_reason), now() + make_interval(hours => least(greatest(p_hours, 1), 72)))
  returning id into gid;
  perform app.audit(p_business, 'support_access.granted', 'support_access', gid::text,
                    jsonb_build_object('hours', p_hours, 'reason', p_reason));
  return gid;
end $$;
create or replace function public.revoke_support_access(p_grant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g public.support_access_grants;
begin
  select * into g from public.support_access_grants where id = p_grant;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(g.business_id, 'settings.manage');
  update public.support_access_grants set revoked_at = now() where id = p_grant;
  perform app.audit(g.business_id, 'support_access.revoked', 'support_access', p_grant::text);
end $$;
create or replace function public.admin_open_support_session(p_business uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform app.require_platform_admin();
  if not exists (select 1 from public.support_access_grants where business_id = p_business
                 and revoked_at is null and expires_at > now()) then
    perform app.raise('no_support_access');
  end if;
  insert into public.audit_logs (business_id, user_id, action, entity, entity_id, details)
  values (p_business, auth.uid(), 'admin.support_session_opened', 'business', p_business::text,
          jsonb_build_object('reason', p_reason));
end $$;
create or replace function public.submit_support_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; uid uuid := auth.uid(); bid uuid := nullif(p ->> 'business_id', '')::uuid; em text;
begin
  em := lower(btrim(coalesce(p ->> 'email', (select email from auth.users where id = uid), '')));
  if uid is null and em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform app.raise('invalid_email'); end if;
  perform app.rate_limit('support:' || coalesce(uid::text, em), 5, 3600);
  if bid is not null and not app.is_member(bid) then bid := null; end if;
  insert into public.support_requests (business_id, user_id, name, email, phone, category, subject, message)
  values (bid, uid, nullif(p ->> 'name', ''), nullif(em, ''), nullif(p ->> 'phone', ''),
          coalesce(nullif(p ->> 'category', ''), 'question'), btrim(p ->> 'subject'), btrim(p ->> 'message'))
  returning id into rid;
  return rid;
end $$;
create or replace function app.build_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
declare today date; n int := 0; c int; st public.business_settings; sub jsonb; r record; added int;
begin
  today := app.biz_today(p_business);
  select * into st from public.business_settings where business_id = p_business;
  select count(*) into c from public.products where business_id = p_business and status = 'active'
     and qty_on_hand <= 0 and exists (select 1 from public.stock_movements m where m.product_id = products.id);
  if c > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'out_of_stock', 'critical', jsonb_build_object('count', c), '/app/inventory?filter=out',
            'out_of_stock:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  select count(*) into c from public.products where business_id = p_business and status = 'active'
     and qty_on_hand > 0 and qty_on_hand <= greatest(min_stock, 0) and min_stock > 0;
  if c > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'low_stock', 'warning', jsonb_build_object('count', c), '/app/inventory?filter=low',
            'low_stock:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  select count(*), min(expiry_date) into r from public.stock_batches
   where business_id = p_business and remaining_qty > 0 and expiry_date <= today + st.expiry_alert_days;
  if r.count > 0 then
    insert into public.notifications (business_id, type, severity, params, link, dedupe_key)
    values (p_business, 'expiring_soon', 'warning', jsonb_build_object('count', r.count, 'first_expiry', r.min),
            '/app/inventory?tab=expiry', 'expiring:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  for r in select pu.id, pu.number, pu.due_date, pu.total - pu.credited_total - pu.paid_total as owed, s.name
           from public.purchases pu join public.suppliers s on s.id = pu.supplier_id
           where pu.business_id = p_business and pu.status in ('ordered', 'partially_received', 'received')
             and pu.due_date is not null and pu.due_date <= today + 3
             and pu.total - pu.credited_total - pu.paid_total > 0 loop
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, case when r.due_date < today then 'supplier_payment_overdue' else 'supplier_payment_due' end,
            case when r.due_date < today then 'critical' else 'warning' end,
            jsonb_build_object('supplier', r.name, 'number', r.number, 'due_date', r.due_date, 'amount', r.owed),
            '/app/purchases/' || r.id, 'purchases.manage',
            'supplier_due:' || r.id || ':' || (r.due_date < today)) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end loop;
  select count(*), coalesce(sum(s.total - s.returned_total + s.refunded_total - s.paid_total), 0) into r
    from public.sales s where s.business_id = p_business and s.customer_id is not null
     and s.due_date is not null and s.due_date < today and s.total - s.returned_total + s.refunded_total - s.paid_total > 0;
  if r.count > 0 then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'customer_overdue', 'warning', jsonb_build_object('count', r.count, 'amount', r.coalesce),
            '/app/customers?filter=overdue', 'customers.credit', 'customer_overdue:' || today) on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  sub := app.subscription_info(p_business);
  if sub ->> 'state' in ('renewal_due', 'grace', 'expired') or
     (sub ->> 'state' = 'trial' and (sub ->> 'trial_ends_at')::timestamptz < now() + interval '5 days') then
    insert into public.notifications (business_id, type, severity, params, link, required_perm, dedupe_key)
    values (p_business, 'subscription_' || (sub ->> 'state'),
            case when sub ->> 'state' in ('grace', 'expired') then 'critical' else 'warning' end,
            sub, '/app/billing', 'billing.manage',
            'subscription:' || (sub ->> 'state') || ':' || coalesce(sub ->> 'current_period_end', sub ->> 'trial_ends_at', ''))
    on conflict do nothing;
    get diagnostics added = row_count; n := n + added;
  end if;
  return n;
end $$;
create or replace function public.generate_alerts(p_business uuid)
returns int language plpgsql security definer set search_path = public as $$
begin
  if not app.is_member(p_business) then perform app.raise('permission_denied'); end if;
  return app.build_alerts(p_business);
end $$;
create or replace function app.generate_all_alerts()
returns int language plpgsql security definer set search_path = public as $$
declare b uuid; n int := 0;
begin
  for b in select id from public.businesses loop
    n := n + app.build_alerts(b);
  end loop;
  return n;
end $$;
revoke all on function app.build_alerts(uuid) from public, anon, authenticated;
revoke all on function app.generate_all_alerts() from public, anon, authenticated;
create or replace function public.mark_notifications_read(p_business uuid, p_ids uuid[] default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not app.is_member(p_business) then perform app.raise('permission_denied'); end if;
  insert into public.notification_reads (notification_id, user_id)
  select id, auth.uid() from public.notifications
   where business_id = p_business and (p_ids is null or id = any (p_ids))
  on conflict do nothing;
end $$;
create or replace function public.ai_begin_query(p_business uuid, p_question text, p_from date, p_to date)
returns uuid language plpgsql security definer set search_path = public as $$
declare qid uuid;
begin
  perform app.require_perm(p_business, 'reports.view');
  perform app.require_feature(p_business, 'ai_advisor');
  if coalesce(btrim(p_question), '') = '' or length(p_question) > 1000 then perform app.raise('invalid_question'); end if;
  perform app.rate_limit('ai:' || auth.uid(), 20, 3600);
  perform app.check_limit(p_business, 'ai_queries_per_month');
  insert into public.ai_queries (business_id, user_id, question, period_from, period_to)
  values (p_business, auth.uid(), btrim(p_question), p_from, p_to) returning id into qid;
  return qid;
end $$;
create or replace function public.ai_complete_query(p_query uuid, p_status text, p_answer text, p_model text,
  p_input_tokens int default null, p_output_tokens int default null, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status not in ('completed', 'failed', 'fallback') then perform app.raise('invalid_status'); end if;
  update public.ai_queries set status = p_status, answer = p_answer, model = p_model, input_tokens = p_input_tokens,
         output_tokens = p_output_tokens, error = left(p_error, 500), completed_at = now()
   where id = p_query and user_id = auth.uid() and status = 'started';
  if not found then perform app.raise('not_found'); end if;
end $$;
create or replace function app.num_or_null(v text) returns numeric language plpgsql immutable as $$
begin
  if v is null or btrim(v) = '' then return null; end if;
  return replace(replace(btrim(v), ' ', ''), ',', '.')::numeric;
exception when others then
  return 'NaN'::numeric;
end $$;
create or replace function public.preview_product_import(p_business uuid, p_rows jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; i int := 0; errs text[]; out jsonb := '[]'; seen_sku text[] := '{}'; seen_bc text[] := '{}';
        v_sku text; v_bc text; ok int := 0; bad int := 0; v numeric; f text;
begin
  perform app.require_perm(p_business, 'imports.manage');
  if jsonb_typeof(p_rows) <> 'array' then perform app.raise('invalid_file'); end if;
  if jsonb_array_length(p_rows) > 2000 then perform app.raise('too_many_rows'); end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1; errs := '{}';
    if coalesce(btrim(r ->> 'name'), '') = '' then errs := errs || 'name_required'::text; end if;
    v_sku := lower(btrim(coalesce(r ->> 'sku', '')));
    if v_sku <> '' then
      if v_sku = any (seen_sku) then errs := errs || 'duplicate_sku_in_file'::text;
      elsif exists (select 1 from public.products where business_id = p_business and lower(products.sku) = v_sku) then
        errs := errs || 'duplicate_sku'::text;
      end if;
      seen_sku := seen_sku || v_sku;
    end if;
    v_bc := btrim(coalesce(r ->> 'barcode', ''));
    if v_bc <> '' then
      if v_bc = any (seen_bc) then errs := errs || 'duplicate_barcode_in_file'::text;
      elsif exists (select 1 from public.products where business_id = p_business and barcode = v_bc) then
        errs := errs || 'duplicate_barcode'::text;
      end if;
      seen_bc := seen_bc || v_bc;
    end if;
    foreach f in array array['purchase_cost', 'selling_price', 'min_stock', 'opening_qty', 'opening_unit_cost'] loop
      v := app.num_or_null(r ->> f);
      if v = 'NaN'::numeric then errs := errs || ('invalid_number:' || f);
      elsif v < 0 then errs := errs || ('negative_number:' || f); end if;
    end loop;
    if app.num_or_null(r ->> 'opening_qty') > 0 and app.num_or_null(r ->> 'opening_qty') <> trunc(app.num_or_null(r ->> 'opening_qty'))
       and lower(coalesce(r ->> 'allow_fraction', '')) not in ('yes', 'true', '1', 'oui') then
      errs := errs || 'fractional_quantity_not_allowed'::text;
    end if;
    if cardinality(errs) = 0 then ok := ok + 1; else bad := bad + 1; end if;
    out := out || jsonb_build_object('row', i, 'ok', cardinality(errs) = 0, 'errors', to_jsonb(errs));
  end loop;
  return jsonb_build_object('rows', out, 'valid', ok, 'invalid', bad, 'total', i,
    'limit', app.plan_limit(p_business, 'max_products'), 'current_products', app.usage_count(p_business, 'max_products'));
end $$;
create or replace function public.import_products(p_business uuid, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pv jsonb; r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]';
        pid uuid; cat uuid; sku text; oq numeric; oc numeric; lim numeric; known boolean;
begin
  perform app.require_perm(p_business, 'imports.manage');
  perform app.require_feature(p_business, 'import');
  pv := public.preview_product_import(p_business, p_rows);
  lim := app.plan_limit(p_business, 'max_products');
  if lim is not null and app.usage_count(p_business, 'max_products') + (pv ->> 'valid')::int > lim then
    perform app.raise('plan_limit_reached', jsonb_build_object('limit', 'max_products', 'max', lim,
      'used', app.usage_count(p_business, 'max_products')));
  end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, 'products', p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    if not ((pv -> 'rows' -> (i - 1)) ->> 'ok')::boolean then
      skipped := skipped + 1;
      v_issues := v_issues || jsonb_build_object('row', i, 'errors', (pv -> 'rows' -> (i - 1)) -> 'errors');
      continue;
    end if;
    cat := null;
    if coalesce(btrim(r ->> 'category'), '') <> '' then
      insert into public.categories (business_id, name) values (p_business, btrim(r ->> 'category'))
      on conflict (business_id, lower(name)) do nothing;
      select id into cat from public.categories where business_id = p_business and lower(name) = lower(btrim(r ->> 'category'));
    end if;
    sku := coalesce(nullif(btrim(r ->> 'sku'), ''), app.next_number(p_business, 'sku', 'SKU-'));
    insert into public.products (business_id, name, sku, barcode, category_id, brand, description, base_unit,
      allow_fraction, purchase_cost, selling_price, min_stock, location, import_batch_id, created_by)
    values (p_business, btrim(r ->> 'name'), sku, nullif(btrim(r ->> 'barcode'), ''), cat, nullif(r ->> 'brand', ''),
      nullif(r ->> 'description', ''), coalesce(nullif(btrim(r ->> 'base_unit'), ''), 'piece'),
      lower(coalesce(r ->> 'allow_fraction', '')) in ('yes', 'true', '1', 'oui'),
      coalesce(app.num_or_null(r ->> 'purchase_cost'), 0), coalesce(app.num_or_null(r ->> 'selling_price'), 0),
      coalesce(app.num_or_null(r ->> 'min_stock'), 0), nullif(r ->> 'location', ''), bid, auth.uid())
    returning id into pid;
    oq := coalesce(app.num_or_null(r ->> 'opening_qty'), 0);
    if oq > 0 then
      oc := app.num_or_null(r ->> 'opening_unit_cost');
      known := oc is not null;
      oc := coalesce(oc, app.num_or_null(r ->> 'purchase_cost'), 0);
      perform app.apply_movement(p_business, pid, 'opening', oq, oc, 'import', bid, null, 'Imported opening stock',
                                 null, not known);
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.products', 'import_batch', bid::text,
                    jsonb_build_object('created', created, 'skipped', skipped, 'file', p_file_name));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;
create or replace function public.rollback_import(p_batch uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b public.import_batches; blocked text[]; n int;
begin
  select * into b from public.import_batches where id = p_batch for update;
  if not found then perform app.raise('not_found'); end if;
  perform app.require_perm(b.business_id, 'imports.manage');
  if b.status <> 'completed' then perform app.raise('already_rolled_back'); end if;
  if b.kind = 'products' then
    select array_agg(p.name) into blocked from public.products p where p.import_batch_id = p_batch and (
      exists (select 1 from public.stock_movements m where m.product_id = p.id and not (m.ref_type = 'import' and m.ref_id = p_batch))
      or exists (select 1 from public.sale_lines where product_id = p.id)
      or exists (select 1 from public.purchase_lines where product_id = p.id)
      or exists (select 1 from public.stock_count_lines where product_id = p.id));
    if blocked is not null then
      perform app.raise('import_has_activity', jsonb_build_object('products', to_jsonb(blocked[1:10])));
    end if;
    delete from public.stock_movements where ref_type = 'import' and ref_id = p_batch;
    delete from public.products where import_batch_id = p_batch;
    get diagnostics n = row_count;
  elsif b.kind = 'suppliers' then
    if exists (select 1 from public.suppliers s where s.import_batch_id = p_batch and (
         exists (select 1 from public.purchases where supplier_id = s.id)
         or exists (select 1 from public.payments where supplier_id = s.id))) then
      perform app.raise('import_has_activity');
    end if;
    update public.products set preferred_supplier_id = null
     where preferred_supplier_id in (select id from public.suppliers where import_batch_id = p_batch);
    delete from public.suppliers where import_batch_id = p_batch;
    get diagnostics n = row_count;
  else
    if exists (select 1 from public.customers c where c.import_batch_id = p_batch and (
         exists (select 1 from public.sales where customer_id = c.id)
         or exists (select 1 from public.payments where customer_id = c.id))) then
      perform app.raise('import_has_activity');
    end if;
    delete from public.customers where import_batch_id = p_batch;
    get diagnostics n = row_count;
  end if;
  update public.import_batches set status = 'rolled_back', rolled_back_at = now(), rolled_back_by = auth.uid()
   where id = p_batch;
  perform app.audit(b.business_id, 'import.rolled_back', 'import_batch', p_batch::text, jsonb_build_object('removed', n));
  return jsonb_build_object('removed', n);
end $$;
create or replace function public.import_parties(p_business uuid, p_kind text, p_rows jsonb, p_file_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; i int := 0; bid uuid; created int := 0; skipped int := 0; v_issues jsonb := '[]'; nm text;
begin
  if p_kind = 'suppliers' then
    perform app.require_perm(p_business, 'suppliers.manage');
    perform app.require_feature(p_business, 'suppliers');
  elsif p_kind = 'customers' then
    perform app.require_perm(p_business, 'customers.manage');
  else
    perform app.raise('invalid_kind');
  end if;
  perform app.require_feature(p_business, 'import');
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then perform app.raise('invalid_file'); end if;
  insert into public.import_batches (business_id, kind, file_name, total_rows, created_by)
  values (p_business, p_kind, p_file_name, jsonb_array_length(p_rows), auth.uid()) returning id into bid;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    nm := btrim(coalesce(r ->> 'name', ''));
    if nm = '' then
      skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["name_required"]'::jsonb);
      continue;
    end if;
    if p_kind = 'suppliers' then
      if exists (select 1 from public.suppliers where business_id = p_business and lower(name) = lower(nm)) then
        skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["duplicate_name"]'::jsonb);
        continue;
      end if;
      insert into public.suppliers (business_id, name, contact_person, phone, email, address, reference,
                                    payment_terms_days, notes, import_batch_id, created_by)
      values (p_business, nm, nullif(r ->> 'contact_person', ''), nullif(r ->> 'phone', ''), nullif(r ->> 'email', ''),
              nullif(r ->> 'address', ''), nullif(r ->> 'reference', ''),
              case when app.num_or_null(r ->> 'payment_terms_days') >= 0 then app.num_or_null(r ->> 'payment_terms_days')::int end,
              nullif(r ->> 'notes', ''), bid, auth.uid());
    else
      if exists (select 1 from public.customers where business_id = p_business and
                 (lower(name) = lower(nm) and coalesce(phone, '') = coalesce(nullif(r ->> 'phone', ''), ''))) then
        skipped := skipped + 1; v_issues := v_issues || jsonb_build_object('row', i, 'errors', '["duplicate_name"]'::jsonb);
        continue;
      end if;
      insert into public.customers (business_id, name, phone, email, address, notes, import_batch_id, created_by)
      values (p_business, nm, nullif(r ->> 'phone', ''), nullif(r ->> 'email', ''), nullif(r ->> 'address', ''),
              nullif(r ->> 'notes', ''), bid, auth.uid());
    end if;
    created := created + 1;
  end loop;
  update public.import_batches set created_count = created, skipped_count = skipped, issues = v_issues where id = bid;
  perform app.audit(p_business, 'import.' || p_kind, 'import_batch', bid::text, jsonb_build_object('created', created));
  return jsonb_build_object('batch_id', bid, 'created', created, 'skipped', skipped, 'issues', v_issues);
end $$;
create or replace function public.export_business_data(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb := '{}'; t text; part jsonb;
begin
  perform app.require_perm(p_business, 'settings.manage');
  res := jsonb_build_object('exported_at', now(), 'format_version', 1,
    'business', (select to_jsonb(b) from public.businesses b where id = p_business),
    'settings', (select to_jsonb(s) from public.business_settings s where business_id = p_business));
  foreach t in array array['categories', 'suppliers', 'customers', 'products', 'product_units', 'stock_batches',
    'stock_movements', 'stock_counts', 'stock_count_lines', 'purchases', 'purchase_lines', 'purchase_receipts',
    'purchase_receipt_lines', 'supplier_credits', 'supplier_returns', 'supplier_return_lines', 'sales', 'sale_lines',
    'sale_returns', 'sale_return_lines', 'payments', 'payment_allocations', 'expenses', 'cash_accounts',
    'cash_movements', 'cash_reconciliations', 'cash_reconciliation_lines', 'attachments']::text[] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x where business_id = $1', t)
      into part using p_business;
    res := res || jsonb_build_object(t, part);
  end loop;
  return res;
end $$;
alter table public.notifications enable row level security;
commit;
