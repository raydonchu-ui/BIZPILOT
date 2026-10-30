import { expect, test } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { passStoreLock } from './storeLockHelper';

// Mobile layout: registration, bottom navigation, quick actions, fast sale entry,
// and the offline queue that never reports unsynced sales as saved.
test('mobile: bottom nav, quick actions and offline-safe sale entry', async ({ page, context }) => {
  const email = `mobile-${randomUUID().slice(0, 6)}@e2e.bizpilot.local`;
  await page.addInitScript(() => localStorage.setItem('bizpilot.lang', 'fr'));
  await page.goto('/signup');
  await page.getByLabel(/^Votre nom complet/).fill('Awa Ngono');
  await page.getByLabel(/^Adresse e-mail/).fill(email);
  await page.getByLabel(/^Mot de passe/).fill('Mobile-pass-123!');
  await page.getByLabel(/^Confirmer le mot de passe/).fill('Mobile-pass-123!');
  await page.getByRole('checkbox').check();
  await page.getByRole('button', { name: 'Créer mon compte' }).click();
  await page.getByLabel(/^Nom du commerce/).fill('Dépôt Awa');
  await page.getByRole('button', { name: 'Créer mon commerce' }).click();
  await passStoreLock(page);
  await expect(page.getByRole('heading', { name: 'Bien démarrer' })).toBeVisible();

  // Add a product with opening stock
  await page.goto('/app/products/new');
  await page.getByLabel(/^Nom/).first().fill('Eau Tangui 1,5L');
  await page.getByLabel(/^Prix de vente/).first().fill('400');
  await page.getByLabel('Quantité en stock (piece)').fill('30');
  await page.getByLabel('Coût par piece').fill('250');
  await page.getByRole('button', { name: 'Enregistrer' }).first().click();
  await expect(page.getByRole('heading', { name: /Eau Tangui/ })).toBeVisible();

  // Bottom navigation and the central quick-action button
  await page.goto('/app');
  const bottom = page.getByRole('navigation', { name: 'Bottom' });
  await expect(bottom).toBeVisible();
  await bottom.getByRole('button', { name: 'Actions rapides' }).click();
  await page.getByRole('link', { name: 'Nouvelle vente' }).last().click();
  await expect(page.getByRole('heading', { name: 'Nouvelle vente' })).toBeVisible();

  // Go offline, record a sale: it must be queued, not reported as saved
  await page.getByPlaceholder('Rechercher ou scanner un produit…').fill('Eau');
  await page.getByRole('button', { name: /Eau Tangui/ }).click();
  await context.setOffline(true);
  await page.getByRole('button', { name: /Valider la vente/ }).click();
  await expect(page.getByRole('heading', { name: 'Enregistrée sur cet appareil' })).toBeVisible();
  await expect(page.getByText(/1 vente\(s\) enregistrée\(s\) sur cet appareil/)).toBeVisible();

  // Back online: the queue syncs and the sale appears once the server confirmed it
  await context.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.goto('/app/sales');
  await expect(page.getByRole('row', { name: /S-00001/ })).toContainText('400 FCFA');
  await expect(page.getByRole('row', { name: /S-00001/ })).toContainText('Hors ligne');
  await page.goto('/app/products');
  // Stock went from 30 to 29: the quantity cell starts with the number. A plain '29' also matched the sidebar's trial date.
  await expect(page.getByText(/^29\b/).first()).toBeVisible();
});
