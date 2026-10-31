# Creator programme

Creators share BizPilot with their audience. A business that signs up through a creator's link and subscribes earns
that creator a commission. Creators are paid to their Mobile Money account on request.

## How it works

1. **Apply** on the creator page (`/creator`). The application needs a display name and a Mobile Money provider and
   number for cashout. Channels and a short bio are optional. BizPilot reviews each application.
2. **Approval** sets the commission rate, from **3% to 10%** of the verified subscription payment. The suggested rate is
   5%. Approval also sets whether commission is paid on the first payment, on renewals, or both.
3. **Referral.** A visit to `?ref=CODE` is kept on that device. When the visitor signs in and has a business, the
   business is attached to the creator once: within 30 days of the business being created and before its first verified
   payment. Self-referrals are refused.
4. **Commission** is recorded automatically when a subscription payment is verified. It is held for 7 days, then it is
   available to withdraw. A refund reverses the commission made from that payment.
5. **Payouts.** A creator requests a payout of at least 5,000 XAF from the available balance. An administrator pays it
   to the Mobile Money account outside BizPilot and records the provider reference. No payout API is connected.

## Blue tick (Verified Premium)

An administrator can give the blue tick to a business on the Verified Premium plan (5,000 XAF a month) from the store
panel in the admin area. The tick lasts one year and stops when the plan stops. A business not on the plan cannot be
given the tick. Sellers can still apply for verification; that path is unchanged.

## Defaults chosen (confirm before enabling)

| Setting | Default |
|---|---|
| Commission rate range | 3% to 10% (suggested 5%) |
| Commission basis | Verified subscription payments (first and renewals) |
| Hold before withdrawal | 7 days |
| Minimum payout | 5,000 XAF |
| Attribution | 30 days from business creation; then 12 months |
| Blue tick validity | 365 days; ends with the plan |

The programme is **off** until an administrator turns it on.

## Deploying

Run `supabase/setup/19_upgrade_creator_terms_badge.sql` in the Supabase SQL Editor after 18. It changes rules only:
no payment, commission entry or payout is edited. Approved creators with a rate below 3% are moved up to 3%.
Then open the Creators page in the admin area to review the settings and switch the programme on.

Not built or not connected: an automatic payout API, and automatic creator approval.
