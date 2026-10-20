// KeyboardEvent.code (physical key position) → USB HID Keyboard/Keypad page (0x07) usage.

import { Modifier } from '../protocol';

const table: Record<string, number> = {
  Enter: 0x28,
  Escape: 0x29,
  Backspace: 0x2a,
  Tab: 0x2b,
  Space: 0x2c,
  Minus: 0x2d,
  Equal: 0x2e,
  BracketLeft: 0x2f,
  BracketRight: 0x30,
  Backslash: 0x31,
  Semicolon: 0x33,
  Quote: 0x34,
  Backquote: 0x35,
  Comma: 0x36,
  Period: 0x37,
  Slash: 0x38,
  CapsLock: 0x39,
  PrintScreen: 0x46,
  ScrollLock: 0x47,
  Pause: 0x48,
  Insert: 0x49,
  Home: 0x4a,
  PageUp: 0x4b,
  Delete: 0x4c,
  End: 0x4d,
  PageDown: 0x4e,
  ArrowRight: 0x4f,
  ArrowLeft: 0x50,
  ArrowDown: 0x51,
  ArrowUp: 0x52,
  // Mac keyboards report the keypad Clear key as NumLock.
  NumLock: 0x53,
  NumpadDivide: 0x54,
  NumpadMultiply: 0x55,
  NumpadSubtract: 0x56,
  NumpadAdd: 0x57,
  NumpadEnter: 0x58,
  Numpad1: 0x59,
  Numpad2: 0x5a,
  Numpad3: 0x5b,
  Numpad4: 0x5c,
  Numpad5: 0x5d,
  Numpad6: 0x5e,
  Numpad7: 0x5f,
  Numpad8: 0x60,
  Numpad9: 0x61,
  Numpad0: 0x62,
  NumpadDecimal: 0x63,
  IntlBackslash: 0x64,
  ContextMenu: 0x65,
  Power: 0x66,
  NumpadEqual: 0x67,
  Help: 0x75,
  AudioVolumeMute: 0x7f,
  AudioVolumeUp: 0x80,
  AudioVolumeDown: 0x81,
  VolumeMute: 0x7f,
  VolumeUp: 0x80,
  VolumeDown: 0x81,
  NumpadComma: 0x85,
  IntlRo: 0x87,
  KanaMode: 0x88,
  IntlYen: 0x89,
  Convert: 0x8a,
  NonConvert: 0x8b,
  Lang1: 0x90,
  Lang2: 0x91,
  ControlLeft: 0xe0,
  ShiftLeft: 0xe1,
  AltLeft: 0xe2,
  MetaLeft: 0xe3,
  ControlRight: 0xe4,
  ShiftRight: 0xe5,
  AltRight: 0xe6,
  MetaRight: 0xe7,
  // Older Firefox names for the Windows / Command keys.
  OSLeft: 0xe3,
  OSRight: 0xe7,
};

for (let i = 0; i < 26; i++) {
  table[`Key${String.fromCharCode(65 + i)}`] = 0x04 + i;
}
for (let i = 1; i <= 9; i++) {
  table[`Digit${i}`] = 0x1e + i - 1;
}
table.Digit0 = 0x27;
for (let i = 1; i <= 12; i++) {
  table[`F${i}`] = 0x3a + i - 1;
}
for (let i = 13; i <= 24; i++) {
  table[`F${i}`] = 0x68 + i - 13;
}

export function hidUsage(code: string): number | undefined {
  return table[code];
}

export function isModifierUsage(usage: number): boolean {
  return usage >= 0xe0 && usage <= 0xe7;
}

export interface ModifierState {
  shiftKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  getModifierState?(key: string): boolean;
}

/** Protocol modifier bits as they are after the event. */
export function modifierBits(event: ModifierState): number {
  let bits = 0;
  if (event.shiftKey) bits |= Modifier.shift;
  if (event.ctrlKey) bits |= Modifier.control;
  if (event.altKey) bits |= Modifier.option;
  if (event.metaKey) bits |= Modifier.command;
  if (event.getModifierState?.('CapsLock')) bits |= Modifier.capsLock;
  if (event.getModifierState?.('Fn')) bits |= Modifier.function;
  return bits;
}
