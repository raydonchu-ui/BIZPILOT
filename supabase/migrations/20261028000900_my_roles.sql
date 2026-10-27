-- Phase 2: one login, several roles. The roles are read from the records that grant them; nothing here grants anything.
create or replace function public.my_roles() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then jsonb_build_object('signed_in', false) else jsonb_build_object(
    'signed_in', true,
    'buyer', true,
    'sellers', coalesce((select jsonb_agg(jsonb_build_object('business_id', m.business_id, 'name', b.name, 'role', m.role,
                 'premium', app.has_feature(m.business_id, 'verified_badge'), 'blue_tick', app.blue_tick(m.business_id))
               order by b.name)
             from public.business_members m join public.businesses b on b.id = m.business_id
            where m.user_id = auth.uid() and m.active), '[]'::jsonb),
    'creator', exists (select 1 from public.creator_profiles c where c.user_id = auth.uid() and c.status = 'approved'),
    'creator_pending', exists (select 1 from public.creator_profiles c where c.user_id = auth.uid() and c.status = 'pending'),
    'admin', app.is_platform_admin()) end
$$;
revoke all on function public.my_roles() from public, anon;
grant execute on function public.my_roles() to authenticated;
