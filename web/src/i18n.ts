import ar from './i18n/ar.json';
import de from './i18n/de.json';
import en from './i18n/en.json';
import es from './i18n/es.json';
import fr from './i18n/fr.json';
import it from './i18n/it.json';
import ja from './i18n/ja.json';
import ko from './i18n/ko.json';
import ptBR from './i18n/pt-BR.json';
import ru from './i18n/ru.json';
import tr from './i18n/tr.json';
import zhCN from './i18n/zh-CN.json';
import { storage } from './storage';

export type Catalog = Record<string, string>;
export type Params = Record<string, string | number>;

/**
 * Keyed by BCP 47 tag, one catalog per base language: other regions of that language use it
 * (de-AT → de, pt-PT → pt-BR, zh-TW → zh-CN).
 */
const catalogs: Record<string, Catalog> = { en, tr, de, es, fr, it, 'pt-BR': ptBR, ru, 'zh-CN': zhCN, ja, ko, ar };
const fallback: Catalog = en;
const OVERRIDE_KEY = 'msm.lang';
const rightToLeft = new Set(['ar']);

export const supportedLanguages = Object.keys(catalogs);

const baseOf = (tag: string) => tag.toLowerCase().split('-')[0]!;
const byTag = new Map(supportedLanguages.map((tag) => [tag.toLowerCase(), tag]));
const byBase = new Map(supportedLanguages.map((tag) => [baseOf(tag), tag]));

let language = 'en';
let catalog: Catalog = fallback;
let pluralRules = new Intl.PluralRules('en');

/** The supported language for a language tag (`de-AT`, `pt_PT`, `zh-Hant-TW`): exact tag first, then the base language. */
export function matchLanguage(tag: string | null | undefined): string | undefined {
  const normalized = tag?.trim().toLowerCase().replace(/_/g, '-');
  if (!normalized) return undefined;
  return byTag.get(normalized) ?? byBase.get(baseOf(normalized));
}

/** Picks a supported language: `?lang=` (remembered), then the stored override, then the browser. */
export function resolveLanguage(query: string | null, stored: string | null, preferred: readonly string[]): string {
  for (const candidate of [query, stored, ...preferred]) {
    const match = matchLanguage(candidate);
    if (match) return match;
  }
  return 'en';
}

export function initI18n(params: URLSearchParams = new URLSearchParams(location.search)): string {
  const query = params.get('lang');
  if (query === 'auto') {
    storage.remove(OVERRIDE_KEY);
  } else {
    const match = matchLanguage(query);
    if (match) storage.set(OVERRIDE_KEY, match);
  }
  const preferred = navigator.languages?.length ? navigator.languages : [navigator.language];
  setLanguage(resolveLanguage(query === 'auto' ? null : query, storage.get(OVERRIDE_KEY), preferred));
  return language;
}

export function setLanguage(lang: string): void {
  language = matchLanguage(lang) ?? 'en';
  catalog = catalogs[language] ?? fallback;
  pluralRules = new Intl.PluralRules(language);
  if (typeof document !== 'undefined') {
    // Mirrors the UI chrome for right-to-left languages; the video stage opts out in CSS.
    document.documentElement.lang = language;
    document.documentElement.dir = textDirection(language);
  }
}

export function currentLanguage(): string {
  return language;
}

export function textDirection(lang: string = language): 'ltr' | 'rtl' {
  return rightToLeft.has(baseOf(lang)) ? 'rtl' : 'ltr';
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
