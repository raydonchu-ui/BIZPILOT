do $$
begin
  if to_regclass('public.conversations') is null or to_regclass('public.profiles') is null
     or to_regprocedure('public.msg_list(integer)') is null or to_regprocedure('app.product_card(uuid)') is null then
    raise exception 'Run 07_upgrade_storefront_chat.sql first (it adds messaging), then run this file again.';
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'products'
        and column_name in ('condition', 'single_item')) <> 2 then
    raise exception 'Run 06_upgrade_direct_trade.sql first: it adds products.condition and products.single_item.';
  end if;
end $$;
