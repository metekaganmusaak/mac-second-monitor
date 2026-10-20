import { describe, expect, it } from 'vitest';
import { ClockSync } from '../src/connection';

describe('ClockSync', () => {
  it('computes RTT and the host clock offset (PROTOCOL.md)', () => {
    const clock = new ClockSync();
    // Client sends at 1000 µs; host (clock 10 s ahead) answers at its 10_001_500; reply arrives at 3000.
    clock.pong(1000, 10_001_500, 3000);
    expect(clock.rttMicros).toBe(2000);
    expect(clock.offsetMicros).toBe(10_001_500 - (1000 + 1000));
    // A frame captured at host time 10_002_000, displayed at client time 4000 → 1.5 ms.
    expect(clock.latencyMs(10_002_000, 4000)).toBeCloseTo(1.5, 5);
  });

  it('keeps the offset of the lowest-RTT sample', () => {
    const clock = new ClockSync();
    clock.pong(0, 5_000_500, 1000); // rtt 1000, offset 5_000_000
    clock.pong(2000, 5_010_000, 12_000); // rtt 10_000 (queued) → offset ignored
    expect(clock.rttMicros).toBe(10_000);
    expect(clock.offsetMicros).toBe(5_000_000);
  });

  it('has no latency before the first PONG', () => {
    expect(new ClockSync().latencyMs(1, 2)).toBeUndefined();
  });
});
