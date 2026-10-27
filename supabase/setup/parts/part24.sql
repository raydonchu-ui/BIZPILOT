-- BizPilot setup PART 24 of 24. Run parts in order.
begin;
create or replace function public.ai_send_message(p_business uuid, p_conversation uuid, p_text text, p_lang text default 'en',
  p_from date default null, p_to date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); txt text := btrim(coalesce(p_text, '')); conv uuid := p_conversation; d1 date; d2 date;
  ans jsonb; lang text := case when p_lang = 'fr' then 'fr' else 'en' end; used numeric;
begin
  perform app.ai_manager_gate(p_business);
  if length(txt) < 1 or length(txt) > 1000 then perform app.raise('invalid_question'); end if;
  perform app.rate_limit('ai_manager:' || uid, 30, 3600);
  perform app.check_limit(p_business, 'ai_queries_per_month');
  d2 := coalesce(p_to, app.biz_today(p_business));
  d1 := coalesce(p_from, d2 - 6);
  if d1 > d2 or d2 - d1 > 366 then perform app.raise('invalid_period'); end if;
  if conv is null then
    insert into public.ai_conversations (business_id, user_id, title) values (p_business, uid, left(txt, 120)) returning id into conv;
  elsif not exists (select 1 from public.ai_conversations where id = conv and business_id = p_business and user_id = uid) then
    perform app.raise('not_found');
  end if;
  insert into public.ai_messages (conversation_id, business_id, user_id, role, content) values (conv, p_business, uid, 'user', txt);
  ans := app.ai_answer(p_business, txt, lang, d1, d2);
  insert into public.ai_messages (conversation_id, business_id, user_id, role, content, intent, data)
  values (conv, p_business, uid, 'assistant', ans ->> 'text', ans ->> 'intent', ans -> 'data');
  update public.ai_conversations set updated_at = now() where id = conv;
  insert into public.ai_queries (business_id, user_id, question, answer, model, status, period_from, period_to, completed_at)
  values (p_business, uid, txt, ans ->> 'text', 'bizpilot-rules', 'completed', d1, d2, now());
  used := app.usage_count(p_business, 'ai_queries_per_month');
  return jsonb_build_object('conversation_id', conv, 'intent', ans ->> 'intent', 'text', ans ->> 'text', 'data', ans -> 'data',
    'suggestions', case when lang = 'fr' then jsonb_build_array('Quel chiffre d’affaires ai-je enregistré cette semaine ?', 'Quels produits doivent être réapprovisionnés ?',
                          'Résumez mes commandes en attente.', 'Préparez mon rapport de ventes hebdomadaire.', 'Quels produits se vendent lentement ?')
                   else jsonb_build_array('How much revenue did I record this week?', 'Which products need restocking?',
                          'Summarize my outstanding orders.', 'Create my weekly sales report.', 'Which products are slow-moving?') end,
    'usage', jsonb_build_object('used', used, 'limit', app.plan_limit(p_business, 'ai_queries_per_month')));
end $$;
create or replace function public.ai_propose_action(p_business uuid, p_kind text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare aid uuid; preview jsonb; title text; lang text := 'en';
begin
  perform app.ai_manager_gate(p_business);
  perform app.rate_limit('ai_action:' || auth.uid(), 20, 3600);
  if p_kind = 'draft_restock_list' then
    title := 'Draft restock list';
    preview := jsonb_build_object('lines', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'on_hand', p.qty_on_hand, 'suggested_qty',
                       greatest(ceil(p.min_stock * 2 - p.qty_on_hand), 1)))
        from public.products p where p.business_id = p_business and p.status = 'active' and p.variant_of is null
         and p.min_stock > 0 and p.qty_on_hand <= p.min_stock), '[]'::jsonb),
      'note', 'Saved as a draft. No purchase order, payment or stock change is made.');
  elsif p_kind = 'draft_product_copy' then
    title := 'Draft product text';
    if not exists (select 1 from public.products where id = (p_payload ->> 'product_id')::uuid and business_id = p_business) then
      perform app.raise('not_found');
    end if;
    preview := app.ai_product_copy(p_business, (p_payload ->> 'product_id')::uuid, lang);
  elsif p_kind in ('draft_promotion', 'change_price', 'adjust_stock', 'refund', 'send_message', 'create_promotion', 'place_supplier_order') then
    title := initcap(replace(p_kind, '_', ' '));
    preview := jsonb_build_object('requested', p_payload, 'note', 'Recorded as a proposal only. This action is not available yet.');
  else
    perform app.raise('invalid_request');
  end if;
  insert into public.ai_action_requests (business_id, user_id, kind, title, preview, payload)
  values (p_business, auth.uid(), p_kind, title, preview, coalesce(p_payload, '{}'::jsonb)) returning id into aid;
  return jsonb_build_object('action_id', aid, 'kind', p_kind, 'title', title, 'preview', preview, 'status', 'proposed');
