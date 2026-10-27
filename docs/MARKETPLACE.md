# BizPilot Market

Every BizPilot business can open an online store connected to its own stock. Customers browse all stores at `/market`, buy from one store per order, and **pay the seller directly**: cash on delivery, or Mobile Money sent to the seller's own MTN / Orange number. They can also contact the seller on WhatsApp or by phone. **BizPilot never collects, holds or shares out buyer-seller money.** Fapshi is used only for BizPilot subscription fees.

## Payments between buyers and sellers (since 26 October 2026)

- **Cash on delivery:** the seller records the method (cash, MTN, Orange) when the order is delivered.
- **Mobile Money to the seller:** the seller adds their MTN and/or Orange number and account name under **My Store → Payments & policies**.
  - The buyer sees the numbers on their own order page and sends the money from their phone.
  - The buyer can enter the transaction ID ("I have paid"). This is evidence only: the order stays **Not paid yet**.
  - Only the seller can mark it **Payment received** (`seller_confirmed`), after checking their own account. A message or screenshot never marks an order paid.
  - Once the seller has confirmed, the buyer cannot cancel on their own. If the seller then cancels, the order shows `refund_pending` until the seller records the refund they sent ("I have sent the refund").
- **WhatsApp / phone:** product pages, carts and checkout have a WhatsApp link with the product, option, quantity, price and link. A sale agreed on WhatsApp is recorded by the seller with **Record a sale** (channel WhatsApp).
- **One sale per order:** delivering an order records exactly one shop sale (channel `marketplace`, client_ref = order id) with the confirmed method. Stock moves once, and the order cannot be delivered twice.
- **BizPilot online payment for orders is switched off:** `market_place_order` refuses `online`, stores can never switch it back on (trigger), and the Fapshi function answers `order_payments_direct`. Orders paid online before this date still work: delivery, refunds and settlements.

## Where things are

| Who | Page | What it does |
|---|---|---|
| Customer | `/market`, `/market/search` | Categories (22 business types), stores, new arrivals, search with filters (category, city, price, in stock) and sorting |
| Customer | `/s/{store-link}` | Storefront: products by category, about (description, hours, delivery areas and fees, pickup, payment methods, contacts the seller chose to show), verified reviews, share buttons, report |
| Customer | `/s/{store-link}/p/{id}` | Product: photos, price and "was" price, stock status, options (size × colour…), add to cart / buy now, wishlist, seller card, reviews, report |
| Customer | `/cart`, `/checkout` | One store per cart. Totals are always computed by the server. Guest checkout or signed in. Delivery area or pickup, cash on delivery or pay online, promo code |
| Customer | `/order/{id}` | Order tracking: timeline, payment status, pay now (online), cancel (while new), messages with the store, verified review after delivery, report a problem (dispute) |
| Customer | `/account` | Order history, wishlist, followed stores, saved addresses, profile. Guest orders placed on the same device are attached automatically |
| Seller | **Online store → My Store** (`/app/store`) | Create the store, setup checklist, publish / unpublish, share links, profile, logo, contact visibility, opening hours, delivery areas, pickup, minimum order, payment methods, cover and brand colour (plan feature), reviews and replies, verification request |
| Seller | **Online store → Orders** (`/app/orders`) | To confirm / awaiting payment / in progress / delivered / closed. Order page: accept, decline, preparing, sent / ready for pickup, delivered (cash collected and method, received by, proof photo), cancel, refund / return, messages and private notes, WhatsApp the customer |
| Seller | **Online store → Promotions** | Discount codes (percentage or fixed, minimum order, dates, maximum uses), plan feature |
| Seller | **Money → Payments** (`/app/payments`) | What BizPilot owes the seller, money held for undelivered orders, payouts, fees, balance history, online payments |
| Seller | **Catalogue → Products** | "Online" tab, an on/off switch per product, bulk show/hide. In the product form: **Online store** section (show online, online photos, "was" price) |
| Admin | `/admin/market` and the next tabs | Marketplace rules (open/closed, online payments switch, commission, online fee, time limits, COD order limit per phone, policies), stores (verify, suspend, restore, ledger), listings (hide / restore), reports and disputes, reviews moderation, blocked contacts, orders needing attention (refunds, flags, disputes), payment issues, seller settlements and payouts |

