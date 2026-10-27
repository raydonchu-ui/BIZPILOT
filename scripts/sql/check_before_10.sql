do $$
begin
  if to_regprocedure('public.market_locations()') is null or to_regprocedure('public.market_report(jsonb)') is null
     or to_regprocedure('public.market_submit_review(uuid,text,uuid,integer,text)') is null
     or to_regprocedure('public.market_order_customer_action(uuid,text,text,text)') is null
     or to_regclass('public.market_reviews') is null then
    raise exception 'Run 09_upgrade_locations_delivery.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;
