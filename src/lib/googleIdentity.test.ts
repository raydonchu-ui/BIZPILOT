import { describe, expect, it } from 'vitest';
import { maskClientId, parseGoogleClientId } from './googleIdentity';

describe('Google client ID check', () => {
  it('accepts a web client ID (trimmed, quotes removed)', () => {
    expect(parseGoogleClientId(' "123456789012-abcdef123.apps.googleusercontent.com" ')).toEqual({ status: 'ok', clientId: '123456789012-abcdef123.apps.googleusercontent.com' });
  });
  it('reports a missing value', () => {
    expect(parseGoogleClientId(undefined)).toEqual({ status: 'missing' });
    expect(parseGoogleClientId('  ')).toEqual({ status: 'missing' });
  });
  it('rejects a client secret pasted by mistake', () => {
    expect(parseGoogleClientId('GOCSPX-abcdefghijklmnop')).toEqual({ status: 'invalid', reason: 'looks_like_secret' });
  });
  it('rejects other values', () => {
    expect(parseGoogleClientId('my-client-id')).toEqual({ status: 'invalid', reason: 'bad_format' });
    expect(parseGoogleClientId('https://cvruxxkgfbsatqvpysey.supabase.co')).toEqual({ status: 'invalid', reason: 'bad_format' });
  });
  it('masks the ID for display', () => {
    const m = maskClientId('123456789012-abcdef123.apps.googleusercontent.com');
    expect(m).toBe('1234…9012-abcd….apps.googleusercontent.com');
    expect(m).not.toContain('5678');
  });
});
