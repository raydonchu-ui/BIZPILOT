do $$
begin
  if to_regprocedure('app.city_key(text)') is null or to_regprocedure('public.market_store(text)') is null
     or to_regclass('public.store_delivery_zones') is null or to_regclass('public.profiles') is null then
    raise exception 'Run 07_upgrade_storefront_chat.sql (and 08_upgrade_profile_photos.sql) first, then run this file again.';
  end if;
end $$;
