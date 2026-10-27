// Stores a profile photo, store logo or store cover: renders the main picture and a thumbnail, uploads both to the
// storefront bucket under the owner's folder, and records them. Identical pictures reuse the same files.
import { supabase } from './supabase';
import { STOREFRONT_BUCKET } from './market';
import { contentHash, decodeImage, extensionFor, FRAMES, renderFrame, thumbPath, type CropState, type FrameName } from './imageProcess';

export { thumbPath };

export interface StoredPicture { path: string; thumb: string; bytes: number }

/**
 * Renders and uploads one picture. `folder` is the owner's folder in the storefront bucket:
 * `users/<account id>` for a profile photo, `<business id>/store` for a logo or cover.
 */
export async function storePicture(args: { folder: string; kind: FrameName; file: Blob; crop: CropState; ownerId: string }): Promise<StoredPicture> {
  const bitmap = await decodeImage(args.file);
  try {
    const frame = FRAMES[args.kind];
    const main = await renderFrame(bitmap, frame, args.crop);
    const small = await renderFrame(bitmap, frame.thumb, args.crop);
    const hash = await contentHash(main);
    const ext = extensionFor(main);
    const path = `${args.folder}/${hash}.${ext}`;
    const thumb = thumbPath(path);
    await uploadOnce(path, main);
    await uploadOnce(thumb, small);
    await record(args.ownerId, path, args.kind, main.size);
    await record(args.ownerId, thumb, 'thumb', small.size);
    return { path, thumb, bytes: main.size + small.size };
  } finally {
    bitmap.close?.();
  }
}

async function uploadOnce(path: string, blob: Blob) {
  const { error } = await supabase.storage.from(STOREFRONT_BUCKET).upload(path, blob, { contentType: blob.type, upsert: false });
  // The same picture was stored before: keep the existing file.
  if (error && !/already exists|duplicate|409/i.test(`${(error as { statusCode?: string }).statusCode ?? ''} ${error.message}`)) throw error;
}

async function record(ownerId: string, path: string, kind: string, bytes: number) {
  // A picture is recorded once; a second record for the same path is expected on reuse and is ignored.
  const { error } = await supabase.from('stored_images').insert({ owner_id: ownerId, bucket: STOREFRONT_BUCKET, path, kind, bytes });
  if (error && error.code !== '23505') throw error;
}
