import { describe, expect, it } from 'vitest';
import { clamp01, fitRect, normalize } from '../src/input/geometry';

describe('fitRect', () => {
  it('letterboxes a wider picture top and bottom', () => {
    expect(fitRect(1280, 714, 1000, 714)).toEqual({ left: 0, top: 78, width: 1000, height: 1000 * (714 / 1280) });
  });

  it('pillarboxes a taller picture left and right', () => {
    const rect = fitRect(1000, 1000, 1600, 800);
    expect(rect).toEqual({ left: 400, top: 0, width: 800, height: 800 });
  });

  it('shows a picture that matches the box in device pixels 1:1', () => {
    // 2560 × 1426 stream in a 1280 × 713.5 CSS px box at 2× (rounding to even pixels).
    // The 0.25 px margin snaps to a whole device pixel (0.5 CSS px).
    expect(fitRect(2560, 1426, 1280, 713.5, 2)).toEqual({ left: 0, top: 0.5, width: 1280, height: 713 });
  });
});

describe('normalize', () => {
  const rect = { left: 0, top: 78, width: 1000, height: 557.8125 };

  it('maps client coordinates into the picture', () => {
    expect(normalize(rect, 500, 78 + 557.8125 / 2)).toEqual({ x: 0.5, y: 0.5 });
    expect(normalize(rect, 0, 78)).toEqual({ x: 0, y: 0 });
  });

  it('extends outside the picture; clamping is separate', () => {
    const point = normalize(rect, 500, 10);
    expect(point.y).toBeLessThan(0);
    expect(clamp01(point.y)).toBe(0);
    expect(clamp01(1.2)).toBe(1);
  });
});
