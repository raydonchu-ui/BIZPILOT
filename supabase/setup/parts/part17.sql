-- BizPilot setup PART 17 of 17. Run parts in order.
begin;
alter table public.market_ledger enable row level security;
alter table public.online_payments enable row level security;
create policy market_ledger_read on public.market_ledger for select
  using (app.has_perm(business_id, 'cash.manage') or app.is_platform_admin());
create policy online_payments_read on public.online_payments for select
  using ((kind = 'order' and (app.has_perm(business_id, 'orders.manage') or app.has_perm(business_id, 'cash.manage')))
         or (kind = 'subscription' and app.has_perm(business_id, 'billing.manage'))
         or app.is_platform_admin());
revoke all on public.stores, public.store_delivery_zones, public.market_promotions, public.market_orders,
  public.market_order_lines, public.market_order_events, public.stock_reservations, public.market_reviews,
  public.market_reports, public.customer_addresses, public.market_favorites, public.market_store_follows,
  public.market_blocklist, public.market_ledger, public.online_payments from anon;
revoke insert, update, delete, truncate, references, trigger on public.stores, public.store_delivery_zones,
  public.market_promotions, public.market_orders, public.market_order_lines, public.market_order_events,
  public.stock_reservations, public.market_reviews, public.market_reports, public.market_blocklist,
  public.market_ledger, public.online_payments from authenticated;
grant select on public.stores, public.store_delivery_zones, public.market_promotions, public.market_orders,
  public.market_order_lines, public.market_order_events, public.stock_reservations, public.market_reviews,
  public.market_reports, public.market_blocklist, public.market_ledger, public.online_payments to authenticated;
revoke execute on function app.market_cancel(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.market_expire() from public, anon, authenticated;
revoke execute on function app.market_order_to_sale(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.market_try_reopen(uuid, timestamptz) from public, anon, authenticated;
revoke execute on function app.activate_fapshi_subscription(uuid) from public, anon, authenticated;
revoke execute on function app.refresh_store_rating(uuid) from public, anon, authenticated;
revoke execute on function app.admin_audit(text, text, text, uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.order_for_customer(uuid, text, boolean) from public, anon, authenticated;
grant execute on function app.listing_public(uuid), app.listing_of(uuid), app.store_is_live(uuid), app.reserved_qty(uuid, uuid),
  app.listing_within_limit(uuid, timestamptz, uuid), app.market_config(), app.norm_phone(text), app.products_market_guard(),
  app.customer_addresses_guard(), app.storefront_can_write(text), app.storage_can_write(text), app.usage_count(uuid, text)
  to anon, authenticated;
revoke execute on function public.market_config_public(), public.market_search(jsonb), public.market_home(text),
  public.market_store(text), public.market_product(uuid), public.market_products_by_ids(uuid[]), public.market_store_cards(uuid[]),
  public.market_quote(jsonb), public.market_place_order(jsonb), public.market_order_view(uuid, text),
  public.market_order_customer_action(uuid, text, text, text), public.market_submit_review(uuid, text, uuid, int, text),
  public.market_report(jsonb), public.market_payment_begin(uuid, text), public.online_payment_status(uuid),
  public.store_slug_available(text, uuid) from public;
grant execute on function public.market_config_public(), public.market_search(jsonb), public.market_home(text),
  public.market_store(text), public.market_product(uuid), public.market_products_by_ids(uuid[]), public.market_store_cards(uuid[]),
  public.market_quote(jsonb), public.market_place_order(jsonb), public.market_order_view(uuid, text),
  public.market_order_customer_action(uuid, text, text, text), public.market_submit_review(uuid, text, uuid, int, text),
  public.market_report(jsonb), public.market_payment_begin(uuid, text), public.online_payment_status(uuid),
  public.store_slug_available(text, uuid) to anon, authenticated;
revoke execute on function public.market_my_orders(int, int), public.market_claim_orders(jsonb),
  public.store_save(uuid, jsonb), public.store_save_zones(uuid, jsonb), public.store_readiness(uuid),
  public.store_set_published(uuid, boolean), public.store_request_verification(uuid, text),
  public.products_set_online(uuid, uuid[], boolean), public.promo_save(uuid, jsonb), public.market_review_reply(uuid, text),
  public.market_order_action(uuid, text, jsonb), public.seller_market_summary(uuid), public.seller_payments_summary(uuid),
  public.billing_fapshi_begin(uuid, text, text), public.admin_set_config(text, jsonb), public.admin_market_overview(),
  public.admin_market_stores(text, text), public.admin_market_store_update(uuid, jsonb),
  public.admin_market_listings(text, boolean, int, int), public.admin_market_hide_product(uuid, boolean, text),
  public.admin_market_reports(text), public.admin_market_report_update(uuid, text, text),
  public.admin_market_orders(text, text, int, int), public.admin_market_order(uuid),
  public.admin_market_order_action(uuid, text, jsonb), public.admin_market_payments(text),
  public.admin_market_payment_resolve(uuid, text, text, text), public.admin_market_balances(), public.admin_market_ledger(uuid),
  public.admin_market_record_payout(uuid, numeric, text, text, text, text), public.admin_market_block(text, text, text),
  public.admin_market_unblock(uuid), public.admin_market_hide_review(uuid, boolean, text), public.admin_market_reviews(text)
  from public, anon;
grant execute on function public.market_my_orders(int, int), public.market_claim_orders(jsonb),
  public.store_save(uuid, jsonb), public.store_save_zones(uuid, jsonb), public.store_readiness(uuid),
  public.store_set_published(uuid, boolean), public.store_request_verification(uuid, text),
  public.products_set_online(uuid, uuid[], boolean), public.promo_save(uuid, jsonb), public.market_review_reply(uuid, text),
  public.market_order_action(uuid, text, jsonb), public.seller_market_summary(uuid), public.seller_payments_summary(uuid),
  public.billing_fapshi_begin(uuid, text, text), public.admin_set_config(text, jsonb), public.admin_market_overview(),
  public.admin_market_stores(text, text), public.admin_market_store_update(uuid, jsonb),
  public.admin_market_listings(text, boolean, int, int), public.admin_market_hide_product(uuid, boolean, text),
  public.admin_market_reports(text), public.admin_market_report_update(uuid, text, text),
  public.admin_market_orders(text, text, int, int), public.admin_market_order(uuid),
  public.admin_market_order_action(uuid, text, jsonb), public.admin_market_payments(text),
  public.admin_market_payment_resolve(uuid, text, text, text), public.admin_market_balances(), public.admin_market_ledger(uuid),
  public.admin_market_record_payout(uuid, numeric, text, text, text, text), public.admin_market_block(text, text, text),
  public.admin_market_unblock(uuid), public.admin_market_hide_review(uuid, boolean, text), public.admin_market_reviews(text)
  to authenticated;
revoke execute on function public.fapshi_attach(uuid, text, text), public.fapshi_payment_lookup(uuid),
  public.fapshi_apply(text, jsonb) from public, anon, authenticated;
grant execute on function public.fapshi_attach(uuid, text, text), public.fapshi_payment_lookup(uuid),
  public.fapshi_apply(text, jsonb) to service_role;
commit;
