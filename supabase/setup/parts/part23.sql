-- BizPilot setup PART 23 of 24. Run parts in order.
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
    'verified', app.blue_tick(s.business_id), 'rating_avg', s.rating_avg, 'rating_count', s.rating_count,
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
create or replace function public.market_shops(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_city text := nullif(btrim(coalesce(p ->> 'city', '')), '');
  v_type text := nullif(p ->> 'type', '');
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
  size int := least(greatest(coalesce((p ->> 'page_size')::int, 24), 1), 60);
  pg int := greatest(coalesce((p ->> 'page')::int, 1), 1);
  res jsonb;
begin
  with base as (
    select s.business_id, s.name, s.verification, s.rating_count, s.published_at
      from public.stores s join public.businesses b on b.id = s.business_id
     where s.status = 'published' and b.status = 'active'
       and (v_city is null or app.city_key(s.city) = app.city_key(v_city) or app.city_key(s.region) = app.city_key(v_city))
       and (v_type is null or b.category = v_type)
       and (v_q is null or s.name ilike app.like_term(v_q) or s.tagline ilike app.like_term(v_q))
  ), ranked as (
    select business_id, row_number() over (order by app.blue_tick(business_id) desc, rating_count desc, published_at desc, name) ord
      from base
  )
  select jsonb_build_object(
    'total', (select count(*) from base), 'page', pg, 'page_size', size,
    'items', coalesce((select jsonb_agg(app.store_card(r.business_id) order by r.ord) from ranked r
                        where r.ord > (pg - 1) * size and r.ord <= pg * size), '[]'::jsonb))
    into res;
  return res;
end $$;
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
commit;
