do $$
begin
  if to_regprocedure('public.admin_creator_reconcile()') is null or to_regprocedure('public.buyer_dashboard()') is null then
    raise exception 'Run the earlier upgrades (up to 17_upgrade_security_hardening.sql) first, then run this file again.';
  end if;
end $$;
