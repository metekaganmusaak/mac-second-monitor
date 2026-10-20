import { describe, expect, it } from 'vitest';
import { describeUserAgent, displaySize, sizeChangedSubstantially, snapRefreshRate } from '../src/device';

describe('describeUserAgent', () => {
  it.each([
    ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36', 0, 'Chrome', 'Windows'],
    ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0', 0, 'Edge', 'Windows'],
    ['Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0', 0, 'Firefox', 'Linux'],
    ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15', 0, 'Safari', 'macOS'],
    // iPadOS reports a Mac user agent; touch support gives it away.
    ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15', 5, 'Safari', 'iPad'],
    ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/141.0 Mobile/15E148 Safari/604.1', 5, 'Chrome', 'iPhone'],
    ['Mozilla/5.0 (Linux; Android 12; HarmonyOS; BAH4-W09) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0 HuaweiBrowser/14.0 Safari/537.36', 10, 'Huawei Browser', 'HarmonyOS'],
    ['Mozilla/5.0 (Linux; Android 14; SM-X710) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/26.0 Chrome/122.0 Safari/537.36', 10, 'Samsung Internet', 'Android'],
    ['Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36', 0, 'Chrome', 'ChromeOS'],
  ])('%s', (ua, touchPoints, browser, os) => {
    expect(describeUserAgent(ua, touchPoints)).toEqual({ browser, os });
  });

  it('leaves unknown parts out', () => {
    expect(describeUserAgent('curl/8.0')).toEqual({});
  });
});

describe('displaySize', () => {
  it('uses device pixels rounded to even numbers', () => {
    expect(displaySize(1280, 713, 2)).toEqual({ width: 2560, height: 1426 });
    expect(displaySize(1366, 683, 1)).toEqual({ width: 1366, height: 684 });
    expect(displaySize(390.5, 844, 3)).toEqual({ width: 1172, height: 2532 });
  });

  it('caps the long side at 8192 keeping the aspect ratio', () => {
    expect(displaySize(5120, 2880, 2)).toEqual({ width: 8192, height: 4608 });
  });

  it('raises tiny windows to the 320 px minimum', () => {
    expect(displaySize(300, 200, 1)).toEqual({ width: 480, height: 320 });
  });
});

describe('sizeChangedSubstantially', () => {
  it('ignores small changes and reacts to large ones', () => {
    const base = { width: 2560, height: 1600 };
    expect(sizeChangedSubstantially(base, { width: 2560, height: 1560 })).toBe(false);
    expect(sizeChangedSubstantially(base, { width: 2560, height: 1400 })).toBe(true);
    expect(sizeChangedSubstantially(base, { width: 1600, height: 2560 })).toBe(true);
  });
});

describe('snapRefreshRate', () => {
  it('snaps to common panel rates', () => {
    expect(snapRefreshRate(59.7)).toBe(60);
    expect(snapRefreshRate(119.2)).toBe(120);
    expect(snapRefreshRate(143)).toBe(144);
    expect(snapRefreshRate(85)).toBe(85);
  });
});
