import { describe, expect, it } from 'vitest';
import en from '../src/i18n/en.json';
import tr from '../src/i18n/tr.json';
import { format, plural, resolveLanguage, setLanguage, t } from '../src/i18n';

const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe('catalogs', () => {
  it('have the same keys', () => {
    expect(Object.keys(tr).sort()).toEqual(Object.keys(en).sort());
  });

  it('use the same placeholders in every language', () => {
    for (const [key, text] of Object.entries(en)) {
      expect(placeholders((tr as Record<string, string>)[key]!), key).toEqual(placeholders(text));
    }
  });

  it('use dot-separated keys', () => {
    for (const key of Object.keys(en)) expect(key).toMatch(/^[a-z]+(\.[A-Za-z_]+)+$/);
  });
});

describe('lookup', () => {
  it('formats parameters and falls back to the key', () => {
    setLanguage('en');
    expect(t('status.connecting', { host: '192.168.1.5:7101' })).toBe('Connecting to 192.168.1.5:7101…');
    expect(t('no.such.key')).toBe('no.such.key');
    expect(format('{a} and {b}', { a: 1 })).toBe('1 and {b}');
  });

  it('chooses plural forms', () => {
    setLanguage('en');
    expect(plural('pairing.attemptsLeft', 1)).toBe('1 attempt left.');
    expect(plural('pairing.attemptsLeft', 2)).toBe('2 attempts left.');
    setLanguage('tr');
    expect(plural('pairing.attemptsLeft', 2)).toBe('2 deneme hakkınız kaldı.');
    expect(t('pairing.title')).toBe("Mac'inizle eşleştirin");
    setLanguage('en');
  });
});

describe('resolveLanguage', () => {
  it('prefers the query, then the stored override, then the browser', () => {
    expect(resolveLanguage('tr', 'en', ['en-US'])).toBe('tr');
    expect(resolveLanguage(null, 'tr', ['en-US'])).toBe('tr');
    expect(resolveLanguage(null, null, ['de-DE', 'tr-TR'])).toBe('tr');
    expect(resolveLanguage(null, null, ['de-DE'])).toBe('en');
    expect(resolveLanguage('xx', null, ['TR'])).toBe('tr');
  });
});
