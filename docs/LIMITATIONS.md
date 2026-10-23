# Known limitations and open items

This list is deliberately blunt. "Not tested" means it was not run, not that it fails.

## Not deployed

- Nothing is deployed to `https://cvruxxkgfbsatqvpysey.supabase.co` or any web host. Deploying needs the project's anon key, plus the database password or a Supabase access token, and a static host account. See [DEPLOYMENT.md](DEPLOYMENT.md).
- All verification ran against a local Supabase stack (Postgres 17, CLI-managed containers). Hosted settings (auth emails, SMTP, rate limits, storage limits, edge runtime) can differ.

## Integrations

| Area | Status |
|---|---|
| MTN MoMo / Orange Money | **Not integrated.** Subscription payments are recorded by the user and verified manually by an administrator. There are no provider APIs, webhooks or automatic reconciliation. Customer sale payments by mobile money are recorded as a method and reference only |
| AI Advisor | Function code is implemented. Tested locally with **no key** (rule-based fallback) and with an **invalid key** (the SDK reached Anthropic, got 401, recorded the failure, fell back). **A real AI answer was not tested** (no API key was available). The `server-side-fallback` beta parameter was not checked against the live API |
| Email notifications | **Not implemented.** Alerts are in-app only. Auth emails (confirmation, reset) use Supabase Auth and need SMTP configured in production. Support replies show in the app, not by email |
| SMS / WhatsApp | Not implemented (receipts can be printed or saved as PDF from the browser) |
| Scheduled jobs | Alerts are generated when the app opens. The optional `pg_cron` schedule is documented but was not tested on the hosted project |

## Product scope

- **Offline:** only **sales** can be recorded offline (queued on the device, synced when back online, and shown as *pending* until the server confirms). Purchases, expenses, stock counts and settings need a connection. Product search uses the last cached catalog. If a queued sale is rejected while syncing (e.g. stock ran out), it is kept as *failed* for the user to retry or discard. It is never silently dropped.
- **One location per business.** No multi-branch stock or transfers.
- **One currency (XAF)** and **one enabled country (Cameroon)**. Other countries exist in the table but are disabled.
- **Imports:** products (with opening stock), suppliers and customers from CSV, with preview and rollback. Historical sales and purchases can't be imported.
- **Barcode camera scanning** uses the browser's `BarcodeDetector`, available in Chrome/Edge on Android and desktop but not Safari/iOS. Typing or using a USB/Bluetooth scanner works everywhere.
- **Receipts** are browser-printable/PDF. They are **not fiscal invoices** and don't meet any tax-authority e-invoicing requirement.
- **Tax:** one inclusive sales-tax rate per business (off by default). VAT returns, withholding and other taxes are not handled.
- **Reports** are management figures, not OHADA/SYSCOHADA financial statements.

## Security

- RLS, permission checks, entitlement checks and idempotency are covered by automated tests (see delivery report). **No external penetration test or professional security review has been done.**
- **MFA is not enforced** for platform administrators. Recommended: enable Supabase MFA (TOTP) and require it for admin accounts before launch (not implemented in the UI).
- No CAPTCHA on sign-up or the contact form. Supabase Auth rate limits apply, plus database rate limits on the contact form (5/hour), business creation (5/day), payment submissions (10/day) and AI questions (20/hour per user). Consider enabling Supabase's CAPTCHA (hCaptcha/Turnstile).
- No Content-Security-Policy header is shipped (other security headers are in `public/_headers` and `vercel.json`). Add a CSP once the final domains are known.

## Testing gaps

- No load/performance testing. Analytics functions run on demand. Very large businesses (hundreds of thousands of movements) may need materialized summaries.
- Browser tests ran in Chromium only (desktop 1440×900 and Pixel 7 emulation). Not tested on Safari/iOS, Firefox, or real low-end Android devices.
- PWA install and offline behaviour were tested in emulation, not on a physical phone.
- No full accessibility audit (form labels and headings are checked by the tests; contrast and screen-reader flows were not audited).
- No backup has been taken from or restored to the hosted project.

## Legal review needed

The Terms, Privacy Policy and Billing Policy pages are **drafts written for a Cameroonian SaaS**. They have not been reviewed by a lawyer, and BizPilot makes no claim of legal compliance. Before launch, have counsel check at least:

- Cameroon's personal data protection framework, including the 2024 personal data protection law and its implementing texts, plus Law No. 2010/012 on cybersecurity and cybercrime: consent, data location and transfers (Supabase region), breach notification, any registration with the authority.
- Law No. 2010/021 on electronic commerce: mandatory information, contract formation, consumer rights.
- Tax obligations for selling the subscription (VAT on digital services, invoicing requirements).
- Wording on refunds, price changes and data retention in the Billing Policy.
- The operator's identity. The legal pages don't yet name the company running BizPilot (legal name, address, RCCM, taxpayer number, contact). Add it once the operating entity exists.
