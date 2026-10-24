-- Store Lock: a 4-digit PIN that locks the BizPilot dashboard on a device (signed-in session).
--
-- Enforced on the server, per Supabase Auth session (the JWT's session_id):
--   * while a session is locked, every permission and membership check used by the API, RLS
--     policies and storage returns "no access", and RPCs raise 'store_locked';
--   * a new sign-in starts locked (once a PIN exists), so signing out and in again does not skip it;
--   * a session also counts as locked after the user's inactivity period without activity.
-- PINs are stored only as bcrypt hashes (pgcrypto) in schema "app", which the API cannot read.
-- Wrong PINs are counted per user with growing waits. Forgotten PIN: sign in again (fresh login
-- within 10 minutes), then set a new PIN; every session of the user is locked afterwards.
-- Limitation: a 4-digit PIN has 10 000 combinations, so its strength comes from the server-side
-- attempt limits, not from the hash. It complements, never replaces, the account password.

create table app.store_pins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  pin_hash text not null,
  idle_minutes int not null default 15 check (idle_minutes between 1 and 240),
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now(),
  pin_changed_at timestamptz not null default now()
);

create table app.store_lock_sessions (
  session_id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  locked boolean not null,
  reason text check (reason in ('new_session', 'manual', 'idle', 'pin_reset', 'pin_changed')),
  locked_at timestamptz,
  unlocked_at timestamptz,
  last_activity timestamptz not null default now()
);
create index store_lock_sessions_user on app.store_lock_sessions (user_id);
revoke all on app.store_pins, app.store_lock_sessions from public, anon, authenticated;

create or replace function app.current_session_id() returns uuid
language sql stable as $$
  select case when coalesce(auth.jwt() ->> 'session_id', '') ~ '^[0-9a-f-]{36}$' then (auth.jwt() ->> 'session_id')::uuid end
$$;

-- True when the calling session must unlock before using business data.
create or replace function app.session_locked() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); sid uuid := app.current_session_id(); pin app.store_pins; s app.store_lock_sessions;
begin
  if uid is null or sid is null then return false; end if;           -- service/database calls
  select * into pin from app.store_pins where user_id = uid;
  if not found then return false; end if;                           -- no PIN yet: the app asks for one first
  select * into s from app.store_lock_sessions where session_id = sid and user_id = uid;
  if not found then return true; end if;                            -- a new sign-in starts locked
  return s.locked or s.last_activity < now() - make_interval(mins => pin.idle_minutes);
end $$;

-- Session row for the caller, created locked for a session never seen before.
create or replace function app.lock_session_row(uid uuid, sid uuid) returns app.store_lock_sessions
language plpgsql security definer set search_path = public as $$
declare s app.store_lock_sessions; idle int;
begin
  insert into app.store_lock_sessions (session_id, user_id, locked, reason, locked_at)
  values (sid, uid, true, 'new_session', now())
  on conflict (session_id) do nothing;
  select idle_minutes into idle from app.store_pins where user_id = uid;
  -- Persist an inactivity lock so it is reported (and kept) even if activity resumes.
  update app.store_lock_sessions set locked = true, reason = 'idle', locked_at = now()
   where session_id = sid and not locked and idle is not null and last_activity < now() - make_interval(mins => idle);
  select * into s from app.store_lock_sessions where session_id = sid;
  if s.user_id <> uid then perform app.raise('permission_denied'); end if;
  return s;
end $$;

create or replace function app.valid_pin(p text) returns boolean
language sql immutable as $$
  select p ~ '^[0-9]{4}$'
     and p !~ '^(.)\1{3}$'                                        -- 0000, 1111, …
     and p not in ('0123', '1234', '2345', '3456', '4567', '5678', '6789', '9876', '8765', '7654', '6543', '5432', '4321', '3210')
$$;