## How stock stays in sync

- A listing is the seller's own BizPilot product (`products.online_published`). Variants are its child products, each with its own price and stock.
- Placing an order **reserves** the stock (`stock_reservations`). Available online = stock on hand − active reservations.
- A counter sale cannot use reserved stock (`app.apply_movement` refuses it with "not enough stock"), unless the business allows negative stock.
- Orders lock the product rows while they are placed, so two buyers cannot get the last item. This is tested with concurrent orders.
- When the seller marks the order **delivered**, BizPilot records a normal sale: stock leaves through the stock ledger at the current average cost, the payment lands in the matching cash account (cash, MTN, Orange; "Other" for online payments held by BizPilot), and the buyer appears under Customers. The cash-on-delivery delivery fee is recorded as a deposit in the same account. Reports, cash reconciliation and profit stay complete.
- Unpaid online orders release their stock after the "time to pay online" (30 minutes by default). Cash-on-delivery orders the seller never confirms are cancelled after 48 hours. A payment that arrives after an order timed out reopens it if the stock is still there; otherwise the order is marked for refund.

## Order and payment states

Order: `pending → confirmed → processing → dispatched → delivered`, or `cancelled`, or `refunded` (after delivery).
Payment: `cod_pending → cod_collected`; `awaiting_payment → paid` (or `failed`, retry allowed); `refund_pending → refunded`; `void` (cancelled before any payment).

## Online payments (Fapshi)

What Fapshi offers, from its official docs (docs.fapshi.com):
- a hosted checkout (`initiate-pay`) whose link expires after 24 hours;
- **direct pay** (`direct-pay`): the payment request goes straight to the payer's phone and they approve it with their Mobile Money PIN. Fapshi **disables it by default on live services**; ask Fapshi support to activate it for your service;
- the service balance (`balance`);
- `payment-status`, limited to 6 checks per minute per transaction;
- a webhook for SUCCESSFUL, FAILED and EXPIRED, sent **once**, authenticated with an `x-wh-secret` header;
- payouts through a separate service that Fapshi must enable.

Fapshi documents **no split payments, no automatic recurring charges and no refund endpoint**. BizPilot is built around that:

1. BizPilot collects with **its own** Fapshi service. The amount comes from the database (`market_payment_begin`), never from the browser.
2. The `fapshi` edge function receives the webhook, checks `x-wh-secret` in constant time, **then asks Fapshi for the status itself**. Only that answer, applied by `fapshi_apply`, marks a payment paid. The browser redirect only triggers the same server check, and a screenshot never changes anything.
3. Safety rules:
   - Duplicate notifications are ignored.
   - A second successful payment for the same order is flagged for refund.
   - A wrong amount or reference is flagged for an administrator and does not mark the order paid.
   - Starting a new payment closes the previous unpaid link first (`expire-pay`).
4. When the order is delivered, the amount is added to the seller's **balance** (`market_ledger`), minus any configured commission and online fee.
5. BizPilot pays sellers outside the app (Mobile Money, bank or a Fapshi payout service), then records each payout with its reference in **Admin → Settlements**. The seller sees it under **Payments**.
6. Refunds to buyers are sent by BizPilot the same way and recorded in **Admin → Orders** (`refund_pending → refunded`).
7. Subscriptions can also be paid with Fapshi from **Subscription → choose a plan**. A verified payment extends the plan by one month or one year automatically. There is no automatic renewal: the owner pays each period.

### Paying by phone (direct pay)

