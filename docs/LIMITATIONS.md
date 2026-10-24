# Known limitations and open items

This list is deliberately blunt. "Not tested" means it was not run, not that it fails.

## Deployment

- The website is deployed on Vercel (www.bizpilotmarket.com) from the `main` branch. The database upgrades (`04`, `05`) and the edge functions (`ai-advisor`, `fapshi`) are applied by the project owner in the Supabase dashboard; this session has no Supabase access token or database password. Until they are applied, the app runs without the new features (see SETUP_SIMPLE.md).
- All verification ran against a local Supabase stack (Postgres 17, CLI-managed containers). Hosted settings (auth emails, SMTP, rate limits, storage limits, edge runtime) can differ.

## Integrations

| Area | Status |
|---|---|
| MTN MoMo / Orange Money (Fapshi) | **Implemented, not tested against Fapshi itself.** Marketplace orders and subscriptions can be paid online through Fapshi's hosted checkout. The edge function was tested against the real local database with a **simulated** Fapshi API that follows Fapshi's documented requests, responses and webhook. No real or sandbox Fapshi credentials were available, so a real sandbox transaction still has to be done (see MARKETPLACE.md). Manual subscription payments (reference + admin verification) still work. In-shop mobile money sales are recorded as a method and reference only |
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

## BizPilot Market (October 2026)

- **Payments:** Fapshi has no split payments, automatic recurring charges or refund API. Online payments go to BizPilot's Fapshi account. Seller payouts and buyer refunds are sent outside the app and recorded by an administrator with their reference. Subscriptions are paid one period at a time.
- **Accounting of online payments:** on delivery, the shop sale is recorded with payment method "Other" (money held by BizPilot) and the seller's BizPilot balance increases. The money reaches the seller's real accounts only when BizPilot pays out.
- **Delivery fees:** cash collected with a cash-on-delivery order goes into the cash account as a deposit, not as a sale. Delivery fees of online orders stay in the seller balance.
- **Notifications:** customers follow their order on its page and see the store's messages there. No email or SMS is sent (email delivery was failing on the live project, see SETUP_SIMPLE.md). Sellers get in-app notifications and can message customers on WhatsApp from the order.
- **Guest order links:** guests keep a private order link (stored on their device). Anyone with the link can open that one order, so customers should not share it publicly.
- **Expiry:** unpaid and unconfirmed orders are expired when someone uses the marketplace or a seller opens their dashboard (no background job). Until then their stock stays reserved only until the reservation time ends.
- **Search:** simple text matching (name, brand, description, category, store); no fuzzy matching or images search. Fine for thousands of listings; a search index would be needed at a much larger scale.
- **Variants on the storefront:** chosen by option buttons when all variants share the same detail fields (size, colour…); otherwise by their labels.
- **Not tested:** real Fapshi transactions, live webhook delivery, and payouts. Store verification is a manual review by an administrator (no document upload).

## Catalogue and Store Lock (October 2026)

- Variants are separate products linked to a main product (each with its own stock, price, SKU and barcode). The main product stays sellable; give it no stock if only its variants are sold.
- Serial numbers and IMEIs are stored per product as optional details, not tracked unit by unit.
- Subcategories are stored on products as text. Renaming a subcategory updates its products; moving a subcategory to another category doesn't.
- Store Lock limits are described in [STORE_LOCK.md](STORE_LOCK.md): 4-digit PIN strength, offline unlocking needs a connection, and bcrypt instead of Argon2id.
