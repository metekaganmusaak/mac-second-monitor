import en from './i18n/en.json';
import tr from './i18n/tr.json';
import { storage } from './storage';

export type Catalog = Record<string, string>;
export type Params = Record<string, string | number>;

const catalogs: Record<string, Catalog> = { en, tr };
const fallback: Catalog = en;
const OVERRIDE_KEY = 'msm.lang';

export const supportedLanguages = Object.keys(catalogs);

let language = 'en';
let catalog: Catalog = fallback;
let pluralRules = new Intl.PluralRules('en');

/** Picks a supported language: `?lang=` (remembered), then the stored override, then the browser. */
export function resolveLanguage(query: string | null, stored: string | null, preferred: readonly string[]): string {
  for (const candidate of [query, stored, ...preferred]) {
    const base = candidate?.toLowerCase().split('-')[0];
    if (base && base in catalogs) return base;
  }
  return 'en';
}

export function initI18n(params: URLSearchParams = new URLSearchParams(location.search)): string {
  const query = params.get('lang');
  if (query === 'auto') {
    storage.remove(OVERRIDE_KEY);
  } else if (query && query.toLowerCase().split('-')[0]! in catalogs) {
    storage.set(OVERRIDE_KEY, query.toLowerCase().split('-')[0]!);
  }
  const preferred = navigator.languages?.length ? navigator.languages : [navigator.language];
  setLanguage(resolveLanguage(query === 'auto' ? null : query, storage.get(OVERRIDE_KEY), preferred));
  return language;
}

export function setLanguage(lang: string): void {
  language = lang in catalogs ? lang : 'en';
  catalog = catalogs[language] ?? fallback;
  pluralRules = new Intl.PluralRules(language);
  if (typeof document !== 'undefined') document.documentElement.lang = language;
}

export function currentLanguage(): string {
  return language;
}

export function format(template: string, params?: Params): string {
  if (!params) return template;
  return template.replace(/\{(\w+)\}/g, (match, name: string) => {
    const value = params[name];
    return value === undefined ? match : String(value);
  });
}

export function t(key: string, params?: Params): string {
  return format(catalog[key] ?? fallback[key] ?? key, params);
}

/** Plural-aware lookup: `key.one`, `key.few`, … chosen by Intl.PluralRules, falling back to `key.other`. */
export function plural(key: string, count: number, params?: Params): string {
  const category = pluralRules.select(count);
  const template = catalog[`${key}.${category}`] ?? catalog[`${key}.other`] ?? fallback[`${key}.other`] ?? key;
  return format(template, { count: formatNumber(count), ...params });
}

export function formatNumber(value: number, fractionDigits = 0): string {
  return new Intl.NumberFormat(language, {
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits,
  }).format(value);
}
