import { describe, expect, it } from 'vitest';
import { urlBase64ToUint8Array } from './push';

describe('urlBase64ToUint8Array', () => {
  it('decodes url-safe base64 without padding into the exact bytes', () => {
    // 0xfb 0xff 0xbf encodes to "-_-_" in base64url; the key form the browser expects.
    expect(Array.from(urlBase64ToUint8Array('-_-_'))).toEqual([0xfb, 0xff, 0xbf]);
  });

  it('handles every padding length', () => {
    expect(Array.from(urlBase64ToUint8Array('AQ'))).toEqual([1]);
    expect(Array.from(urlBase64ToUint8Array('AQI'))).toEqual([1, 2]);
    expect(Array.from(urlBase64ToUint8Array('AQID'))).toEqual([1, 2, 3]);
  });
});
