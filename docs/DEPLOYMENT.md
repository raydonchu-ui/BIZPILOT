# Deploying BizPilot

> **Status:** BizPilot has **not** been deployed to `https://cvruxxkgfbsatqvpysey.supabase.co` or to any web host. All verification so far ran against a local Supabase stack. These are the steps to deploy it.

## 1. What you need

| Item | Where to get it | Used for |
|---|---|---|
| Supabase project (`cvruxxkgfbsatqvpysey`) | supabase.com dashboard | Database, auth, storage, edge function |
| Supabase **access token** or the **database password** | Dashboard → Account → Access Tokens / Project Settings → Database | `supabase link`, `db push`, `functions deploy` (on your machine or in CI, never in the app) |
| Project **anon / publishable key** | Project Settings → API | `VITE_SUPABASE_ANON_KEY` (public by design) |
| Static web host (Netlify, Vercel, Cloudflare Pages, …) | Host account | Serving `dist/` over HTTPS |
| Anthropic API key (optional) | console.anthropic.com | AI Advisor (server secret) |
| SMTP provider (recommended) | Resend, Brevo, Mailgun, … | Auth emails (confirmation, password reset) at production volume |
| MTN MoMo / Orange Money merchant numbers | The operators | Numbers shown on the Subscription page for manual payment |

## 2. Database, storage and edge function

From the project folder on a trusted machine:

```bash
npm install
npx supabase login                                    # or export SUPABASE_ACCESS_TOKEN=...
npx supabase link --project-ref cvruxxkgfbsatqvpysey  # asks for the database password
npx supabase db push                                  # applies supabase/migrations in order
npx supabase functions deploy ai-advisor
npx supabase secrets set ANTHROPIC_API_KEY=sk-ant-...   # optional; without it the Advisor uses rule-based answers
npx supabase secrets set AI_MODEL=claude-opus-5-5       # optional; this is the default
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are provided to edge functions automatically on hosted Supabase. The function verifies the caller's JWT itself and runs every query as that user, so RLS applies.

The migrations create the private storage bucket `business-files` and its policies. Uploads are limited to 5 MB and to PNG, JPEG, WebP and PDF.

**Before the first `db push`**, check that the project is empty. The migrations assume a fresh `public` schema.

## 3. Auth settings (dashboard → Authentication)

The local `supabase/config.toml` does not apply to the hosted project. Set these in the dashboard:

| Setting | Value |
|---|---|
| Site URL | your production URL, e.g. `https://app.example.cm` |
| Redirect URLs | `https://app.example.cm/login`, `https://app.example.cm/reset-password` (add preview URLs if used) |
| Confirm email | **On** (the app only accepts staff invitations for verified emails) |
| Minimum password length | 8 (the app also enforces 8) |
| Leaked password protection | On, if your plan offers it |
| SMTP | Configure a provider. Supabase's built-in sender is rate-limited and meant for testing |
| Email templates | Optionally translate to French; the app's links already work with the defaults |

## 4. First platform administrator

There is no public admin registration. To create the first administrator:

1. Sign up normally in the deployed app with the administrator's email and confirm it.
2. In the dashboard SQL editor (which runs as `postgres`), run:
   ```sql
   select app.bootstrap_platform_admin('admin@example.com');
   ```
   The function is revoked from `anon` and `authenticated`, so it can't be called through the API.
3. That administrator can add more administrators under **Admin → Settings → Add platform administrator** (target account must have a verified email).

## 5. Platform configuration (Admin → Settings)

Edit these JSON values before opening sign-ups:

- `payment_instructions`: set `mtn_momo` / `orange_money` to `{ "enabled": true, "number": "6XX XX XX XX", "account_name": "..." }` and optional `notes_en` / `notes_fr`. Until enabled, the Subscription page tells users to contact support.
- `support_contact`: email, phone and WhatsApp shown on the Contact page.
- `trial`: plan and length of the free trial (default Business, 30 days). `grace_days` (default 7). `renewal_notice_days` (default 7).
- Plans and prices: **Admin → Plans** (seeded: Free, Starter 1,500 FCFA/month, Business 3,000 FCFA/month).

## 6. Frontend

```bash
cat > .env.production.local <<'EOF'
VITE_SUPABASE_URL=https://cvruxxkgfbsatqvpysey.supabase.co
VITE_SUPABASE_ANON_KEY=<anon or publishable key>
EOF
npm run build      # outputs dist/
```

Deploy `dist/` as a single-page app:

- **Netlify / Cloudflare Pages:** `public/_redirects` (SPA fallback) and `public/_headers` (security headers) are copied into `dist/`.
- **Vercel:** `vercel.json` has the rewrite and headers.
- **Other hosts:** serve `index.html` for unknown paths, serve over HTTPS, and don't cache `sw.js` or `index.html` long-term.

Environment variables (all public; only these two reach the browser):

| Variable | Example | Notes |
|---|---|---|
| `VITE_SUPABASE_URL` | `https://cvruxxkgfbsatqvpysey.supabase.co` | |
| `VITE_SUPABASE_ANON_KEY` | `eyJ…` / `sb_publishable_…` | Public by design. Never put the service-role or secret key here |

Server-only secrets (Supabase secrets, never in `.env` files the frontend reads):

| Secret | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | No | Enables AI answers |
| `AI_MODEL` | No | Defaults to `claude-opus-5-5` |

## 7. Optional: scheduled alerts

Low-stock, expiry, overdue-credit and renewal alerts are generated when a user opens the app (`generate_alerts`, deduplicated). To generate them on a schedule as well, enable `pg_cron` in the dashboard and run:

```sql
select cron.schedule('bizpilot-alerts', '15 6 * * *', $$ select app.generate_all_alerts() $$);
```

`app.generate_all_alerts()` is revoked from API roles, so only database-side jobs can call it. Alerts are deduplicated per day: running it twice adds nothing the second time (tested locally). The `pg_cron` schedule itself was not tested on the hosted project.

## 8. After deploying: smoke check

1. Open the site. Pricing should show the three plans, and FR/EN switching should work.
2. Sign up, confirm the email, and create a business (Cameroon).
3. Add a product with opening stock, record a sale, and check the dashboard figures.
4. Install it on a phone (Add to Home Screen), go offline, record a sale, go back online, and check that it syncs.
5. As admin: verify a test payment, then reject a duplicate reference.
6. Run the e2e suite against the deployment: `E2E_BASE_URL=https://app.example.cm npx playwright test e2e/core.spec.ts`. It creates test users and businesses; delete them afterwards.
