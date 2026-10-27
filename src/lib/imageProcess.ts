// Image pipeline for profile photos, store logos and covers. A picture is checked (type, size, that it really
// decodes), cropped to the frame the user chose, resized to a fixed size and re-encoded. Re-encoding drops the
// original metadata (EXIF, GPS), and content-hash file names mean the same picture is stored only once.

export const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/webp'] as const;
export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;

export type Frame = { width: number; height: number; thumb: { width: number; height: number } };

/** Fixed frames: each one is a real output size, with a smaller copy for lists and messages. */
export const FRAMES = {
  avatar: { width: 512, height: 512, thumb: { width: 128, height: 128 } },
  logo: { width: 512, height: 512, thumb: { width: 128, height: 128 } },
  cover: { width: 1600, height: 600, thumb: { width: 800, height: 300 } },
} satisfies Record<string, Frame>;

export type FrameName = keyof typeof FRAMES;

export interface CropState {
  /** 1 shows the whole picture as far as the frame allows; larger zooms in. */
  zoom: number;
  /** -1 (left or top edge) … 1 (right or bottom edge). */
  offsetX: number;
  offsetY: number;
}

export const DEFAULT_CROP: CropState = { zoom: 1, offsetX: 0, offsetY: 0 };

/**
 * Which part of the source picture goes into the frame. The largest area with the frame's shape is taken
 * first, then zoomed into and moved within the picture.
 */
export function cropRect(srcW: number, srcH: number, frameW: number, frameH: number, crop: CropState) {
  const aspect = frameW / frameH;
  let baseW = srcW;
  let baseH = srcW / aspect;
  if (baseH > srcH) {
    baseH = srcH;
    baseW = srcH * aspect;
  }
  const zoom = Math.min(Math.max(crop.zoom, 1), 4);
  const w = baseW / zoom;
  const h = baseH / zoom;
  const roomX = srcW - w;
  const roomY = srcH - h;
  const ox = Math.min(Math.max(crop.offsetX, -1), 1);
  const oy = Math.min(Math.max(crop.offsetY, -1), 1);
  return {
    sx: roomX / 2 * (1 + ox),
    sy: roomY / 2 * (1 + oy),
    sw: w,
    sh: h,
  };
}

/** Checks a file before anything is decoded: type and size. Throws a short error code for the UI. */
export function checkImageFile(file: { type: string; size: number }) {
  if (!(IMAGE_TYPES as readonly string[]).includes(file.type)) throw new Error('file_type_not_allowed');
  if (file.size > MAX_UPLOAD_BYTES) throw new Error('file_too_large');
}

/** Decodes the picture. A file that only claims to be an image fails here. */
export async function decodeImage(file: Blob): Promise<ImageBitmap> {
  try {
    const bitmap = await createImageBitmap(file);
    if (!bitmap.width || !bitmap.height) throw new Error('image_invalid');
    return bitmap;
  } catch {
    throw new Error('image_invalid');
  }
}

/** Draws the chosen part of the picture into a canvas of the frame's size. Used for the live preview and the saved file. */
export function drawFrame(canvas: HTMLCanvasElement, bitmap: ImageBitmap, frame: { width: number; height: number }, crop: CropState) {
  canvas.width = frame.width;
  canvas.height = frame.height;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('image_invalid');
  ctx.imageSmoothingQuality = 'high';
  const r = cropRect(bitmap.width, bitmap.height, frame.width, frame.height, crop);
  ctx.drawImage(bitmap, r.sx, r.sy, r.sw, r.sh, 0, 0, frame.width, frame.height);
}

/** Draws the chosen part of the picture into the frame and encodes it (WebP, or JPEG where WebP is not available). */
export async function renderFrame(bitmap: ImageBitmap, frame: { width: number; height: number }, crop: CropState): Promise<Blob> {
  const canvas = document.createElement('canvas');
  drawFrame(canvas, bitmap, frame, crop);
  const webp = await toBlob(canvas, 'image/webp', 0.86);
  if (webp && webp.type === 'image/webp') return webp;
  const jpeg = await toBlob(canvas, 'image/jpeg', 0.9);
  if (!jpeg) throw new Error('image_invalid');
  return jpeg;
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => canvas.toBlob((b) => resolve(b), type, quality));
}

/** SHA-256 of the encoded bytes, used as the file name so an identical picture is stored once. */
export async function contentHash(blob: Blob): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer());
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

/** The thumbnail sits next to the main picture: 512.webp -> 512-thumb.webp, so one stored path finds both. */
export function thumbPath(path: string) {
  return path.replace(/\.(webp|jpg)$/, '-thumb.$1');
}

export function extensionFor(blob: Blob) {
  return blob.type === 'image/jpeg' ? 'jpg' : 'webp';
}
