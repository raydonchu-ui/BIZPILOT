import { expect, test, type Page } from '@playwright/test';
import { closeDb, createBusiness, createUser, sql } from '../tests/db/helpers';

// Store Lock PIN through the real UI and server: setup, lock, refresh/direct URL, wrong PINs,
// waits, inactivity, change, forgotten PIN, sign-out/sign-in.
const PASSWORD = 'Test-password-123!'; // createUser's password
test.describe.configure({ mode: 'serial' });
test.afterAll(closeDb);

const pinBox = (page: Page) => page.locator('input[type="password"][inputmode="numeric"][maxlength="4"]').first();
const lockedHeading = (page: Page) => page.getByRole('heading', { name: 'Store locked' });
let email = '';

async function signIn(page: Page) {
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'en'));
  await page.goto('/login');
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(PASSWORD);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page).toHaveURL(/\/app/);
}

test.beforeAll(async () => {
  const u = await createUser('pin-e2e');
  await createBusiness(u, 'PIN Test Shop');
  email = u.email;
});

test('the PIN is optional: the dashboard opens without one; a PIN can be set from the profile; weak or mismatched PINs are refused', async ({ page }) => {
  await signIn(page);
  await expect(page.getByRole('navigation', { name: 'App' })).toBeVisible(); // no PIN is required on first access
  await page.goto('/app/profile');
  await page.getByRole('button', { name: 'Set a PIN (optional)' }).click();
  await expect(page.getByRole('heading', { name: 'Create your Store Lock PIN' })).toBeVisible();
  await pinBox(page).fill('1234');
  await expect(page.getByText(/less obvious PIN/)).toBeVisible();
  await pinBox(page).fill('2580');
  await pinBox(page).fill('2581');
  await expect(page.getByText('The two PINs do not match.')).toBeVisible();
  await pinBox(page).fill('2580');
  await pinBox(page).fill('2580');
  await expect(page.getByRole('navigation', { name: 'App' })).toBeVisible();
  const [row] = await sql(`select p.pin_hash from app.store_pins p join auth.users u on u.id = p.user_id where u.email = $1`, [email]);
  expect(row.pin_hash).toMatch(/^\$2[aby]\$/);
  // The PIN is not kept in browser storage.
  const stored = await page.evaluate(() => JSON.stringify({ ...localStorage, ...sessionStorage }));
  expect(stored).not.toContain('2580');
});

test('Lock store locks at once; refresh and direct URLs stay locked; wrong PINs are counted', async ({ page }) => {
  await signIn(page);
  await expect(lockedHeading(page)).toBeVisible(); // a new sign-in starts locked
  await pinBox(page).fill('2580');
  await expect(page.getByRole('navigation', { name: 'App' })).toBeVisible();

  await page.getByRole('button', { name: 'Lock store' }).first().click();
  await expect(lockedHeading(page)).toBeVisible();
  await expect(page.getByText('PIN Test Shop')).toHaveCount(0); // no business data behind the lock
  await page.reload();
  await expect(lockedHeading(page)).toBeVisible();
  await page.goto('/app/products');
  await expect(lockedHeading(page)).toBeVisible();
  await page.goto('/app/reports');
  await expect(lockedHeading(page)).toBeVisible();

  await pinBox(page).fill('9999');
  await expect(page.getByText(/Wrong PIN\. 4 attempt/)).toBeVisible();
  await pinBox(page).fill('2580');
  await expect(page).toHaveURL(/\/app\/reports/);
  await expect(page.getByRole('heading', { name: 'Reports' })).toBeVisible();
});

test('too many wrong PINs cause a wait, even for the right PIN', async ({ page }) => {
  await signIn(page);
  for (const p of ['1111', '2222', '3333', '4444']) {
    await pinBox(page).fill(p);
    await expect(page.getByText(/Wrong PIN/)).toBeVisible();
  }
  await pinBox(page).fill('5555');
  await expect(page.getByText(/Too many wrong PINs\. Try again in \d+ s/)).toBeVisible();
  await expect(pinBox(page)).toBeDisabled();
  await sql(`update app.store_pins set locked_until = now() - interval '1 second' where user_id = (select id from auth.users where email = $1)`, [email]);
  await page.reload();
  await pinBox(page).fill('2580');
  await expect(page.getByRole('navigation', { name: 'App' })).toBeVisible();
});

