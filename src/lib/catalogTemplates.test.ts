import { describe, expect, it } from 'vitest';
import { barcodeProblem, BUSINESS_TYPES, CATEGORY_TEMPLATES, categoryTemplate } from './catalogTemplates';
import { combine, optionKey } from '../components/VariantGenerator';
import { pinProblem } from './storeLock';

describe('category templates', () => {
  it('has suggestions for every business type in both languages', () => {
    for (const type of BUSINESS_TYPES) {
      for (const lang of ['en', 'fr'] as const) {
        const tpl = categoryTemplate(type, lang);
        expect(tpl.length).toBeGreaterThan(0);
        expect(new Set(tpl.map((c) => c.name.toLowerCase())).size).toBe(tpl.length); // no duplicate top-level names
        for (const c of tpl) {
          expect(c.name.length).toBeLessThanOrEqual(80);
          expect(new Set(c.children.map((x) => x.toLowerCase())).size).toBe(c.children.length);
          expect(c.children.every((x) => x.length > 0 && x.length <= 80 && !x.includes('|'))).toBe(true);
        }
      }
    }
  });
  it('covers the clothing, electronics and hair & beauty items asked for', () => {
    const names = (type: string) => categoryTemplate(type, 'en').flatMap((c) => [c.name, ...c.children]);
    for (const n of ['Men', 'Women', 'Kids', 'Baby', 'Unisex', 'Sportswear', 'Traditional clothing', 'Workwear', 'Accessories', 'T-shirts', 'Polo shirts',
      'Long-sleeve shirts', 'Short-sleeve shirts', 'Trousers', 'Jeans', 'Shorts', 'Cargo pants', 'Joggers', 'Hoodies', 'Sweatshirts', 'Jackets', 'Coats',
      'Dresses', 'Skirts', 'Shoes', 'Sneakers', 'Boots', 'Sandals', 'Watches', 'Bags', 'Belts', 'Jewelry', 'Caps & hats']) expect(names('fashion')).toContain(n);
    for (const n of ['Phones', 'Computers', 'Laptops', 'Tablets', 'Televisions', 'Accessories', 'Chargers', 'Cables', 'Power banks', 'Cameras', 'Audio', 'Gaming',
      'Networking', 'Spare parts']) expect(names('electronics')).toContain(n);
    for (const n of ['Wigs', 'Human hair', 'Hair extensions', 'Bundles', 'Closures', 'Frontals', 'Braiding hair', 'Shampoos', 'Conditioners', 'Hair oils',
      'Styling tools', 'Clippers', 'Makeup', 'Skincare', 'Perfumes', 'Nails', 'Salon supplies']) expect(names('hair_beauty')).toContain(n);
  });
  it('falls back to general merchandise for an unknown type', () => {
    expect(categoryTemplate('unknown', 'en').map((c) => c.name)).toEqual(CATEGORY_TEMPLATES.general.map((c) => c.en));
  });
});

describe('barcode check digit', () => {
  it('accepts valid EAN-13, EAN-8, UPC-A and non-numeric codes', () => {
    for (const ok of ['4006381333931', '96385074', '036000291452', '6151100000019', 'ABC-123', '12345']) expect(barcodeProblem(ok)).toBeNull();
  });
  it('flags a mistyped GTIN', () => {
    expect(barcodeProblem('4006381333932')).toBe('check_digit');
    expect(barcodeProblem('036000291453')).toBe('check_digit');
  });
});

describe('variant combinations', () => {
  const labels = { size: 'Size', color: 'Colour' };
  it('builds every combination with attribute keys', () => {
    const rows = combine([{ name: 'Size', values: 'S, M, M ,L' }, { name: 'Couleur', values: 'Black,White' }], labels);
    expect(rows.map((r) => r.label)).toEqual(['S / Black', 'S / White', 'M / Black', 'M / White', 'L / Black', 'L / White']);
    expect(rows[3].attributes).toEqual({ size: 'M', color: 'White' });
  });
  it('maps option names to attribute keys and ignores empty options', () => {
    expect(optionKey('Taille', labels)).toBe('size');
    expect(optionKey('Length', labels)).toBe('length');
    expect(optionKey('Pack type', labels)).toBe('pack_type');
    expect(combine([{ name: 'Size', values: ' , ' }], labels)).toEqual([]);
    expect(combine([{ name: 'A', values: Array.from({ length: 20 }, (_, i) => i).join(',') }, { name: 'B', values: Array.from({ length: 20 }, (_, i) => i).join(',') }], labels)).toHaveLength(100);
  });
});

describe('PIN rules (same as the server)', () => {
  it('requires 4 digits and refuses obvious PINs', () => {
    for (const bad of ['1234', '0000', '7777', '4321', '0123', '123', '12345', '12a4', '']) expect(pinProblem(bad)).not.toBeNull();
    for (const ok of ['2580', '1357', '9024', '1470']) expect(pinProblem(ok)).toBeNull();
  });
});
