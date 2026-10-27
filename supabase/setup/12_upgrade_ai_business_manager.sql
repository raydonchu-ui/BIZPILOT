-- BizPilot upgrade: check_before_12 20261028000300_ai_business_manager 
-- Paste into Supabase Dashboard -> SQL Editor -> New query, then Run. Run it ONCE.
-- Adds features only: existing businesses, products, sales and users are not changed.
begin;

-- ===== check_before_12.sql =====
do $$
begin
  if to_regprocedure('public.ai_send_message(uuid,uuid,text,text,date,date)') is null
     and to_regclass('public.ai_queries') is null then
    raise exception 'Run 11_upgrade_payments_verified_premium.sql (and the earlier upgrades) first, then run this file again.';
  end if;
  if to_regprocedure('public.billing_payment_cancel(uuid)') is null
     or to_regprocedure('public.verification_apply(uuid,jsonb)') is null then
    raise exception 'Run 11_upgrade_payments_verified_premium.sql first, then run this file again.';
  end if;
end $$;

-- ===== 20261028000300_ai_business_manager.sql =====
create table if not exists public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  title text not null check (length(title) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ai_conversations_owner on public.ai_conversations (business_id, user_id, updated_at desc);
create table if not exists public.ai_messages (
  id bigserial primary key,
  conversation_id uuid not null references public.ai_conversations (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null check (length(content) <= 6000),
  intent text,
  data jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ai_messages_conversation on public.ai_messages (conversation_id, id);
create table if not exists public.ai_action_requests (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('draft_restock_list', 'draft_product_copy', 'draft_promotion', 'change_price',
    'adjust_stock', 'refund', 'send_message', 'create_promotion', 'place_supplier_order')),
  title text not null check (length(title) <= 160),
  preview jsonb not null default '{}'::jsonb,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'proposed' check (status in ('proposed', 'executed', 'cancelled', 'refused')),
  result jsonb,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index if not exists ai_action_requests_owner on public.ai_action_requests (business_id, created_at desc);
create table if not exists public.supplier_draft_lists (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  created_by uuid references auth.users (id) on delete set null,
  title text not null check (length(title) <= 160),
  lines jsonb not null default '[]'::jsonb,
  source_action_id uuid references public.ai_action_requests (id) on delete set null,
  status text not null default 'draft' check (status in ('draft', 'archived')),
  created_at timestamptz not null default now()
);
create index if not exists supplier_draft_lists_business on public.supplier_draft_lists (business_id, created_at desc);
alter table public.ai_conversations enable row level security;
alter table public.ai_messages enable row level security;
alter table public.ai_action_requests enable row level security;
alter table public.supplier_draft_lists enable row level security;
drop policy if exists ai_conversations_owner on public.ai_conversations;
create policy ai_conversations_owner on public.ai_conversations for select
  using (user_id = auth.uid() and app.has_perm(business_id, 'reports.view'));
drop policy if exists ai_messages_owner on public.ai_messages;
create policy ai_messages_owner on public.ai_messages for select
  using (user_id = auth.uid() and app.has_perm(business_id, 'reports.view'));
drop policy if exists ai_actions_owner on public.ai_action_requests;
create policy ai_actions_owner on public.ai_action_requests for select
  using (user_id = auth.uid() and app.has_perm(business_id, 'reports.view'));
drop policy if exists supplier_drafts_read on public.supplier_draft_lists;
create policy supplier_drafts_read on public.supplier_draft_lists for select
  using (app.has_perm(business_id, 'purchases.manage') or app.has_perm(business_id, 'reports.view'));
revoke all on public.ai_conversations, public.ai_messages, public.ai_action_requests, public.supplier_draft_lists from anon, authenticated;
grant select on public.ai_conversations, public.ai_messages, public.ai_action_requests, public.supplier_draft_lists to authenticated;
create or replace function app.ai_money(n numeric) returns text
language sql immutable as $$
  select translate(to_char(round(coalesce(n, 0)), 'FM999,999,999,990'), ',', ' ') || ' FCFA'
$$;
create or replace function app.ai_snapshot(bid uuid, d1 date, d2 date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s1 timestamptz := app.range_start(bid, d1); s2 timestamptz := app.range_start(bid, d2 + 1);
  sales_j jsonb; expenses_total numeric; lines_no_cost int; best jsonb; slow jsonb; low jsonb;
  orders_j jsonb; listing_gaps int; out_count int; channels jsonb; cost_estimated int;
begin
  select jsonb_build_object('count', count(*), 'revenue', coalesce(sum(s.total - s.returned_total), 0),
           'cost', coalesce(sum(s.cost_total - s.returned_cost), 0), 'returns', coalesce(sum(s.returned_total), 0))
    into sales_j from public.sales s where s.business_id = bid and s.cancelled_at is null and s.sold_at >= s1 and s.sold_at < s2;
  select coalesce(jsonb_object_agg(ch, n), '{}'::jsonb) into channels from (
    select s.channel ch, count(*) n from public.sales s
     where s.business_id = bid and s.cancelled_at is null and s.sold_at >= s1 and s.sold_at < s2 group by s.channel) x;
  select coalesce(sum(e.amount), 0) into expenses_total from public.expenses e
   where e.business_id = bid and e.status <> 'voided' and e.void_reason is null and e.expense_date between d1 and d2;
  select count(*)::int into lines_no_cost from public.sale_lines l join public.sales s on s.id = l.sale_id
   where s.business_id = bid and s.cancelled_at is null and s.sold_at >= s1 and s.sold_at < s2
     and (l.cost_amount is null or l.cost_amount = 0);
  select count(*)::int into cost_estimated from public.stock_movements m
   where m.business_id = bid and m.movement_type = 'sale' and m.cost_estimated and m.occurred_at >= s1 and m.occurred_at < s2;
  select coalesce(jsonb_agg(x order by x.qty desc), '[]'::jsonb) into best from (
    select p.name, sum(l.base_quantity - l.returned_base_qty) qty
      from public.sale_lines l join public.sales s on s.id = l.sale_id join public.products p on p.id = l.product_id
     where s.business_id = bid and s.cancelled_at is null and s.sold_at >= s1 and s.sold_at < s2
     group by p.id, p.name having sum(l.base_quantity - l.returned_base_qty) > 0 order by qty desc, p.name limit 5) x;
  select coalesce(jsonb_agg(x order by x.stock_value desc), '[]'::jsonb) into slow from (
    select p.name, p.qty_on_hand as qty, p.stock_value from public.products p
     where p.business_id = bid and p.status = 'active' and p.variant_of is null and p.qty_on_hand > 0
       and not exists (select 1 from public.sale_lines l join public.sales s on s.id = l.sale_id
                        where l.product_id = p.id and s.cancelled_at is null and s.sold_at >= now() - interval '30 days')
     order by p.stock_value desc limit 5) x;
  select coalesce(jsonb_agg(x order by x.ratio), '[]'::jsonb) into low from (
    select p.name, p.qty_on_hand as qty, p.min_stock, round(p.qty_on_hand / nullif(p.min_stock, 0), 2) as ratio
      from public.products p
     where p.business_id = bid and p.status = 'active' and p.variant_of is null and p.min_stock > 0 and p.qty_on_hand <= p.min_stock
     order by ratio limit 10) x;
  select count(*)::int into out_count from public.products p
   where p.business_id = bid and p.status = 'active' and p.variant_of is null and p.qty_on_hand <= 0
     and exists (select 1 from public.stock_movements m where m.product_id = p.id);
  select jsonb_build_object(
      'open', count(*) filter (where status in ('pending', 'confirmed', 'processing', 'dispatched')),
      'open_total', coalesce(sum(total) filter (where status in ('pending', 'confirmed', 'processing', 'dispatched')), 0),
      'unconfirmed', count(*) filter (where status = 'pending'),
      'awaiting_receipt', count(*) filter (where status = 'delivered' and receipt_status = 'awaiting'),
      'disputes', (select count(*) from public.market_reports r where r.business_id = bid and r.kind = 'dispute' and r.status in ('open', 'reviewing')))
    into orders_j from public.market_orders where business_id = bid;
  select count(*)::int into listing_gaps from public.products p
   where p.business_id = bid and p.status = 'active' and p.variant_of is null and p.online_published
     and (cardinality(p.online_images) = 0 or coalesce(btrim(p.description), '') = '');
  return jsonb_build_object(
    'period', jsonb_build_object('from', d1, 'to', d2, 'days', d2 - d1 + 1),
    'sales', coalesce(sales_j, '{}'::jsonb) || jsonb_build_object('channels', channels),
    'revenue', coalesce((sales_j ->> 'revenue')::numeric, 0),
    'cost', coalesce((sales_j ->> 'cost')::numeric, 0),
    'expenses', expenses_total,
    'gross_profit', coalesce((sales_j ->> 'revenue')::numeric, 0) - coalesce((sales_j ->> 'cost')::numeric, 0),
    'operating_profit_estimate', coalesce((sales_j ->> 'revenue')::numeric, 0) - coalesce((sales_j ->> 'cost')::numeric, 0) - expenses_total,
    'data_quality', jsonb_build_object('lines_without_cost', lines_no_cost, 'sales_with_estimated_cost', cost_estimated,
                                       'costs_complete', lines_no_cost = 0 and cost_estimated = 0),
    'best_sellers', best, 'slow_movers', slow, 'low_stock', low, 'out_of_stock', out_count,
    'orders', orders_j, 'listing_gaps', listing_gaps);
end $$;
create or replace function app.ai_answer(bid uuid, question text, lang text, d1 date, d2 date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q text := lower(coalesce(question, '')); fr boolean := lang = 'fr'; snap jsonb; intent text; txt text := ''; r record;
  pr public.products; nm text;
  m numeric;
begin
  intent := case
    when q ~ '(restock|r[ée]appro|reorder|low stock|stock bas|rupture|needs? (more )?stock)' then 'restock'
    when q ~ '(profit|b[ée]n[ée]fice|marge|margin)' then 'profit'
    when q ~ '(description|title|titre|keyword|mot[- ]cl|whatsapp|caption|l[ée]gende|promo message|marketing)' then 'copy'
    when q ~ '(promo|promotion|discount|remise|rabais)' then 'promo'
    when q ~ '(best|top|meilleur|plus vendu|best[- ]sell)' then 'best'
    when q ~ '(slow|lent|dormant|not selling|ne se vend)' then 'slow'
    when q ~ '(task|t[âa]che|to do|[àa] faire|incomplete|incomplet)' then 'tasks'
    when q ~ '(order|commande|outstanding|pending|en attente|receipt|livraison|deliver)' then 'orders'
    when q ~ '(revenue|revenu|chiffre|sales|ventes|sold|vendu|how much|combien|recorded|enregistr)' then 'revenue'
    when q ~ '(report|rapport|summary|r[ée]sum[ée]|weekly|hebdo|semaine|daily|briefing|bilan)' then 'report'
    else 'briefing' end;
  snap := app.ai_snapshot(bid, d1, d2);
  if intent = 'copy' then
    select p.* into pr from public.products p
     where p.business_id = bid and p.status = 'active' and p.variant_of is null and position(lower(p.name) in q) > 0
     order by length(p.name) desc limit 1;
    if not found then
      return jsonb_build_object('intent', 'copy', 'text', case when fr then 'Nommez le produit (son nom exact) pour que je rédige son titre, sa description et son message WhatsApp.'
        else 'Name the product (its exact name) and I will write its title, description and WhatsApp message.' end, 'data', '{}'::jsonb);
    end if;
    return jsonb_build_object('intent', 'copy', 'data', app.ai_product_copy(bid, pr.id, lang), 'text',
      case when fr then 'Brouillon à relire avant publication. Seuls les faits enregistrés sont utilisés.'
        else 'Draft to review before you publish. Only the facts recorded for this product are used.' end);
  end if;
  if intent = 'revenue' then
    txt := case when fr then format('Sur la période du %s au %s, %s vente(s) enregistrée(s) pour un chiffre d’affaires de %s (retours déduits). '
             || 'Ce n’est pas le bénéfice : le coût des marchandises est de %s.',
             d1, d2, snap -> 'sales' ->> 'count', app.ai_money((snap ->> 'revenue')::numeric), app.ai_money((snap ->> 'cost')::numeric))
           else format('From %s to %s, %s sale(s) recorded, revenue %s (returns deducted). This is not profit: the cost of goods sold is %s.',
             d1, d2, snap -> 'sales' ->> 'count', app.ai_money((snap ->> 'revenue')::numeric), app.ai_money((snap ->> 'cost')::numeric)) end;
  elsif intent = 'profit' then
    txt := case when fr then format('Bénéfice brut enregistré : %s (chiffre %s moins coût %s). Après dépenses enregistrées (%s) : environ %s.',
             app.ai_money((snap ->> 'gross_profit')::numeric), app.ai_money((snap ->> 'revenue')::numeric), app.ai_money((snap ->> 'cost')::numeric),
             app.ai_money((snap ->> 'expenses')::numeric), app.ai_money((snap ->> 'operating_profit_estimate')::numeric))
           else format('Recorded gross profit: %s (revenue %s minus cost %s). After recorded expenses (%s): about %s.',
             app.ai_money((snap ->> 'gross_profit')::numeric), app.ai_money((snap ->> 'revenue')::numeric), app.ai_money((snap ->> 'cost')::numeric),
             app.ai_money((snap ->> 'expenses')::numeric), app.ai_money((snap ->> 'operating_profit_estimate')::numeric)) end;
  elsif intent = 'restock' then
    if jsonb_array_length(snap -> 'low_stock') = 0 then
      txt := case when fr then 'Aucun produit sous son seuil de réapprovisionnement. ' || (snap ->> 'out_of_stock') || ' produit(s) en rupture.'
                  else 'No product is below its restock level. ' || (snap ->> 'out_of_stock') || ' product(s) are out of stock.' end;
    else
      txt := case when fr then 'Priorités de réapprovisionnement (du plus urgent) :' else 'Restock priorities (most urgent first):' end;
      for r in select * from jsonb_to_recordset(snap -> 'low_stock') as x(name text, qty numeric, min_stock numeric) loop
        txt := txt || E'\n- ' || r.name || ' : ' || r.qty || ' / ' || r.min_stock || case when fr then ' (seuil)' else ' (minimum)' end;
      end loop;
    end if;
  elsif intent = 'orders' then
    txt := case when fr then format('Commandes en ligne ouvertes : %s, pour %s. À confirmer : %s. Livrées en attente de confirmation du client : %s. Signalements ouverts : %s.',
             snap -> 'orders' ->> 'open', app.ai_money((snap -> 'orders' ->> 'open_total')::numeric), snap -> 'orders' ->> 'unconfirmed',
             snap -> 'orders' ->> 'awaiting_receipt', snap -> 'orders' ->> 'disputes')
           else format('Open online orders: %s, worth %s. To confirm: %s. Delivered and waiting for the customer to confirm: %s. Open problems: %s.',
             snap -> 'orders' ->> 'open', app.ai_money((snap -> 'orders' ->> 'open_total')::numeric), snap -> 'orders' ->> 'unconfirmed',
             snap -> 'orders' ->> 'awaiting_receipt', snap -> 'orders' ->> 'disputes') end;
  elsif intent = 'best' then
    txt := case when fr then 'Produits les plus vendus sur la période :' else 'Best-selling products in the period:' end;
    for r in select * from jsonb_to_recordset(snap -> 'best_sellers') as x(name text, qty numeric) loop
      txt := txt || E'\n- ' || r.name || ' : ' || r.qty;
    end loop;
    if jsonb_array_length(snap -> 'best_sellers') = 0 then txt := case when fr then 'Aucune vente enregistrée sur la période.' else 'No sales recorded in the period.' end; end if;
  elsif intent = 'slow' then
    txt := case when fr then 'Produits en stock sans vente depuis 30 jours (par valeur du stock) :' else 'In stock but not sold for 30 days (by stock value):' end;
    for r in select * from jsonb_to_recordset(snap -> 'slow_movers') as x(name text, qty numeric, stock_value numeric) loop
      txt := txt || E'\n- ' || r.name || ' : ' || r.qty || ' ' || case when fr then 'en stock' else 'in stock' end;
    end loop;
    if jsonb_array_length(snap -> 'slow_movers') = 0 then txt := case when fr then 'Aucun produit dormant.' else 'No slow-moving products.' end; end if;
  elsif intent = 'tasks' then
    txt := case when fr then format('À faire : %s commande(s) à confirmer ; %s livraison(s) en attente de confirmation client ; %s produit(s) en rupture ; %s produit(s) en ligne sans photo ou sans description ; %s produit(s) sous le seuil de réapprovisionnement.',
             snap -> 'orders' ->> 'unconfirmed', snap -> 'orders' ->> 'awaiting_receipt', snap ->> 'out_of_stock', snap ->> 'listing_gaps', jsonb_array_length(snap -> 'low_stock'))
           else format('To do: %s order(s) to confirm; %s delivery(ies) waiting for customer confirmation; %s product(s) out of stock; %s online product(s) without a photo or description; %s product(s) below restock level.',
             snap -> 'orders' ->> 'unconfirmed', snap -> 'orders' ->> 'awaiting_receipt', snap ->> 'out_of_stock', snap ->> 'listing_gaps', jsonb_array_length(snap -> 'low_stock')) end;
  elsif intent = 'promo' then
    txt := case when fr then 'Idées de promotion à partir de vos données (rien n’est appliqué sans votre confirmation) : '
             || 'proposez une remise sur les produits dormants (' || jsonb_array_length(snap -> 'slow_movers') || ' produit(s)), '
             || 'et mettez en avant les plus vendus (' || jsonb_array_length(snap -> 'best_sellers') || ' produit(s)).'
           else 'Promotion ideas from your data (nothing is applied without your confirmation): offer a discount on the ' || jsonb_array_length(snap -> 'slow_movers')
             || ' slow-moving product(s), and feature the ' || jsonb_array_length(snap -> 'best_sellers') || ' best seller(s).' end;
  elsif intent = 'report' or intent = 'briefing' then
    txt := case when fr then format('Rapport du %s au %s. Chiffre d’affaires : %s (%s vente(s)). Coût : %s. Dépenses : %s. Bénéfice brut estimé : %s. '
             || 'Commandes ouvertes : %s. Produits en rupture : %s. Sous le seuil : %s.',
             d1, d2, app.ai_money((snap ->> 'revenue')::numeric), snap -> 'sales' ->> 'count', app.ai_money((snap ->> 'cost')::numeric),
             app.ai_money((snap ->> 'expenses')::numeric), app.ai_money((snap ->> 'gross_profit')::numeric),
             snap -> 'orders' ->> 'open', snap ->> 'out_of_stock', jsonb_array_length(snap -> 'low_stock'))
           else format('Report from %s to %s. Revenue: %s (%s sale(s)). Cost: %s. Expenses: %s. Estimated gross profit: %s. '
             || 'Open orders: %s. Out of stock: %s. Below restock level: %s.',
             d1, d2, app.ai_money((snap ->> 'revenue')::numeric), snap -> 'sales' ->> 'count', app.ai_money((snap ->> 'cost')::numeric),
             app.ai_money((snap ->> 'expenses')::numeric), app.ai_money((snap ->> 'gross_profit')::numeric),
             snap -> 'orders' ->> 'open', snap ->> 'out_of_stock', jsonb_array_length(snap -> 'low_stock')) end;
  end if;
  if not (snap -> 'data_quality' ->> 'costs_complete')::boolean then
    txt := txt || case when fr then E'\nAttention : certaines lignes de vente n’ont pas de coût complet, donc le bénéfice est estimé.'
                       else E'\nNote: some sale lines have no complete cost, so profit is an estimate.' end;
  end if;
  return jsonb_build_object('intent', intent, 'text', txt, 'data', snap);
end $$;
create or replace function app.ai_product_copy(bid uuid, pid uuid, lang text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.products; store text; price text; attrs text; words text[];
begin
  select * into p from public.products where id = pid and business_id = bid;
  if not found then return null; end if;
  select name into store from public.stores where business_id = bid;
  price := app.ai_money(p.selling_price);
  attrs := (select string_agg(key || ': ' || (value #>> '{}'), ', ') from jsonb_each(coalesce(p.attributes, '{}'::jsonb)));
  words := array(select distinct w from unnest(regexp_split_to_array(lower(coalesce(p.name, '') || ' ' || coalesce(p.brand, '')), '[^a-z0-9àâäéèêëîïôöùûüç]+')) w
                 where length(w) > 2 order by w);
  return jsonb_build_object(
    'title', btrim(p.name || coalesce(' · ' || p.brand, '')),
    'description', btrim(concat_ws(' ',
        case when lang = 'fr' then 'Disponible à ' || price || ' par ' || p.base_unit || '.' else 'Available at ' || price || ' per ' || p.base_unit || '.' end,
        nullif(btrim(p.description), ''),
        case when attrs is not null then case when lang = 'fr' then 'Caractéristiques : ' else 'Details: ' end || attrs || '.' end)),
    'keywords', to_jsonb(words),
    'whatsapp', case when lang = 'fr' then format('Bonjour ! %s est disponible chez %s à %s. Répondez-moi pour commander.', p.name, store, price)
                     else format('Hello! %s is available at %s for %s. Reply to order.', p.name, store, price) end,
    'draft', true);
end $$;
create or replace function app.ai_manager_gate(bid uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.require_perm(bid, 'reports.view');
  perform app.require_feature(bid, 'ai_business_manager');
end $$;
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