1. The payer enters their MTN MoMo or Orange Money number (the checkout phone is used for orders; the operator is detected from the number and can be changed).
2. The `fapshi` function sends `direct-pay` with the amount from the database. Fapshi pushes the request to the phone.
3. The page shows "Approve the payment on your phone" and asks the server every 5 seconds. The server asks Fapshi (`payment-status`, throttled), and the webhook usually arrives first.
4. When Fapshi reports SUCCESSFUL, `fapshi_apply` marks the order paid, or activates the plan through a verified `billing_payments` row (method `fapshi`). The page updates by itself.
5. Declined, cancelled or insufficient balance: the page says so, and the payer can try again. Nothing is marked paid from the browser.
6. If direct pay is not activated on the Fapshi service, Fapshi refuses the request, so no pop-up reaches the phone. The payer is then told this and continues on the Fapshi payment page, where they enter their number and get the approval request. They can also choose that page themselves.
7. Fapshi's last answer to a direct-pay request (accepted, or refused with its reason) is kept privately in `app_config` (`fapshi_direct_pay`). **Admin → Mobile Money** shows it with the steps to ask Fapshi support for activation.

The money is collected into BizPilot's Fapshi service: it shows in the Fapshi dashboard balance at once, and withdrawals are made from there. **Admin → Mobile Money** shows:
- the live Fapshi balance, read on the server, so the keys never reach the browser;
- what was received today, in 7 days and in 30 days (subscriptions and orders);
- requests still waiting for approval;
- every payment with its Fapshi transaction ID.

It refreshes every 15 seconds. **Admin → Overview** also shows "Mobile Money today".

Commission (default 0 %) applies to the goods amount of delivered orders. For cash on delivery the seller owes it, and it shows as a negative balance. The online fee (default 0 %) applies to online orders only. Both are shown to sellers on **My Store → Payments** and **Payments** before they use online payment.

## Turning on online payments

1. **Fapshi account:**
   1. Activate your Fapshi account and create a **collection service**.
   2. Copy its **API user** and **API key**. The key is shown once; keep it only in step 3.
   3. Test first with the **sandbox** service and the test numbers (MTN 670000000 succeeds, 670000001 fails).
2. **Supabase → Edge Functions → Deploy a new function → Via editor:**
   1. Name it exactly `fapshi`.
   2. **Delete all the template code** in the editor (the "Hello" example that imports `@supabase/server`). Paste the whole of `supabase/functions/fapshi/index.ts` (one file, no dependencies) and deploy.
   3. In the function's settings, **turn off "Verify JWT"**, because Fapshi's webhook has no Supabase token. The function checks every caller itself.
3. **Supabase → Edge Functions → Secrets**, add:
   - `FAPSHI_API_USER`, `FAPSHI_API_KEY`;
   - `FAPSHI_BASE_URL`: `https://sandbox.fapshi.com` while testing, `https://live.fapshi.com` for real money;
   - `FAPSHI_WEBHOOK_SECRET`: a long random text you invent;
   - `SITE_URL`: `https://www.bizpilotmarket.com`.
   - `SUPABASE_URL`, plus the anon/publishable and service-role/secret keys, are provided by Supabase. The function reads either the old variable names or the new `SUPABASE_PUBLISHABLE_KEYS`/`SUPABASE_SECRET_KEYS`. Never put any of these in Vercel or the browser.
4. **Fapshi dashboard → your service:**
   - webhook URL: `https://cvruxxkgfbsatqvpysey.supabase.co/functions/v1/fapshi/webhook`;
   - webhook secret: the same value as `FAPSHI_WEBHOOK_SECRET`;
   - leave IP whitelisting empty, because Supabase Edge Functions have no fixed IP.
5. **BizPilot → Admin → Marketplace:** tick **Online payments (Fapshi) available** and set the fees (or leave 0 %). Save.
6. Sellers can now tick **Pay online** under **My Store → Payments**.
7. Test one order end to end in sandbox mode, then switch the secrets to live credentials and the live URL.
8. **Test keys are safe on the live site.** A key starting with `FAK_TEST_` is a sandbox key, and the function always uses `https://sandbox.fapshi.com` for it. Sandbox approves test payments without moving any money, so in test mode only platform administrators can start a payment, and customers see "Mobile Money payment is not available yet". Admin → Mobile Money shows a TEST mode notice until live keys are set.
9. Ask Fapshi support to **activate direct pay** on the live service, so payers get the request on their phone. Until then, payers are sent to the Fapshi payment page automatically.