create or replace function app.fresh_login(max_age interval default interval '10 minutes') returns boolean
language sql stable as $$
  select coalesce((select max((x ->> 'timestamp')::bigint) from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) x), 0)
         >= extract(epoch from now() - max_age)
$$;

-- Checks a PIN with attempt limits. Never raises for a wrong PIN, so the failure is recorded.
-- 5 wrong PINs → 30 s wait, then 1, 2, 5, 10 min, then 15 min per further mistake.
create or replace function app.check_pin(uid uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pin app.store_pins; ok boolean; wait int;
begin
  select * into pin from app.store_pins where user_id = uid for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'pin_not_set'); end if;
  if pin.locked_until is not null and pin.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'pin_temporarily_locked',
      'retry_after', ceil(extract(epoch from pin.locked_until - now()))::int);
  end if;
  ok := p_pin ~ '^[0-9]{4}$' and extensions.crypt(p_pin, pin.pin_hash) = pin.pin_hash;
  if ok then
    update app.store_pins set failed_attempts = 0, locked_until = null where user_id = uid;
    return jsonb_build_object('ok', true);
  end if;
  wait := case when pin.failed_attempts + 1 < 5 then 0 when pin.failed_attempts + 1 = 5 then 30 when pin.failed_attempts + 1 = 6 then 60
               when pin.failed_attempts + 1 = 7 then 120 when pin.failed_attempts + 1 = 8 then 300 when pin.failed_attempts + 1 = 9 then 600 else 900 end;
  update app.store_pins set failed_attempts = failed_attempts + 1,
         locked_until = case when wait > 0 then now() + make_interval(secs => wait) end
   where user_id = uid;
  if wait > 0 then
    insert into public.audit_logs (user_id, action, entity, entity_id, details)
    values (uid, 'store_lock.too_many_attempts', 'user', uid::text, jsonb_build_object('attempts', pin.failed_attempts + 1, 'wait_seconds', wait));
  end if;
  return jsonb_build_object('ok', false, 'error', case when wait > 0 then 'pin_temporarily_locked' else 'wrong_pin' end,
    'retry_after', wait, 'attempts_left', greatest(0, 4 - pin.failed_attempts));
end $$;

create or replace function app.require_session() returns table (uid uuid, sid uuid)
language plpgsql stable as $$
begin
  uid := auth.uid(); sid := app.current_session_id();
  if uid is null then perform app.raise('not_authenticated'); end if;
  if sid is null then perform app.raise('session_required'); end if;
  return next;
end $$;

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------
create or replace function public.store_lock_status()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; pin app.store_pins; s app.store_lock_sessions;
begin
  select * into u from app.require_session();
  select * into pin from app.store_pins where user_id = u.uid;
  if not found then return jsonb_build_object('has_pin', false, 'locked', false); end if;
  s := app.lock_session_row(u.uid, u.sid);
  delete from app.store_lock_sessions where user_id = u.uid and last_activity < now() - interval '60 days' and session_id <> u.sid;
  return jsonb_build_object('has_pin', true, 'locked', s.locked, 'reason', s.reason, 'idle_minutes', pin.idle_minutes,
    'retry_after', case when pin.locked_until > now() then ceil(extract(epoch from pin.locked_until - now()))::int else 0 end,
    'can_reset', app.fresh_login());
end $$;

-- First PIN for this account. The session that sets it stays unlocked.
create or replace function public.set_store_pin(p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if exists (select 1 from app.store_pins where user_id = u.uid) then perform app.raise('pin_already_set'); end if;
  if not app.valid_pin(p_pin) then perform app.raise('pin_too_simple'); end if;
  insert into app.store_pins (user_id, pin_hash) values (u.uid, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)));
  insert into app.store_lock_sessions (session_id, user_id, locked, unlocked_at, last_activity)
  values (u.sid, u.uid, false, now(), now())
  on conflict (session_id) do update set locked = false, reason = null, unlocked_at = now(), last_activity = now();
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_created', 'user', u.uid::text);
  return public.store_lock_status();
