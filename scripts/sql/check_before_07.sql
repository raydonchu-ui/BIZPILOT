do $$
begin
  if to_regclass('public.stores') is null or to_regclass('public.business_members') is null
     or to_regprocedure('app.has_perm(uuid,text)') is null or to_regprocedure('app.rate_limit(text,integer,integer)') is null then
    raise exception 'Run 06_upgrade_direct_trade.sql (and the earlier upgrades) first, then run this file again.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'online_published') then
    raise exception 'The online store (products.online_published) is missing. Run 05_upgrade_marketplace.sql first.';
  end if;
end $$;