## Plans

| Plan | Online listings | Promotions | Cover photo & brand colour |
|---|---|---|---|
| Free | 20 | no | no |
| Starter | 300 | yes | yes |
| Business | unlimited | yes | yes |

The values are data: edit them in **Admin → Plans** (`max_online_products`, features `promotions`, `store_customization`). When a paid plan expires, nothing is deleted: listings above the new limit are hidden (oldest stay visible) until the seller renews or hides some.

## Trust and safety

- **Reviews:** only for products of a delivered order, once per product. The seller can reply; administrators can hide a review.
- **Reports:** anyone can report a listing or store, confidentially. Buyers open a dispute from their order. The admin queue tracks open → reviewing → resolved or dismissed, and the resolution of a dispute appears on the order.
- **Fraud controls:**
  - at most 3 open cash-on-delivery orders per phone number and store (configurable);
  - at most 10 orders per phone number per hour;
  - 120 orders per IP per hour (mobile networks share IPs);
  - blocked phone numbers and emails;
  - sellers cannot buy from their own store.
- **Contact details:** sellers choose which contacts are public. A buyer's name, phone and address are visible only to that store's staff with the orders permission, and to platform administrators.
- **Isolation:** every table has Row Level Security. The public only reaches marketplace data through functions that return safe columns: never costs, stock values, suppliers or other customers. Sellers never see other sellers' orders, customers, stock or money (tested).
- **Audit:** store, order, payment, refund, payout, moderation and configuration actions are written to the audit log.

## Database upgrade

New projects: `01_bizpilot_setup.sql` already includes everything. Existing project (created before 25 October 2026), in the Supabase SQL Editor:

1. `04_upgrade_catalog_and_store_lock.sql`, if not run yet.
2. `05_upgrade_marketplace.sql`, in one transaction. If the editor refuses a query this large, run `05a_upgrade_marketplace_part1.sql`, then `05b_upgrade_marketplace_part2.sql`.
3. `06_upgrade_direct_trade.sql` adds:
   - direct payments to sellers;
   - sales channels, delivery costs and cancelling a sale;
   - product condition and one-of-a-kind items;
   - comparing sellers, the channel report and the new alerts.

   It checks that 05 is installed. It can be run again safely: verified on a copy with data, where sales, stock, totals and payments were unchanged, and on a second run.
4. `07_upgrade_storefront_chat.sql` adds:
   - stock status on product cards (In stock, Low stock, Out of stock), from recorded stock only;
   - the city selector for real: shops and products are filtered by city, with accents and capitals ignored, and the shopper dashboard numbers;
   - messaging between shoppers and stores: product-linked conversations, unread counts, the inbox and the notifications list.

   It checks that 06 is installed (`scripts/sql/check_before_07.sql`). Each statement only creates or replaces functions and adds new tables; it changes no existing business, product, stock, sale or payment.

5. `08_upgrade_profile_photos.sql` adds profile photos and checked, cropped store logos and covers. Pictures are stored privately to their owner (`scripts/sql/check_before_08.sql`).
6. `09_upgrade_locations_delivery.sql` adds the ten regions of Cameroon, a maintained list of towns, and delivery areas by region and town. Existing delivery zones keep their behaviour (`scripts/sql/check_before_09.sql`).
7. `10_upgrade_order_lifecycle.sql` adds the buyer's receipt step, problems on orders, and review rules (`scripts/sql/check_before_10.sql`). It also fixes an access check: a signed-in account could act on a guest order with any token. Existing orders keep receipt status "none" and behave as before.
Each file checks that it is run in the right order and only once. They add tables and functions and do not change existing businesses, products, stock, sales, payments or customers (verified on a copy with data). Until they are run, the app keeps working: the market says "opening soon" and seller pages explain the update.


