// Profile photos: an account writes only inside its own picture folder, a profile can only point at a picture in
// that folder, and the record of stored pictures belongs to its owner.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { admin, anon, closeDb, createUser, sql, type TestUser } from './helpers';

const picture = () => new Blob([new Uint8Array([82, 73, 70, 70, 1, 2, 3])], { type: 'image/webp' });

describe('profile photos and picture storage', () => {
  let ada: TestUser; let grace: TestUser; const names: string[] = [];

  beforeAll(async () => {
    ada = await createUser('img-ada');
    grace = await createUser('img-grace');
  });
  afterAll(async () => {
    // Storage objects are removed through the Storage API, never by deleting rows directly.
    if (names.length) await admin.storage.from('storefront').remove(names);
    await closeDb();
  });

  it('a profile may point at a picture in its own folder', async () => {
    const path = `users/${ada.id}/avatar-own.webp`;
    const { data, error } = await ada.client.from('profiles').update({ avatar_path: path }).eq('id', ada.id).select('avatar_path');
    expect(error).toBeNull();
    expect(data?.[0]?.avatar_path).toBe(path);
  });

  it('a profile cannot point at a picture in someone else’s folder', async () => {
    const { error } = await ada.client.from('profiles').update({ avatar_path: `users/${grace.id}/stolen.webp` }).eq('id', ada.id).select('id');
    expect(error).not.toBeNull();
    const [{ avatar_path }] = await sql<{ avatar_path: string }>('select avatar_path from profiles where id = $1', [ada.id]);
    expect(avatar_path).toBe(`users/${ada.id}/avatar-own.webp`);
  });

  it('an account uploads only into its own folder', async () => {
    const own = `users/${ada.id}/own-upload.webp`;
    names.push(own);
    const ok = await ada.client.storage.from('storefront').upload(own, picture(), { contentType: 'image/webp', upsert: false });
    expect(ok.error).toBeNull();
    const elsewhere = await ada.client.storage.from('storefront').upload(`users/${grace.id}/intruder.webp`, picture(), { contentType: 'image/webp', upsert: false });
    expect(elsewhere.error).not.toBeNull();
    const [{ n }] = await sql<{ n: number }>('select count(*)::int n from storage.objects where name = $1', [`users/${grace.id}/intruder.webp`]);
    expect(n).toBe(0);
  });

  it('anonymous visitors cannot upload pictures', async () => {
    const res = await anon().storage.from('storefront').upload(`users/${ada.id}/anon.webp`, picture(), { contentType: 'image/webp', upsert: false });
    expect(res.error).not.toBeNull();
  });

  it('another account cannot delete a picture it does not own', async () => {
    const path = `users/${ada.id}/own-upload.webp`;
    await grace.client.storage.from('storefront').remove([path]);
    const [{ n }] = await sql<{ n: number }>('select count(*)::int n from storage.objects where name = $1', [path]);
    expect(n).toBe(1);
  });

  it('the owner can remove their own picture', async () => {
    const path = `users/${ada.id}/to-remove.webp`;
    await ada.client.storage.from('storefront').upload(path, picture(), { contentType: 'image/webp', upsert: false });
    const res = await ada.client.storage.from('storefront').remove([path]);
    expect(res.error).toBeNull();
    const [{ n }] = await sql<{ n: number }>('select count(*)::int n from storage.objects where name = $1', [path]);
    expect(n).toBe(0);
  });

  it('the record of stored pictures belongs to its owner', async () => {
    const path = `users/${ada.id}/recorded-${Date.now()}.webp`;
    const mine = await ada.client.from('stored_images').insert({ owner_id: ada.id, bucket: 'storefront', path, kind: 'avatar', bytes: 2048 });
    expect(mine.error).toBeNull();
    const forged = await ada.client.from('stored_images').insert({ owner_id: grace.id, bucket: 'storefront', path: `users/${grace.id}/x.webp`, kind: 'avatar', bytes: 10 });
    expect(forged.error).not.toBeNull();
    const seenByGrace = await grace.client.from('stored_images').select('id').eq('path', path);
    expect(seenByGrace.data ?? []).toEqual([]);
    const seenByAda = await ada.client.from('stored_images').select('id').eq('path', path);
    expect(seenByAda.data?.length).toBe(1);
    await sql('delete from stored_images where path = $1', [path]);
  });

  it('the same picture cannot be recorded twice', async () => {
    const path = `users/${ada.id}/once-${Date.now()}.webp`;
    await ada.client.from('stored_images').insert({ owner_id: ada.id, bucket: 'storefront', path, kind: 'avatar', bytes: 100 });
    const again = await ada.client.from('stored_images').insert({ owner_id: ada.id, bucket: 'storefront', path, kind: 'avatar', bytes: 100 });
    expect(again.error).not.toBeNull();
    await sql('delete from stored_images where path = $1', [path]);
  });
});
