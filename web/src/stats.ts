/** Displayed frames and their capture-to-display latency over one STATS window. */
export class FrameCounter {
  private presented = 0;
  private latencyTotal = 0;
  private latencyCount = 0;

  add(latencyMs: number | undefined): void {
    this.presented++;
    // Ignore samples taken before the clock offset settled.
    if (latencyMs !== undefined && latencyMs > -50 && latencyMs < 10_000) {
      this.latencyTotal += Math.max(0, latencyMs);
      this.latencyCount++;
    }
  }

  take(seconds: number): { fps: number; latencyMs?: number } {
    const result: { fps: number; latencyMs?: number } = { fps: seconds > 0 ? this.presented / seconds : 0 };
    if (this.latencyCount) result.latencyMs = this.latencyTotal / this.latencyCount;
    this.presented = 0;
    this.latencyTotal = 0;
    this.latencyCount = 0;
    return result;
  }
}
