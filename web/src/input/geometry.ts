export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface Point {
  x: number;
  y: number;
}

/**
 * Where a `contentWidth × contentHeight` picture goes inside a box (CSS px), aspect-fitted and
 * centred. When the picture already matches the box in device pixels it is shown 1:1, which
 * keeps text sharp instead of resampling by a fraction of a percent.
 */
export function fitRect(contentWidth: number, contentHeight: number, boxWidth: number, boxHeight: number, devicePixelRatio = 1): Rect {
  if (contentWidth <= 0 || contentHeight <= 0 || boxWidth <= 0 || boxHeight <= 0) {
    return { left: 0, top: 0, width: boxWidth, height: boxHeight };
  }
  let width: number;
  let height: number;
  if (Math.abs(contentWidth - boxWidth * devicePixelRatio) <= 2 && Math.abs(contentHeight - boxHeight * devicePixelRatio) <= 2) {
    width = contentWidth / devicePixelRatio;
    height = contentHeight / devicePixelRatio;
  } else {
    const scale = Math.min(boxWidth / contentWidth, boxHeight / contentHeight);
    width = contentWidth * scale;
    height = contentHeight * scale;
  }
  // Align the origin to a device pixel.
  const snap = (value: number) => Math.round(value * devicePixelRatio) / devicePixelRatio;
  return { left: snap((boxWidth - width) / 2), top: snap((boxHeight - height) / 2), width, height };
}

/** Client coordinates → video frame coordinates (0…1 inside the picture, not clamped). */
export function normalize(rect: Rect, clientX: number, clientY: number): Point {
  return {
    x: rect.width > 0 ? (clientX - rect.left) / rect.width : 0,
    y: rect.height > 0 ? (clientY - rect.top) / rect.height : 0,
  };
}

export function clamp01(value: number): number {
  return value < 0 ? 0 : value > 1 ? 1 : value;
}
