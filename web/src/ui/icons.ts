// Stroke icons, 24 × 24, drawn with `stroke: currentColor` in CSS.
export const icons = {
  enterFullscreen: ['M4 9V4h5', 'M20 9V4h-5', 'M4 15v5h5', 'M20 15v5h-5'],
  exitFullscreen: ['M9 4v5H4', 'M15 4v5h5', 'M9 20v-5H4', 'M15 20v-5h5'],
  keyboard: ['M3 7a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z', 'M7 9h.01M11 9h.01M15 9h.01M7 12h.01M11 12h.01M15 12h.01M8 15h8'],
  stats: ['M4 20V10', 'M10 20V4', 'M16 20v-7', 'M22 20H2'],
  disconnect: ['M12 3v8', 'M6.3 6.8a8 8 0 1 0 11.4 0'],
} as const;
