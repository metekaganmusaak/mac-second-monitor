import { describe, expect, it, vi } from 'vitest';
import en from '../src/i18n/en.json';
import {
  currentLanguage,
  format,
  matchLanguage,
  plural,
  resolveLanguage,
  setLanguage,
  supportedLanguages,
  t,
  textDirection,
} from '../src/i18n';

type Catalog = Record<string, string>;

const files = import.meta.glob<Catalog>('../src/i18n/*.json', { eager: true, import: 'default' });
const catalogs: Record<string, Catalog> = Object.fromEntries(
  Object.entries(files).map(([path, catalog]) => [path.replace(/^.*\/|\.json$/g, ''), catalog]),
);
const languages = Object.keys(catalogs).sort();

const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]!).sort();

// `key.one`, `key.few`, … are plural forms of `key` when English has `key.other`.
const pluralBase = (key: string) => {
  const base = key.match(/^(.+)\.(zero|one|two|few|many|other)$/)?.[1];
  return base && `${base}.other` in en ? base : undefined;
};
const plainKeys = (catalog: Catalog) => Object.keys(catalog).filter((key) => !pluralBase(key)).sort();
const pluralForms = (catalog: Catalog, base: string) =>
  Object.keys(catalog)
    .filter((key) => pluralBase(key) === base)
    .map((key) => key.slice(base.length + 1))
    .sort();
const pluralBases = [...new Set(Object.keys(en).map(pluralBase).filter((base) => base !== undefined))];

/** A plural form that only ever stands for one number ("one" in English, "two" in Arabic) may spell it out instead of using {count}. */
const singleNumber = (lang: string, category: string) => {
  const rules = new Intl.PluralRules(lang);
  let matches = 0;
  for (let n = 0; n <= 1000; n++) if (rules.select(n) === category) matches++;
  return matches === 1;
};

// Product, protocol and browser names that stay as they are in every language.
const untranslated = ['Mac Second Monitor', 'Mac', 'USB', 'Wi-Fi', 'WebCodecs', 'HTTPS', 'localhost', 'Chrome', 'Edge', 'Safari', 'Firefox'];

describe('catalogs', () => {
  it('are all registered', () => {
    expect([...supportedLanguages].sort()).toEqual(languages);
    expect(languages).toEqual(['ar', 'de', 'en', 'es', 'fr', 'it', 'ja', 'ko', 'pt-BR', 'ru', 'tr', 'zh-CN']);
  });

  it('use dot-separated keys', () => {
    for (const key of Object.keys(en)) expect(key).toMatch(/^[a-z]+(\.[A-Za-z_]+)+$/);
  });

  describe.each(languages)('%s', (lang) => {
    const catalog = catalogs[lang]!;

    it('has the same keys as English', () => {
      expect(plainKeys(catalog)).toEqual(plainKeys(en));
      for (const base of pluralBases) expect(pluralForms(catalog, base).length, base).toBeGreaterThan(0);
    });

    it('has exactly the plural forms the language uses', () => {
      const categories = [...new Intl.PluralRules(lang).resolvedOptions().pluralCategories].sort();
      for (const base of pluralBases) expect(pluralForms(catalog, base), base).toEqual(categories);
    });

    it('uses the same placeholders', () => {
      for (const key of plainKeys(en)) expect(placeholders(catalog[key]!), key).toEqual(placeholders(en[key as keyof typeof en]));
      for (const base of pluralBases) {
        const expected = placeholders(en[`${base}.other` as keyof typeof en]);
        for (const category of pluralForms(catalog, base)) {
          const actual = placeholders(catalog[`${base}.${category}`]!);
          if (!actual.includes('count') && singleNumber(lang, category)) actual.push('count');
          expect(actual.sort(), `${base}.${category}`).toEqual(expected);
        }
      }
    });

    it('keeps names untranslated and has no empty strings', () => {
      for (const [key, text] of Object.entries(catalog)) {
        expect(text.trim(), key).not.toBe('');
        const source = en[(pluralBase(key) ? `${pluralBase(key)}.other` : key) as keyof typeof en];
        for (const name of untranslated) if (source.includes(name)) expect(text, `${key}: ${name}`).toContain(name);
      }
    });
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
    setLanguage('ru');
    expect(plural('pairing.attemptsLeft', 1)).toBe('Осталась 1 попытка.');
    expect(plural('pairing.attemptsLeft', 3)).toBe('Осталось 3 попытки.');
    expect(plural('pairing.attemptsLeft', 5)).toBe('Осталось 5 попыток.');
    expect(plural('pairing.attemptsLeft', 21)).toBe('Осталась 21 попытка.');
    setLanguage('ar');
    expect(plural('pairing.attemptsLeft', 2)).toBe('تبقّت لديك محاولتان.');
    expect(plural('pairing.attemptsLeft', 3)).toBe('تبقّت لديك 3 محاولات.');
    expect(plural('pairing.attemptsLeft', 11)).toBe('تبقّت لديك 11 محاولة.');
    setLanguage('ja');
    expect(plural('pairing.attemptsLeft', 1)).toBe('残り1回です。');
    setLanguage('fr');
    expect(plural('pairing.attemptsLeft', 0)).toBe('Il reste 0 tentative.');
    setLanguage('en');
  });
});

