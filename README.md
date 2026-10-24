# BizPilot — Your Business, Ahead.

Retail management, inventory and profit analytics for shop owners in Cameroon. Amounts in FCFA (XAF); interface in English and French. Runs in the browser and installs as a PWA on phones.

- **Frontend:** Vite + React 18 + TypeScript + Tailwind, TanStack Query, Recharts, `vite-plugin-pwa`
- **Backend:** Supabase (Postgres 17, Auth, Storage, Edge Functions). Every money or stock change goes through a `SECURITY DEFINER` Postgres function. Every table has Row Level Security.
- **BizPilot Market:** every business can open an online store at `/s/{link}` using its own BizPilot stock (reservations prevent overselling between the shop and online). It offers cash on delivery or online payment with Fapshi, verified on the server by the `fapshi` edge function, plus seller settlements, verified-purchase reviews, reports and disputes, and marketplace administration. See [docs/MARKETPLACE.md](docs/MARKETPLACE.md).
- **AI Advisor:** Supabase Edge Function `ai-advisor`, which calls the Anthropic API on the server. The key never reaches the browser. When the function is unavailable, the app gives rule-based answers instead.

## Documentation

| Document | Contents |
|---|---|
| [docs/SETUP_SIMPLE.md](docs/SETUP_SIMPLE.md) | **Start here:** set up Supabase + Vercel from the browser, no command line |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Deploying to your Supabase project and a static host, environment variables, auth settings, first administrator |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Payment verification, plans and pricing, backups and recovery, incident response, monitoring, maintenance |
| [docs/FINANCIAL_RULES.md](docs/FINANCIAL_RULES.md) | How BizPilot computes cost, profit, stock value, balances and the analytics |
| [docs/MARKETPLACE.md](docs/MARKETPLACE.md) | BizPilot Market: stores, orders, stock sync, Fapshi payments and settlements, plans, trust and safety, setup |
| [docs/STORE_LOCK.md](docs/STORE_LOCK.md) | How the 4-digit Store Lock PIN works, what it protects and its limits |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | What is not done, not verified, or needs a third-party account or legal review |

## Run locally

Requirements: Node 20+, Docker (for the local Supabase stack).

```bash
npm install
npx supabase start            # starts Postgres/Auth/Storage/Edge runtime and applies supabase/migrations
cp .env.example .env.local    # then set VITE_SUPABASE_URL=http://127.0.0.1:54321 and the local anon key printed by `supabase status`
npm run dev                   # http://localhost:5173
```

Optional, for the AI Advisor locally:

```bash
echo "ANTHROPIC_API_KEY=sk-ant-..." > supabase/functions/.env.local   # git-ignored
npx supabase functions serve --env-file supabase/functions/.env.local
```

Without a key, the function returns `mode: "fallback"` and the app shows rule-based answers built from the same server-computed figures.

Make yourself a platform administrator (local): sign up in the app, then run in `psql` (`postgresql://postgres:postgres@127.0.0.1:54322/postgres`):

```sql
select app.bootstrap_platform_admin('you@example.com');
```

## Scripts

| Script | What it does |
|---|---|
| `npm run dev` | Vite dev server |
| `npm run build` | Type-check (`tsc -b`) and production build to `dist/` |
| `npm run typecheck` | Type-check only |
| `npm test` | All Vitest suites (database integration tests + i18n coverage) |
| `npm run test:db` | Database integration tests against the local Supabase API (`tests/db`) |
| `npm run test:unit` | Frontend unit tests (`src/**/*.test.ts`) |
| `npm run test:e2e` | Playwright: core desktop workflow, mobile offline sale, every-route smoke test. Needs `npm run dev` running. |
| `npm run db:reset` | Recreate the local database from migrations |

Static analysis of the PL/pgSQL functions: `psql "$DB_URL" -f scripts/plpgsql_check.sql` (needs the `plpgsql_check` extension, which the local stack includes).

The AI Advisor function tests (`tests/db/ai_advisor.test.ts`) run only when `ADVISOR_URL` points to a served function. Set `ADVISOR_EXPECT` to `not_configured` (no key), `ai_error` (invalid key) or `ai` (valid key).

## Project layout

```
supabase/migrations/   schema, RLS, business logic (RPCs), analytics, storage, grants
supabase/functions/    ai-advisor edge function
src/lib/               Supabase client, auth/business context, offline queue, formatting
src/i18n/              English + French strings (fr is type-checked against en)
src/pages/public/      marketing site, pricing, legal pages, contact
src/pages/app/         the shop app (dashboard, sales, purchases, inventory, reports, …)
src/pages/admin/       platform admin portal (no public registration)
tests/db/              integration tests through the real Supabase API
e2e/                   Playwright tests
```
