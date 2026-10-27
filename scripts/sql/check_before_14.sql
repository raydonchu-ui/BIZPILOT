do $$
begin
  if to_regprocedure('public.automation_list(uuid)') is null or to_regclass('public.seller_automations') is null then
    raise exception 'Run 13_upgrade_premium_automations.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;
