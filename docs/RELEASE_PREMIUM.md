# Release notes: seller payments, Verified Premium, AI Business Manager, creators, finance, security

Run these upgrade files in the Supabase SQL Editor, **in order, once each**, after the earlier upgrades (01 → 09 are
already documented in `MARKETPLACE.md`). Each file starts with a check that the previous one is in place.

| # | File | Adds |
|---|------|------|
| 10 | `10_upgrade_order_lifecycle.sql` | Receipt step, problems on orders, review rules, access fix |
| 11 | `11_upgrade_payments_verified_premium.sql` | MTN/Orange settings per method; Verified Premium plan (5,000 XAF); verification applications; billing cancel and refund |
| 12 | `12_upgrade_ai_business_manager.sql` | AI Business Manager (premium), conversations, confirmed drafts |
| 13 | `13_upgrade_premium_automations.sql` | Premium automations, run records, retry |
| 14 | `14_upgrade_creator_program.sql` | Creator programme, referrals, commission ledger, payouts |
| 15 | `15_upgrade_admin_finance.sql` | Finance overview, drill-down, platform health, location maintenance |
| 16 | `16_upgrade_notifications_support.sql` | Notification preferences, buyer order notices, support replies, renewal reminders |
| 17 | `17_upgrade_security_hardening.sql` | Anonymous access closed to private functions |

Every file was replayed on a database that already had it applied (no errors), and the whole migration chain was
rebuilt from scratch with `supabase db reset` and tested. Replay from a database that is still at 09 has **not** been
run; run it on a copy first if the live database has drifted.

## Required after the SQL

1. **Redeploy the `chat-push` edge function.** Push payloads no longer show the sender's name or the message text.
2. **Scheduler (not configured).** These functions must run regularly; none is scheduled by this release:
   - `select app.run_due_automations();` (every hour is enough)
   - `select app.send_renewal_reminders();` (once a day)
   - `select app.expire_verifications();` (once a day)
   - `select app.prune_notifications(90);` (once a day)
   Use `pg_cron` if the project has it, or a scheduled edge function with the service role.
3. **Creator programme is off by default.** An administrator opens it on the Creators page. The suggested rate is 5%.
   Confirm the rate, the hold period (7 days), the minimum payout (5,000 XAF) and the attribution window (12 months).
4. **Verification thresholds** are in `app_config` key `verification`: 300 followers, 7 days' account age, a year's
   validity. Confirm them.
5. **Identity documents.** Each decision sets `documents_purge_after` (90 days). **Nothing deletes the files yet.**
   Either build the purge job or confirm that keeping them is acceptable.

## Not integrated (do not describe as working)

- **Creator payouts.** No payout API is connected. An administrator pays the creator outside BizPilot and records the
  provider reference. Fapshi's payout support was not verified against this account.
- **AI provider.** The AI Business Manager answers with fixed rules from recorded data. No external model is called.
  The existing advisor (`ai-advisor`) is unchanged and still needs `ANTHROPIC_API_KEY` for model answers.
- **Outbound customer messages from automations.** Not built. Automations only notify the seller or save drafts.

## Business decisions taken as defaults (confirm them)

- Verified Premium upgrade: paid in full, a new month from approval, no credit for unused days on the old plan.
- Reviews open once receipt is confirmed, or after the 3-day receipt window with no problem.
- A review may be edited once within 48 hours.
- Blue tick: an approval expires after a year; an expiring approval needs the premium plan. Manual administrator
  verifications without an expiry keep their tick.
- Commission is calculated on the amount paid, rounded to whole francs; the first commissioned payment is the first one
  approved after the programme opens.

## Tests run for this release

- `npx vitest run src tests/db`: 269 passed, 4 skipped (the AI advisor tests, which need the provider key).
- `npx playwright test`: 33 passed, 13 skipped (online-payment and mock-dependent cases, and the legacy-database spec).
- `npm run build`: passes.
- Browser checks on desktop and 390px phone widths for: seller payment settings, the blue-tick tab, billing with the
  upgrade card, the administrator verification queue, the AI Business Manager, premium automations, the creator
  workspace and admin creators page, the finance centre, the locations page, and the dashboard banner.

Pages not checked in a browser: the seller order detail after the receipt change, the notification preferences card,
and the admin payout actions (their rules are covered by the database tests).
