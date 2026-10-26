import { describe, expect, it } from 'vitest';
import { CAMEROON_CITIES, cityKey } from './cities';

describe('Cameroon cities', () => {
  it('matches a city whatever accents, case or punctuation the seller used', () => {
    expect(cityKey('Yaoundé')).toBe(cityKey('yaounde'));
    expect(cityKey('YAOUNDÉ')).toBe('yaounde');
    expect(cityKey('Garoua-Boulaï')).toBe(cityKey('garoua boulai'));
    expect(cityKey('Douala ')).toBe('douala');
  });
  it('lists each town once, with its proper spelling', () => {
    expect(new Set(CAMEROON_CITIES).size).toBe(CAMEROON_CITIES.length);
    expect(CAMEROON_CITIES).toContain('Yaoundé');
    expect(CAMEROON_CITIES).toContain('Douala');
  });
});
