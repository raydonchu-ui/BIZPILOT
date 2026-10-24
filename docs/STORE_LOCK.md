# Store Lock (4-digit PIN)

Store Lock locks BizPilot on a device when someone steps away from the counter. It is an extra
layer on top of the account password, never a replacement for it.

## How it works

- **First access:** the first time a person opens a store dashboard, they create a 4-digit PIN (typed twice). Obvious PINs (1234, 0000, 4321…) are refused. Each person (owner, manager, cashier) has their own PIN.
- **Locking:** the **Lock store** button (top bar) locks at once. The store also locks after the inactivity period chosen in **Profile → Store Lock** (1 minute to 4 hours, default 15 minutes).
- **Every new sign-in starts locked** once a PIN exists. Signing out and in again does not skip the PIN.
- **Unlocking** needs the PIN, checked by the server. After 5 wrong PINs the person waits 30 s, then 1, 2, 5, 10 and 15 minutes for further mistakes. The right PIN is also refused during a wait. Too many attempts are written to the audit log.
- **Changing the PIN** needs the current PIN. Other devices of that person are locked and ask for the new one.
- **Forgot PIN:** sign in again (password, Google or reset email). Within 10 minutes of that sign-in, a new PIN can be chosen. Then **every** device of that person is locked and needs the new PIN.

## What protects the data

- The lock is kept on the **server**, per signed-in session (the session ID in the Supabase login token). While a session is locked, every access check behind the database functions, row-level security and file storage refuses it. Refreshing the page, opening a direct link or calling the API does not get around it.
- The inactivity limit is also enforced by the server: if the app stops reporting activity, the session counts as locked when the period ends, even if the device was switched off.
- PINs are stored only as **bcrypt hashes** (`pgcrypto`, salted) in a database schema the API cannot read. The PIN is never stored in the browser, never logged, and never sent anywhere except the unlock request.
- When the store locks, business data cached in the page's memory is cleared.

## Limits (honest)

- A 4-digit PIN has 10 000 combinations. Its protection comes from the server-side waits, not from the hash: someone with direct database access could recover a PIN from its hash quickly. That's why PINs only guard sessions that are already signed in with the real password.
- Bcrypt is used because Argon2id isn't available inside Supabase Postgres without an extra service.
- **Offline:** an unlocked device keeps working offline (offline sales) and still locks after inactivity, but unlocking needs an internet connection.
- Database jobs and Supabase's service role aren't affected by the lock, by design.

## Where it lives

- Database: `supabase/migrations/20261024000200_store_lock.sql`
- App: `src/components/StoreLock.tsx`, `src/lib/storeLock.ts`, `src/pages/app/settings/ProfilePage.tsx`
- Tests: `tests/db/store_lock.test.ts`, `e2e/store-lock.spec.ts`
