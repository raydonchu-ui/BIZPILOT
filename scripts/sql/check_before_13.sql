do $$
begin
  if to_regprocedure('public.ai_send_message(uuid,uuid,text,text,date,date)') is null
     or to_regprocedure('public.billing_payment_cancel(uuid)') is null then
    raise exception 'Run 12_upgrade_ai_business_manager.sql (and the earlier upgrades) first, then run this file again.';
  end if;
end $$;
