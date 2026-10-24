import { type Page } from '@playwright/test';

export const TEST_PIN = '2580';
const SETUP = /Create your Store Lock PIN|Créez votre PIN de verrouillage/;
const LOCKED = /Store locked|Boutique verrouillée/;
const pinInput = (page: Page) => page.locator('input[type="password"][inputmode="numeric"][maxlength="4"]').first();

// After signing in: create the Store Lock PIN on first access to the dashboard, or unlock a new
// session (a new sign-in starts locked once a PIN exists). Does nothing if neither screen shows.
export async function passStoreLock(page: Page, pin = TEST_PIN) {
  await page.waitForFunction(({ s, l }) => new RegExp(s).test(document.body.innerText) || new RegExp(l).test(document.body.innerText)
    || !!document.querySelector('nav[aria-label="App"], nav[aria-label="Bottom"]'), { s: SETUP.source, l: LOCKED.source }, { timeout: 20000 });
  const text = await page.locator('body').innerText();
  if (SETUP.test(text)) {
    await pinInput(page).fill(pin);
    await page.getByText(/^(Confirm PIN|Confirmer le PIN)$/).first().waitFor();
    await pinInput(page).fill(pin);
  } else if (LOCKED.test(text)) {
    await pinInput(page).fill(pin);
  } else {
    return;
  }
  await page.waitForFunction(({ s, l }) => !new RegExp(s).test(document.body.innerText) && !new RegExp(l).test(document.body.innerText),
    { s: SETUP.source, l: LOCKED.source }, { timeout: 20000 });
}
