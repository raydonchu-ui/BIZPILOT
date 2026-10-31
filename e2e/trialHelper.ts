import { sql } from '../tests/db/helpers';

// New accounts start on the Free plan. Browser tests that exercise paid features give the owner's business a
// 30-day Business trial, as the database tests do.
export async function startBusinessTrial(email: string) {
  await sql(`update business_subscriptions set plan_code = 'business', status = 'trialing', trial_ends_at = now() + interval '30 days'
    where business_id in (select m.business_id from business_members m join auth.users u on u.id = m.user_id where u.email = $1)`, [email]);
}