end $$;
create or replace function public.ai_confirm_action(p_action uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.ai_action_requests; did uuid;
begin
  select * into a from public.ai_action_requests where id = p_action for update;
  if not found or a.user_id <> auth.uid() then perform app.raise('not_found'); end if;
  perform app.ai_manager_gate(a.business_id);
  if a.status <> 'proposed' then perform app.raise('invalid_status'); end if;
  if a.kind = 'draft_restock_list' then
    insert into public.supplier_draft_lists (business_id, created_by, title, lines, source_action_id)
    values (a.business_id, auth.uid(), 'Restock draft ' || to_char(now(), 'YYYY-MM-DD'), coalesce(a.preview -> 'lines', '[]'::jsonb), a.id)
    returning id into did;
    update public.ai_action_requests set status = 'executed', decided_at = now(), result = jsonb_build_object('draft_id', did) where id = a.id;
  elsif a.kind = 'draft_product_copy' then
    update public.ai_action_requests set status = 'executed', decided_at = now(), result = jsonb_build_object('saved', true) where id = a.id;
  else
    perform app.raise('action_not_enabled');
  end if;
  perform app.audit(a.business_id, 'ai.action_executed', 'ai_action', a.id::text, jsonb_build_object('kind', a.kind));
  return jsonb_build_object('action_id', a.id, 'status', 'executed', 'result', (select result from public.ai_action_requests where id = a.id));
end $$;
create or replace function public.ai_cancel_action(p_action uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a public.ai_action_requests;
begin
  select * into a from public.ai_action_requests where id = p_action for update;
  if not found or a.user_id <> auth.uid() then perform app.raise('not_found'); end if;
  perform app.ai_manager_gate(a.business_id);
  if a.status <> 'proposed' then perform app.raise('invalid_status'); end if;
  update public.ai_action_requests set status = 'cancelled', decided_at = now() where id = a.id;
end $$;
create or replace function public.ai_list_conversations(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.ai_manager_gate(p_business);
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'updated_at', c.updated_at) order by c.updated_at desc)
                     from (select * from public.ai_conversations where business_id = p_business and user_id = auth.uid()
                           order by updated_at desc limit 30) c), '[]'::jsonb);
end $$;
create or replace function public.ai_get_conversation(p_conversation uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.ai_conversations;
begin
  select * into c from public.ai_conversations where id = p_conversation and user_id = auth.uid();
  if not found then perform app.raise('not_found'); end if;
  perform app.ai_manager_gate(c.business_id);
  return jsonb_build_object('id', c.id, 'title', c.title, 'messages', coalesce((
    select jsonb_agg(jsonb_build_object('role', m.role, 'content', m.content, 'intent', m.intent, 'data', m.data, 'created_at', m.created_at)
                     order by m.id) from public.ai_messages m where m.conversation_id = c.id), '[]'::jsonb));
end $$;
create or replace function public.ai_clear_history(p_business uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform app.ai_manager_gate(p_business);
  delete from public.ai_conversations where business_id = p_business and user_id = auth.uid();
  get diagnostics n = row_count;
  perform app.audit(p_business, 'ai.history_cleared', 'ai_conversation', null, jsonb_build_object('conversations', n));
  return n;
end $$;
create or replace function public.ai_product_text(p_business uuid, p_product uuid, p_lang text default 'en') returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.ai_manager_gate(p_business);
  return app.ai_product_copy(p_business, p_product, case when p_lang = 'fr' then 'fr' else 'en' end);
end $$;
revoke all on function app.ai_snapshot(uuid, date, date), app.ai_answer(uuid, text, text, date, date),
  app.ai_product_copy(uuid, uuid, text), app.ai_manager_gate(uuid), app.ai_money(numeric) from public, anon, authenticated;
revoke all on function public.ai_send_message(uuid, uuid, text, text, date, date), public.ai_propose_action(uuid, text, jsonb),
  public.ai_confirm_action(uuid), public.ai_cancel_action(uuid), public.ai_list_conversations(uuid),
  public.ai_get_conversation(uuid), public.ai_clear_history(uuid), public.ai_product_text(uuid, uuid, text) from public, anon;
grant execute on function public.ai_send_message(uuid, uuid, text, text, date, date), public.ai_propose_action(uuid, text, jsonb),
  public.ai_confirm_action(uuid), public.ai_cancel_action(uuid), public.ai_list_conversations(uuid),
  public.ai_get_conversation(uuid), public.ai_clear_history(uuid), public.ai_product_text(uuid, uuid, text) to authenticated;
commit;