describe('resolveLanguage', () => {
  it('prefers the query, then the stored override, then the browser', () => {
    expect(resolveLanguage('tr', 'en', ['en-US'])).toBe('tr');
    expect(resolveLanguage(null, 'tr', ['en-US'])).toBe('tr');
    expect(resolveLanguage(null, null, ['nl-NL', 'tr-TR'])).toBe('tr');
    expect(resolveLanguage(null, null, ['de-DE', 'tr-TR'])).toBe('de');
    expect(resolveLanguage(null, null, ['nl-NL'])).toBe('en');
    expect(resolveLanguage('xx', null, ['TR'])).toBe('tr');
    expect(resolveLanguage('pt-PT', 'ja', ['ko-KR'])).toBe('pt-BR');
  });

  it('falls back from regional variants to the catalog of the base language', () => {
    expect(matchLanguage('de-AT')).toBe('de');
    expect(matchLanguage('de-CH')).toBe('de');
    expect(matchLanguage('es-419')).toBe('es');
    expect(matchLanguage('fr-CA')).toBe('fr');
    expect(matchLanguage('pt')).toBe('pt-BR');
    expect(matchLanguage('pt-PT')).toBe('pt-BR');
    expect(matchLanguage('pt_br')).toBe('pt-BR');
    expect(matchLanguage('zh')).toBe('zh-CN');
    expect(matchLanguage('zh-TW')).toBe('zh-CN');
    expect(matchLanguage('zh-Hant-HK')).toBe('zh-CN');
    expect(matchLanguage('ja-JP')).toBe('ja');
    expect(matchLanguage('ko-KR')).toBe('ko');
    expect(matchLanguage('ar-EG')).toBe('ar');
    expect(matchLanguage('RU')).toBe('ru');
    expect(matchLanguage('nl')).toBeUndefined();
    expect(matchLanguage('')).toBeUndefined();
    expect(matchLanguage(null)).toBeUndefined();
  });
});

describe('setLanguage', () => {
  it('sets lang and dir on the document', () => {
    const root = { lang: '', dir: '' };
    vi.stubGlobal('document', { documentElement: root });
    try {
      setLanguage('ar');
      expect(root).toEqual({ lang: 'ar', dir: 'rtl' });
      setLanguage('zh-TW');
      expect(currentLanguage()).toBe('zh-CN');
      expect(root).toEqual({ lang: 'zh-CN', dir: 'ltr' });
      setLanguage('xx');
      expect(root).toEqual({ lang: 'en', dir: 'ltr' });
    } finally {
      vi.unstubAllGlobals();
      setLanguage('en');
    }
  });

  it('knows which languages are right-to-left', () => {
    expect(textDirection('ar')).toBe('rtl');
    expect(textDirection('ar-SA')).toBe('rtl');
    for (const lang of languages.filter((lang) => lang !== 'ar')) expect(textDirection(lang), lang).toBe('ltr');
  });
});
