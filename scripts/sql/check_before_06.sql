do $$
begin
  if to_regclass('public.stores') is null or to_regclass('public.online_payments') is null then
    raise exception 'Run 05_upgrade_marketplace.sql (or 05a then 05b) first, then run this file again.';
  end if;
end $$;
