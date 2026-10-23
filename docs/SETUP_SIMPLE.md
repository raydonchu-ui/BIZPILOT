# BizPilot setup: the simple way (no command line)

You only need a web browser. Do the steps in this order. Menu names in the Supabase and Vercel dashboards sometimes change slightly; look for the closest match.

**Never paste these anywhere except where a step tells you to:** the Supabase database password, the Supabase `service_role` / secret key, your Anthropic API key. None of them go in Vercel, and none of them go in a chat.

---

## Step 1: Create the database (Supabase, about 2 minutes)

1. Open your project at supabase.com → **SQL Editor** → **New query**.
2. Open the file `supabase/setup/01_bizpilot_setup.sql` from the GitHub repo, copy **all** of it, and paste it in.
3. Click **Run**. It should finish with "Success. No rows returned".
   - Run it only **once**, on an empty project. It runs as one block: if anything fails, nothing is saved, and you can fix the problem and run it again.

## Step 2: Copy two values from Supabase

Go to **Project Settings → API Keys** (or click **Connect** at the top of the dashboard). Copy:

| Name in Supabase | Looks like |
|---|---|
| **Project URL** | `https://cvruxxkgfbsatqvpysey.supabase.co` |
| **Publishable key** (or the legacy **anon public** key) | `sb_publishable_…` or `eyJhbGci…` |

Both are public: they're meant to be in the website. Your data is protected by the database rules, not by hiding these.

## Step 3: Put the site online (Vercel)

1. vercel.com → **Add New → Project** → import the BizPilot GitHub repository.
2. Framework: **Vite** (detected automatically). Build command `npm run build`, output folder `dist`.
3. Open **Environment Variables** and add:

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | the Project URL from step 2 |
   | `VITE_SUPABASE_ANON_KEY` | the publishable / anon key from step 2 |

4. Click **Deploy**. When it finishes, copy your site address (e.g. `https://bizpilot.vercel.app`, or your own domain later).

If you change an environment variable later, redeploy (Deployments → ⋯ → Redeploy) so the site picks it up.

## Step 4: Tell Supabase about your site

**Authentication → URL Configuration**
- **Site URL:** your Vercel address, e.g. `https://bizpilot.vercel.app`
- **Redirect URLs:** add `https://bizpilot.vercel.app/**`

**Authentication → Sign In / Providers → Email**
- **Confirm email:** ON
- **Minimum password length:** 8

**Authentication → Emails → Templates**: for each template below, paste the subject and the HTML from the repo:

| Template | Subject | HTML file |
|---|---|---|
| Confirm signup | `Confirm your BizPilot account / Confirmez votre compte BizPilot` | `supabase/templates/confirmation.html` |
| Reset password | `Reset your BizPilot password / Réinitialisez votre mot de passe BizPilot` | `supabase/templates/recovery.html` |
| Change email address | `Confirm your new email for BizPilot / Confirmez votre nouvelle adresse` | `supabase/templates/email_change.html` |
| Magic link | `Your BizPilot sign-in link / Votre lien de connexion BizPilot` | `supabase/templates/magic_link.html` |

The emails are in English and French together, and they show the BizPilot logo from your site, so do step 3 first.

**Authentication → Emails → SMTP Settings (strongly recommended):** Supabase's built-in email sender only sends a few emails per hour and is meant for testing. Create a free account with an email provider (Resend, Brevo, …), then enter its SMTP host, port, username and password here. Use a sender like `no-reply@yourdomain`.

## Step 5: Make yourself the administrator

1. On your new site, click **Start** and sign up with your own email. Confirm it from the email you receive, and create your shop.
2. In Supabase → **SQL Editor** → **New query**, paste this with **your** email, then Run:
   ```sql
   select app.bootstrap_platform_admin('your@email.com');
   ```
   (The same line is in `supabase/setup/02_make_me_admin.sql`.)
3. Refresh the site: an **Admin** link appears in your user menu.

## Step 6: Fill in your payment and contact details

In BizPilot → **Admin → Settings**:
- `payment_instructions`: put your MTN MoMo / Orange Money merchant numbers and names, and set `"enabled": true`.
- `support_contact`: your support email, phone and WhatsApp.

## Step 7 (optional): Turn on the AI Advisor

Without this, the Advisor still works with rule-based answers.

1. Get an API key at console.anthropic.com (and set a monthly spending limit there).
2. Supabase → **Edge Functions** → **Deploy a new function** → **Via editor**. Name it exactly `ai-advisor`, paste the contents of `supabase/functions/ai-advisor/index.ts`, and deploy.
3. Supabase → **Edge Functions → Secrets** → add `ANTHROPIC_API_KEY` = your key.

## Step 8 (optional): Daily alerts

Supabase → **Database → Extensions** → enable **pg_cron**. Then run `supabase/setup/03_optional_daily_alerts.sql` in the SQL Editor.

---

### Check that it works
- Sign up with a second email → you receive the branded confirmation email.
- Log out → **Forgot password?** → you receive the reset email, and the link lets you choose a new password.
- Add a product with stock, make a sale, and check the dashboard.

### If you later switch to the command line
Because step 1 set up the database by hand, tell the Supabase CLI those changes are already applied before using `supabase db push`:
```bash
npx supabase migration repair --status applied 20261022000100 20261022000150 20261022000200 20261022000300 20261022000400 20261022000500 20261022000600 20261022000700 20261022000800
```