test('locks automatically after the chosen inactivity period', async ({ page }) => {
  await page.clock.install();
  await signIn(page);
  await pinBox(page).fill('2580');
  await page.goto('/app/profile');
  await page.getByLabel('Lock automatically after').selectOption('1');
  await expect(page.getByText('Saved').first()).toBeVisible();
  await page.clock.fastForward('00:30');
  await expect(page.getByRole('heading', { name: 'Store Lock' })).toBeVisible(); // still open after 30 s
  await page.clock.fastForward('01:10');
  await expect(lockedHeading(page)).toBeVisible();
  await pinBox(page).fill('2580');
  await page.goto('/app/profile');
  await page.getByLabel('Lock automatically after').selectOption('15');
});

test('change PIN (needs the current one), then forgotten PIN via a fresh sign-in', async ({ page }) => {
  await signIn(page);
  await pinBox(page).fill('2580');
  await page.goto('/app/profile');
  await page.getByLabel('Current PIN').fill('1357');
  await page.getByLabel('New PIN').fill('1470');
  await page.getByRole('button', { name: 'Change PIN' }).click();
  await expect(page.getByText('Wrong PIN.')).toBeVisible();
  await page.getByLabel('Current PIN').fill('2580');
  await page.getByLabel('New PIN').fill('1470');
  await page.getByRole('button', { name: 'Change PIN' }).click();
  await expect(page.getByText(/PIN changed/)).toBeVisible();

  await page.getByRole('button', { name: 'Lock store' }).first().click();
  await pinBox(page).fill('2580');
  await expect(page.getByText(/Wrong PIN/)).toBeVisible();

  // Forgot PIN, long after signing in: the app asks to sign in again first.
  await page.route('**/rest/v1/rpc/store_lock_status', async (route) => {
    const res = await route.fetch(); const body = await res.json();
    await route.fulfill({ response: res, json: { ...body, can_reset: false } }); // as if the last sign-in were old
  });
  await page.reload();
  await page.getByRole('button', { name: 'Forgot PIN?' }).click();
  await expect(page.getByText(/sign in again with your account/)).toBeVisible();
  await page.unroute('**/rest/v1/rpc/store_lock_status');
  await page.getByRole('button', { name: 'Sign in again' }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(PASSWORD);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(page.getByRole('heading', { name: 'Choose a new PIN' })).toBeVisible(); // straight to a new PIN after signing in
  await pinBox(page).fill('3698');
  await pinBox(page).fill('3698');
  await expect(lockedHeading(page)).toBeVisible();
  await expect(page.getByText(/New PIN saved/)).toBeVisible();
  await pinBox(page).fill('1470');
  await expect(page.getByText(/Wrong PIN/)).toBeVisible();
  await pinBox(page).fill('3698');
  await expect(page.getByRole('navigation', { name: 'App' })).toBeVisible();

  // Right after a sign-in, "Forgot PIN?" goes directly to choosing a new one.
  await page.getByRole('button', { name: 'Lock store' }).first().click();
  await page.getByRole('button', { name: 'Forgot PIN?' }).click();
  await expect(page.getByRole('heading', { name: 'Choose a new PIN' })).toBeVisible();
});

test('logging out and in again asks for the PIN; "Sign out" works from the lock screen', async ({ page }) => {
  await signIn(page);
  await pinBox(page).fill('3698');
  await page.locator('button[aria-haspopup="menu"]').click();
  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.getByLabel(/^Email address/).fill(email);
  await page.getByLabel(/^Password/).fill(PASSWORD);
  await page.getByRole('button', { name: 'Log in' }).click();
  await expect(lockedHeading(page)).toBeVisible();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.goto('/app');
  await expect(page).toHaveURL(/\/login/);
});
