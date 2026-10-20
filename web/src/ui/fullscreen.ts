// Fullscreen with the WebKit-prefixed API (iPadOS Safari) as a fallback.

interface WebKitDocument {
  webkitFullscreenElement?: Element | null;
  webkitExitFullscreen?: () => void;
  webkitFullscreenEnabled?: boolean;
}

interface WebKitElement {
  webkitRequestFullscreen?: () => void;
}

interface KeyboardLock {
  lock?: (codes?: string[]) => Promise<void>;
  unlock?: () => void;
}

export function fullscreenSupported(): boolean {
  const doc = document as Document & WebKitDocument;
  return !!(doc.fullscreenEnabled || doc.webkitFullscreenEnabled);
}

export function isFullscreen(): boolean {
  const doc = document as Document & WebKitDocument;
  return !!(doc.fullscreenElement ?? doc.webkitFullscreenElement);
}

/** Must be called from a user gesture. */
export async function toggleFullscreen(element: HTMLElement = document.documentElement): Promise<void> {
  const doc = document as Document & WebKitDocument;
  const keyboard = (navigator as Navigator & { keyboard?: KeyboardLock }).keyboard;
  try {
    if (isFullscreen()) {
      keyboard?.unlock?.();
      if (doc.exitFullscreen) await doc.exitFullscreen();
      else doc.webkitExitFullscreen?.();
      return;
    }
    const target = element as HTMLElement & WebKitElement;
    if (target.requestFullscreen) await target.requestFullscreen({ navigationUI: 'hide' });
    else target.webkitRequestFullscreen?.();
    // Lets Escape and system shortcuts reach the Mac (Chromium only; holding Esc still exits).
    await keyboard?.lock?.().catch(() => undefined);
  } catch (error) {
    console.warn('Fullscreen request failed', error);
  }
}

export function onFullscreenChange(callback: () => void): void {
  document.addEventListener('fullscreenchange', callback);
  document.addEventListener('webkitfullscreenchange', callback);
}
