do $$
begin
  if to_regprocedure('public.admin_finance_overview(date,date)') is null then
    raise exception 'Run 15_upgrade_admin_finance.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;
