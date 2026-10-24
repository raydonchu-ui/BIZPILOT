-- Stops here (nothing is changed) when the database is not ready for this upgrade.
do $$
begin
  if to_regprocedure('public.store_lock_status()') is null then
    raise exception 'Run 04_upgrade_catalog_and_store_lock.sql first, then run this file again.';
  end if;
  if to_regclass('public.stores') is not null then
    raise exception 'The marketplace upgrade is already installed. Nothing to do.';
  end if;
end $$;
