do $$
begin
  if to_regprocedure('public.market_order_customer_action(uuid,text,text,text)') is null
     or to_regclass('public.market_reviews') is null or to_regprocedure('app.review_gate(public.market_orders)') is null then
    raise exception 'Run 10_upgrade_order_lifecycle.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;