end $$;

create or replace function public.lock_store()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if not exists (select 1 from app.store_pins where user_id = u.uid) then perform app.raise('pin_not_set'); end if;
  perform app.lock_session_row(u.uid, u.sid);
  update app.store_lock_sessions set locked = true, reason = 'manual', locked_at = now() where session_id = u.sid and not locked;
  return public.store_lock_status();
end $$;

create or replace function public.unlock_store(p_pin text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; r jsonb;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin:' || u.uid, 30, 3600);
  r := app.check_pin(u.uid, p_pin);
  if (r ->> 'ok')::boolean then
    perform app.lock_session_row(u.uid, u.sid);
    update app.store_lock_sessions set locked = false, reason = null, unlocked_at = now(), last_activity = now() where session_id = u.sid;
  end if;
  return r || jsonb_build_object('status', public.store_lock_status());
end $$;

-- Activity from an unlocked session (called by the app while the user is active).
create or replace function public.store_lock_heartbeat()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; s app.store_lock_sessions;
begin
  select * into u from app.require_session();
  if not exists (select 1 from app.store_pins where user_id = u.uid) then return jsonb_build_object('has_pin', false, 'locked', false); end if;
  s := app.lock_session_row(u.uid, u.sid);
  if not s.locked then update app.store_lock_sessions set last_activity = now() where session_id = u.sid; end if;
  return jsonb_build_object('has_pin', true, 'locked', s.locked, 'reason', s.reason);
end $$;

-- Change PIN: needs the current PIN (same attempt limits). Other devices are locked.
create or replace function public.change_store_pin(p_current text, p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record; r jsonb;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin:' || u.uid, 30, 3600);
  if app.session_locked() then perform app.raise('store_locked'); end if;
  if not app.valid_pin(p_new) then perform app.raise('pin_too_simple'); end if;
  r := app.check_pin(u.uid, p_current);
  if not (r ->> 'ok')::boolean then return r; end if;
  update app.store_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), pin_changed_at = now() where user_id = u.uid;
  update app.store_lock_sessions set locked = true, reason = 'pin_changed', locked_at = now()
   where user_id = u.uid and session_id <> u.sid and not locked;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_changed', 'user', u.uid::text);
  return r;
end $$;

-- Forgotten PIN: allowed within 10 minutes of signing in (password, Google, email link…).
-- Every session of the user — this one included — must then unlock with the new PIN.
create or replace function public.reset_store_pin(p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  perform app.rate_limit('pin_reset:' || u.uid, 5, 3600);
  if not app.fresh_login() then perform app.raise('fresh_login_required'); end if;
  if not app.valid_pin(p_new) then perform app.raise('pin_too_simple'); end if;
  insert into app.store_pins (user_id, pin_hash) values (u.uid, extensions.crypt(p_new, extensions.gen_salt('bf', 10)))
  on conflict (user_id) do update set pin_hash = excluded.pin_hash, pin_changed_at = now(), failed_attempts = 0, locked_until = null;
  perform app.lock_session_row(u.uid, u.sid);
  update app.store_lock_sessions set locked = true, reason = 'pin_reset', locked_at = now() where user_id = u.uid;
  insert into public.audit_logs (user_id, action, entity, entity_id) values (u.uid, 'store_lock.pin_reset', 'user', u.uid::text);
  return public.store_lock_status();
end $$;

create or replace function public.set_store_lock_timeout(p_minutes int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u record;
begin
  select * into u from app.require_session();
  if app.session_locked() then perform app.raise('store_locked'); end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 240 then perform app.raise('invalid_input'); end if;
  update app.store_pins set idle_minutes = p_minutes where user_id = u.uid;
  if not found then perform app.raise('pin_not_set'); end if;
  update app.store_lock_sessions set last_activity = now() where session_id = u.sid;
  return public.store_lock_status();
end $$;

-- ---------------------------------------------------------------------------
-- Enforcement: the shared access checks refuse a locked session
-- ---------------------------------------------------------------------------
create or replace function app.require_auth() returns uuid language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then perform app.raise('not_authenticated'); end if;
  if app.session_locked() then perform app.raise('store_locked'); end if;
  return v;
end $$;

create or replace function app.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

create or replace function app.my_business_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select case when app.session_locked() then '{}'::uuid[] else
    (select coalesce(array_agg(business_id), '{}') from public.business_members where user_id = auth.uid() and active) end
$$;

create or replace function app.is_member(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and exists (select 1 from public.business_members
                 where business_id = bid and user_id = auth.uid() and active)
$$;

create or replace function app.can_read(bid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and (app.is_member(bid) or (
    app.is_platform_admin() and exists (
      select 1 from public.support_access_grants g
      where g.business_id = bid and g.revoked_at is null and g.expires_at > now())))
$$;

create or replace function app.has_perm(bid uuid, perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.session_locked() and coalesce((
    select case
      when m.role = 'owner' then true
      when m.permissions ? perm then (m.permissions ->> perm)::boolean
      else perm = any (app.role_permissions(m.role))
    end
    from public.business_members m
    join public.businesses b on b.id = m.business_id and b.status = 'active'
    where m.business_id = bid and m.user_id = auth.uid() and m.active
  ), false)
$$;

create or replace function public.get_my_context()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then return null; end if;
  if app.session_locked() then perform app.raise('store_locked'); end if;
  return jsonb_build_object(
    'user_id', uid,
    'email', (select email from auth.users where id = uid),
    'email_confirmed', (select email_confirmed_at is not null from auth.users where id = uid),
    'profile', (select to_jsonb(pr) from public.profiles pr where pr.id = uid),
    'is_platform_admin', app.is_platform_admin(),
    'pending_invites', (select count(*) from public.business_invites i
                        where lower(i.email) = lower((select email from auth.users where id = uid))
                          and i.accepted_at is null and i.revoked_at is null),
    'businesses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'role', m.role, 'status', b.status, 'currency', b.currency,
        'currency_decimals', b.currency_decimals, 'language', b.language, 'timezone', b.timezone,
        'category', b.category, 'logo_path', b.logo_path, 'country_code', b.country_code,
        'permissions', to_jsonb(app.my_permissions(b.id)),
        'subscription', app.subscription_info(b.id),
        'plan', (select jsonb_build_object('code', ep.code, 'name_en', ep.name_en, 'name_fr', ep.name_fr,
                                           'features', ep.features, 'limits', ep.limits)
                 from app.effective_plan(b.id) ep)
      ) order by b.created_at)
      from public.business_members m join public.businesses b on b.id = m.business_id
      where m.user_id = uid and m.active and b.status <> 'closed'), '[]'::jsonb));
end $$;

revoke execute on function app.check_pin(uuid, text) from public, anon, authenticated;
revoke execute on function app.lock_session_row(uuid, uuid) from public, anon, authenticated;
grant execute on function app.session_locked() to anon, authenticated; -- used inside RLS checks
revoke execute on function public.store_lock_status() from public, anon;
revoke execute on function public.set_store_pin(text) from public, anon;
revoke execute on function public.lock_store() from public, anon;
revoke execute on function public.unlock_store(text) from public, anon;
revoke execute on function public.store_lock_heartbeat() from public, anon;
revoke execute on function public.change_store_pin(text, text) from public, anon;
revoke execute on function public.reset_store_pin(text) from public, anon;
revoke execute on function public.set_store_lock_timeout(int) from public, anon;
grant execute on function public.store_lock_status(), public.set_store_pin(text), public.lock_store(), public.unlock_store(text),
  public.store_lock_heartbeat(), public.change_store_pin(text, text), public.reset_store_pin(text), public.set_store_lock_timeout(int)
  to authenticated;
