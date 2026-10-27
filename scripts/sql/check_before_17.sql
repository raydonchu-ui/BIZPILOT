do $$
begin
  if to_regprocedure('public.creator_apply(jsonb)') is null or to_regprocedure('public.admin_finance_overview(date,date)') is null then
    raise exception 'Run the earlier upgrades (up to 16_upgrade_notifications_support.sql) first, then run this file again.';
  end if;
end $$;