## Order lifecycle: delivery, receipt and reviews

- The seller marks an order delivered as before: the sale, stock and cash are recorded at that point.
- The buyer then confirms receipt, or reports a problem, in the receipt card on the order page. The receipt window is 3 days from delivery (`app.order_receipt_start`).
- A problem reported on an order holds the receipt ("Problem reported") until support resolves or dismisses it. Resolving releases it for the buyer to confirm; dismissing returns it to the buyer.
- A review opens once the buyer has confirmed receipt, or the window has passed with no problem reported. It does not open while a problem is open. A buyer can edit a review once, within 48 hours of posting; the edit is marked.
- Reviews and order problems can be reported. Reports about a review go to the same list as other reports, for moderation.
- Nothing is confirmed on the buyer's behalf. When the window passes, the receipt stays open for the buyer, and only the review rule above changes.

Decisions to confirm with the business: the 3-day window, that reviews open after the window without a problem, and the 48-hour edit window. Each is one value in the migration (`20261027000600_order_lifecycle.sql`).

## Messages and background notifications

- A shopper messages a store from the store page or a product page ("Message the seller"). A conversation belongs to one shopper, one store and, when it starts from a product, that product. Members of the store who can manage orders (owner, manager, cashier) answer from **Messages** in the seller app, or from the same Messages page in the shop.
- A new message shows as a pop-up while BizPilot is open, raises the bell and the Messages badge, and appears in the notifications list.
- Background notifications, when the app is closed, need a one-time setup:
  1. Make a VAPID key pair: `npx web-push generate-vapid-keys` (or any tool that makes P-256 keys in base64url form).
  2. Supabase → Edge Functions → Secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` (a `mailto:` address). Deploy with `supabase functions deploy chat-push` and keep JWT verification on.
  3. The build host: `VITE_VAPID_PUBLIC_KEY` with the public key, then redeploy.
  Until these are set, messaging works without background alerts, and the account page says they are not available.
- Each person turns alerts on per device under **My account → Profile**, and the browser must allow notifications. On iPhone, web push works only after the app is added to the Home Screen.

## Testing

- **DB tests:** `tests/db/storefront.test.ts` (5 tests: stock status, read-only storefront for customers, store editing by owners and managers only), `tests/db/shopper.test.ts` (6 tests: city filtering, accents and capitals, city counts, dashboard sign-in), `tests/db/messaging.test.ts` (12 tests: conversations, unread counts, inbox rows, isolation between shoppers and stores, refused writes, push subscriptions), `tests/db/marketplace.test.ts` (15 tests, including direct Mobile Money to the seller), `tests/db/records.test.ts` (8 tests: channels, delivery cost, duplicates, credit, cancellation, partial returns, incomplete profit, one-of-a-kind items, alerts) and `tests/db/fapshi_function.test.ts` (12 tests, subscriptions only: the edge function against the real local database with a simulated Fapshi API).
- **Browser tests:** `e2e/marketplace.spec.ts` covers seller setup, guest checkout, fulfilment, review, online payment and admin moderation. For the online payment test, run:
  ```
  node e2e/fapshiMock.mjs &
  supabase functions serve fapshi --no-verify-jwt --env-file <file with FAPSHI_API_USER=e2e-user, FAPSHI_API_KEY=e2e-key, FAPSHI_WEBHOOK_SECRET=e2e-webhook-secret, FAPSHI_BASE_URL=http://<docker gateway>:4999, SITE_URL=http://localhost:5173>
  ```
- **Order lifecycle:** `tests/db/order_lifecycle.test.ts` (14 tests: receipt window, confirmation once, disputes holding and releasing the receipt, review gating, one edit, review reports, and access to guest orders).
- **Old database:** `e2e/legacy-db.spec.ts` (run with `LEGACY_DB=1`) checks the app on a database without the upgrades.
