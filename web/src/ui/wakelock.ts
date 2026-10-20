/** Keeps the screen on while streaming (Screen Wake Lock API; secure contexts only). */
export class ScreenWakeLock {
  private sentinel: WakeLockSentinel | null = null;
  private wanted = false;
  private requesting = false;

  constructor() {
    // The browser releases the lock whenever the page is hidden.
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.wanted) void this.request();
    });
  }

  acquire(): void {
    this.wanted = true;
    void this.request();
  }

  release(): void {
    this.wanted = false;
    void this.sentinel?.release().catch(() => undefined);
    this.sentinel = null;
  }

  private async request(): Promise<void> {
    if (!('wakeLock' in navigator) || this.sentinel || this.requesting || document.visibilityState !== 'visible') return;
    this.requesting = true;
    try {
      const sentinel = await navigator.wakeLock.request('screen');
      sentinel.addEventListener('release', () => {
        if (this.sentinel === sentinel) this.sentinel = null;
      });
      if (this.wanted) this.sentinel = sentinel;
      else void sentinel.release();
    } catch {
      // Denied (e.g. battery saver) — not fatal.
    } finally {
      this.requesting = false;
    }
  }
}
