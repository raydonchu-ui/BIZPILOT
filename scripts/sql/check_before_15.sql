do $$
begin
  if to_regprocedure('public.admin_creator_reconcile()') is null or to_regprocedure('public.admin_set_creator_program(jsonb)') is null then
    raise exception 'Run 14_upgrade_creator_program.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;
