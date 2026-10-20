import { t } from './i18n';
import type { DisplayInfo } from './protocol';
import { storage } from './storage';

const DEVICE_ID_KEY = 'msm.deviceId';
const MAX_DIMENSION = 8192;
const MIN_DIMENSION = 320;

/** Stable random ID for this browser profile. */
export function deviceId(): string {
  let id = storage.get(DEVICE_ID_KEY);
  if (!id) {
    // crypto.randomUUID needs a secure context; getRandomValues does not.
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    id = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
    storage.set(DEVICE_ID_KEY, id);
  }
  return id;
}

export interface DeviceDescription {
  browser?: string;
  os?: string;
}

/** Browser and OS names (proper nouns, not translated) from a user agent string. */
export function describeUserAgent(ua: string, maxTouchPoints = 0): DeviceDescription {
  const browser =
    /Edg(e|A|iOS)?\//.test(ua) ? 'Edge'
    : /OPR\/|Opera/.test(ua) ? 'Opera'
    : /SamsungBrowser\//.test(ua) ? 'Samsung Internet'
    : /HuaweiBrowser\//.test(ua) ? 'Huawei Browser'
    : /Firefox\/|FxiOS\//.test(ua) ? 'Firefox'
    : /Chrome\/|CriOS\/|Chromium\//.test(ua) ? 'Chrome'
    : /Safari\//.test(ua) && /Version\//.test(ua) ? 'Safari'
    : undefined;

  const os =
    /iPad/.test(ua) || (/Macintosh/.test(ua) && maxTouchPoints > 1) ? 'iPad'
    : /iPhone/.test(ua) ? 'iPhone'
    : /HarmonyOS|OpenHarmony/.test(ua) ? 'HarmonyOS'
    : /Android/.test(ua) ? 'Android'
    : /CrOS/.test(ua) ? 'ChromeOS'
    : /Windows/.test(ua) ? 'Windows'
    : /Macintosh|Mac OS X/.test(ua) ? 'macOS'
    : /Linux/.test(ua) ? 'Linux'
    : undefined;

  return { ...(browser ? { browser } : {}), ...(os ? { os } : {}) };
}

export function deviceName(): string {
  const { browser, os } = describeUserAgent(navigator.userAgent, navigator.maxTouchPoints);
  return t('device.name', {
    browser: browser ?? t('device.browser.unknown'),
    os: os ?? t('device.os.unknown'),
  });
}

export interface Size {
  width: number;
  height: number;
}

/**
 * Backing pixel size for the virtual display: the viewport in device pixels, even numbers,
 * within the host's accepted range (320…8192) while keeping the aspect ratio.
 */
export function displaySize(cssWidth: number, cssHeight: number, devicePixelRatio: number): Size {
  let width = Math.max(1, cssWidth * devicePixelRatio);
  let height = Math.max(1, cssHeight * devicePixelRatio);
  const down = Math.min(1, MAX_DIMENSION / Math.max(width, height));
  width *= down;
  height *= down;
  const up = Math.max(1, MIN_DIMENSION / Math.min(width, height));
  width = Math.min(MAX_DIMENSION, width * up);
  height = Math.min(MAX_DIMENSION, height * up);
  return { width: even(width), height: even(height) };
}

function even(value: number): number {
  return Math.max(2, Math.round(value / 2) * 2);
}

export function currentDisplaySize(): Size {
  return displaySize(window.innerWidth, window.innerHeight, window.devicePixelRatio || 1);
}

export function displayInfo(refreshRate: number): DisplayInfo {
  const size = currentDisplaySize();
  return {
    ...size,
    // CSS defines 96 px per inch; the physical density is unknown to web pages.
    dpi: Math.round(96 * (window.devicePixelRatio || 1)),
    refreshRate,
  };
}

/** True when the virtual display should be recreated for the new viewport size. */
export function sizeChangedSubstantially(previous: Size, next: Size, tolerance = 0.05): boolean {
  return (
    Math.abs(next.width - previous.width) / previous.width > tolerance ||
    Math.abs(next.height - previous.height) / previous.height > tolerance
  );
}

const commonRates = [30, 48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 240];

export function snapRefreshRate(hz: number): number {
  for (const rate of commonRates) {
    if (Math.abs(hz - rate) / rate < 0.05) return rate;
  }
  return Math.round(hz);
}

/** Measures the display refresh rate with requestAnimationFrame; 60 if it can't tell. */
export function estimateRefreshRate(timeoutMs = 600): Promise<number> {
  return new Promise((resolve) => {
    const stamps: number[] = [];
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      const intervals = stamps.slice(1).map((stamp, i) => stamp - stamps[i]!).sort((a, b) => a - b);
      const median = intervals[Math.floor(intervals.length / 2)];
      resolve(median && intervals.length >= 5 ? snapRefreshRate(1000 / median) : 60);
    };
    const tick = (time: number) => {
      stamps.push(time);
      if (stamps.length >= 20) finish();
      else if (!done) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
    setTimeout(finish, timeoutMs);
  });
}
