# Operating BizPilot

## Subscription payments (manual verification)

BizPilot does **not** connect to MTN MoMo or Orange Money. It never starts or takes a payment. The flow is:

1. The owner sends the plan price to the merchant number shown on **Subscription** (set in Admin → Settings → `payment_instructions`).
2. They enter the provider's transaction ID, the amount, the payer's number/name and, optionally, a screenshot (private storage).
3. In **Admin → Payments**, an administrator checks the provider's merchant statement for that exact reference, amount, date and receiving account. A screenshot alone is not proof.
4. **Verify** activates the plan, or extends it from the end of the current paid period. **Reject** records a reason. Both are audited.

Safeguards: a transaction reference can only be used once (unless the earlier one was rejected), and amounts that differ from the expected price are highlighted. Only platform administrators can verify. A business can never activate its own plan.

To later automate this with an operator's API, a server-side webhook would need to verify signatures and call the same verification function. That integration is not built (see LIMITATIONS.md).

## Plans and pricing

Admin → Plans edits prices, features and limits. Changes apply right away to entitlement checks; periods already paid are not changed. Remember to update the public FAQ/Terms wording if you change what plans include. Feature keys and limit keys are listed in `supabase/migrations/20261022000150_plans_entitlements.sql`.

## Support access and privacy

Administrators see platform metadata and usage counts only. To look at a business's records, the **owner** grants time-limited support access (Settings → Data & privacy → Support access). The administrator then opens a support session, which is logged. Owners can revoke access at any time. Every admin action is in Admin → Audit log.

## Backups and recovery

| What | How |
|---|---|
| Database | Supabase daily backups (retention depends on your Supabase plan). For point-in-time recovery, enable the PITR add-on. **Recommended:** also run your own off-site `pg_dump` (below) |
| Storage (receipts, logos, payment proofs) | Not included in database backups. Copy the `business-files` bucket regularly (e.g. with `rclone` via the S3-compatible endpoint) |
| Per-business export | Owners can download all their data as JSON (Settings → Data & privacy), and lists as CSV |
| Code and migrations | Keep this repository in Git. The schema can be rebuilt from `supabase/migrations` |

Off-site dump (run from a trusted machine; the connection string contains the database password, so never commit it):

```bash
pg_dump "$SUPABASE_DB_URL" --format=custom --no-owner --file=bizpilot-$(date +%F).dump
```

Restore test (do this at least once before launch, then quarterly):

```bash
npx supabase start      # empty local stack, or a separate staging project
pg_restore --no-owner --clean --if-exists -d "postgresql://postgres:postgres@127.0.0.1:54322/postgres" bizpilot-YYYY-MM-DD.dump
npm run test:db         # sanity check that functions and policies still work
```

> **Not tested:** no backup has been taken from or restored to the hosted project. The commands above are standard procedure, not a verified runbook.

**Data is never deleted by the app.** Expired subscriptions keep all their data, and corrections are counter-entries. To delete a business on request, use the SQL editor deliberately: export first, then delete the `businesses` row (cascades) and its storage folder.

## Incident response

1. **Contain:** if a key leaks, rotate it right away (Supabase → API keys; Anthropic console). A leaked anon key is low risk because RLS applies, but rotate it anyway if abuse is suspected. Suspend affected businesses with Admin → Businesses → Subscription → *suspended* if needed.
2. **Investigate:** Admin → Audit log; Supabase logs (API, Auth, Postgres, Edge Functions); `audit_logs` and `stock_movements` (immutable ledger).
3. **Correct:** use counter-entries (returns, adjustments, voids), never direct `UPDATE`s on financial tables. If a restore is needed, restore to a separate project first and copy the affected rows.
4. **Inform:** tell affected owners what happened, which data, and what they should do. Check whether Cameroon's data-protection rules require you to notify an authority (legal advice needed).
5. **Learn:** add a test reproducing the issue in `tests/db` before you fix it.

## Monitoring

- Supabase dashboard → Reports (API errors, slow queries, auth sign-ups), plus email alerts for usage limits.
- Admin → Overview: payments waiting for verification, open support requests, failed AI calls.
- Admin → AI usage: questions, failures, rule-based fallbacks and tokens per day. Set a monthly spend limit in the Anthropic console.

## Maintenance

- **Schema changes:** add a new timestamped file in `supabase/migrations` (never edit one that's already deployed), run `npm run db:reset && npm test` locally, then `supabase db push`.
- **Function changes:** `supabase functions deploy ai-advisor`.
- **Frontend:** `npm run build` and redeploy `dist/`. Users get the new version on their next visit; the PWA prompts them to reload.
- **Dependencies:** `npm outdated` monthly; `npm audit` before each release.
- **Before each release:** `npm run typecheck && npm test && npm run test:e2e` (with `npm run dev` running against a local stack).
