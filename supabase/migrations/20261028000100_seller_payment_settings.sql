-- Phase 6: seller Mobile Money settings for MTN and Orange, kept separate per method.
-- Details are entered by the seller. BizPilot does not verify them with MTN or Orange, and it never stores PINs,
-- wallet passwords or OTPs (instructions that ask for them are refused). Buyers see only the methods the seller enabled.

-- Text that asks a buyer for a secret is refused. Used by the check constraints and the save function.
create or replace function app.payment_text_ok(t text) returns boolean
language sql immutable as $$
  select t is null or t !~* '(\mpin\M|\motp\M|password|mot de passe|code secret|secret code|passcode|one.time code|code a usage unique|wallet pass)'
$$;

-- 1. Per-method switches, instructions, and whether proof of payment is requested.
alter table public.stores
  add column if not exists momo_mtn_enabled boolean not null default false,
  add column if not exists momo_orange_enabled boolean not null default false,
  add column if not exists momo_mtn_instructions text,
  add column if not exists momo_orange_instructions text,
  add column if not exists momo_proof_required boolean not null default false,
  add column if not exists momo_settings_updated_at timestamptz;

-- Existing stores keep what they had: a method that already had a number and the direct-payment switch on stays on.
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

-- 2. Saving: each method on or off; an enabled method needs its number.
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

-- 3. Buyer view of a Mobile Money order: only the methods the seller enabled, labelled as seller-entered.
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
