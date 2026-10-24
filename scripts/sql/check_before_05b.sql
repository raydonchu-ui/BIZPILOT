-- Stops here (nothing is changed) unless 05a has been run and 05b has not.
do $$
begin
  if to_regclass('public.stores') is null then raise exception 'Run 05a_upgrade_marketplace_part1.sql first.'; end if;
  if to_regclass('public.market_ledger') is not null then raise exception 'This part is already installed. Nothing to do.'; end if;
end $$;
