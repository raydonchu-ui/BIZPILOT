do $$
begin
  if to_regprocedure('public.ai_send_message(uuid,uuid,text,text,date,date)') is null
     and to_regclass('public.ai_queries') is null then
    raise exception 'Run 11_upgrade_payments_verified_premium.sql (and the earlier upgrades) first, then run this file again.';
  end if;
  if to_regprocedure('public.billing_payment_cancel(uuid)') is null
     or to_regprocedure('public.verification_apply(uuid,jsonb)') is null then
    raise exception 'Run 11_upgrade_payments_verified_premium.sql first, then run this file again.';
  end if;
end $$;
