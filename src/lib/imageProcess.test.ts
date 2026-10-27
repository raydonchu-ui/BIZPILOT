import { describe, expect, it } from 'vitest';
import { checkImageFile, cropRect, DEFAULT_CROP, MAX_UPLOAD_BYTES } from './imageProcess';

describe('cropRect', () => {
  it('takes the largest square from a wide picture, centred by default', () => {
    const r = cropRect(1200, 800, 1, 1, DEFAULT_CROP);
    expect(r.sw).toBe(800);
    expect(r.sh).toBe(800);
    expect(r.sx).toBe(200);
    expect(r.sy).toBe(0);
  });

  it('keeps the frame shape for a tall picture and a wide cover frame', () => {
    const r = cropRect(900, 1600, 8, 3, DEFAULT_CROP);
    expect(r.sw / r.sh).toBeCloseTo(8 / 3, 5);
    expect(r.sw).toBe(900);
    expect(r.sx).toBe(0);
    expect(r.sy).toBeCloseTo((1600 - 900 * 3 / 8) / 2, 5);
  });

  it('zooms in around the centre and stays inside the picture', () => {
    const r = cropRect(1000, 1000, 1, 1, { zoom: 2, offsetX: 0, offsetY: 0 });
    expect(r.sw).toBe(500);
    expect(r.sx).toBe(250);
    for (const offsetX of [-5, -1, 0, 1, 5]) {
      const e = cropRect(1000, 1000, 1, 1, { zoom: 2, offsetX, offsetY: offsetX });
      expect(e.sx).toBeGreaterThanOrEqual(0);
      expect(e.sx + e.sw).toBeLessThanOrEqual(1000 + 1e-9);
      expect(e.sy + e.sh).toBeLessThanOrEqual(1000 + 1e-9);
    }
  });

  it('moves to the edges at the offset limits', () => {
    expect(cropRect(1000, 1000, 1, 1, { zoom: 2, offsetX: -1, offsetY: 0 }).sx).toBe(0);
    expect(cropRect(1000, 1000, 1, 1, { zoom: 2, offsetX: 1, offsetY: 0 }).sx).toBe(500);
  });

  it('caps the zoom so a tiny crop is never produced', () => {
    expect(cropRect(1000, 1000, 1, 1, { zoom: 100, offsetX: 0, offsetY: 0 }).sw).toBe(250);
  });
});

describe('checkImageFile', () => {
  it('accepts PNG, JPEG and WebP up to 5 MB', () => {
    expect(() => checkImageFile({ type: 'image/png', size: 1000 })).not.toThrow();
    expect(() => checkImageFile({ type: 'image/jpeg', size: MAX_UPLOAD_BYTES })).not.toThrow();
    expect(() => checkImageFile({ type: 'image/webp', size: 10 })).not.toThrow();
  });

  it('refuses other types and oversized files', () => {
    expect(() => checkImageFile({ type: 'image/svg+xml', size: 10 })).toThrow('file_type_not_allowed');
    expect(() => checkImageFile({ type: 'application/pdf', size: 10 })).toThrow('file_type_not_allowed');
    expect(() => checkImageFile({ type: 'image/png', size: MAX_UPLOAD_BYTES + 1 })).toThrow('file_too_large');
  });
});
