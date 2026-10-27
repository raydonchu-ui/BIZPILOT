import { describe, expect, it } from 'vitest';
import { thumbPath } from './pictures';

describe('thumbPath', () => {
  it('names the thumbnail next to the main picture, keeping the extension', () => {
    expect(thumbPath('users/abc/hash.webp')).toBe('users/abc/hash-thumb.webp');
    expect(thumbPath('biz-1/store/hash.jpg')).toBe('biz-1/store/hash-thumb.jpg');
  });
});
