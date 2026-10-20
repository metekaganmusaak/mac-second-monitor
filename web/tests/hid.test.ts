import { describe, expect, it } from 'vitest';
import { hidUsage, isModifierUsage, modifierBits } from '../src/input/hid';
import { Modifier } from '../src/protocol';

describe('hidUsage', () => {
  it.each([
    ['KeyA', 0x04],
    ['KeyZ', 0x1d],
    ['Digit1', 0x1e],
    ['Digit9', 0x26],
    ['Digit0', 0x27],
    ['Enter', 0x28],
    ['Escape', 0x29],
    ['Backspace', 0x2a],
    ['Tab', 0x2b],
    ['Space', 0x2c],
    ['Minus', 0x2d],
    ['BracketLeft', 0x2f],
    ['Semicolon', 0x33],
    ['Quote', 0x34],
    ['Backquote', 0x35],
    ['Slash', 0x38],
    ['CapsLock', 0x39],
    ['F1', 0x3a],
    ['F12', 0x45],
    ['F13', 0x68],
    ['F24', 0x73],
    ['Insert', 0x49],
    ['Delete', 0x4c],
    ['PageDown', 0x4e],
    ['ArrowRight', 0x4f],
    ['ArrowLeft', 0x50],
    ['ArrowDown', 0x51],
    ['ArrowUp', 0x52],
    ['NumpadDivide', 0x54],
    ['NumpadEnter', 0x58],
    ['Numpad1', 0x59],
    ['Numpad0', 0x62],
    ['NumpadDecimal', 0x63],
    ['NumpadEqual', 0x67],
    ['IntlBackslash', 0x64],
    ['IntlRo', 0x87],
    ['IntlYen', 0x89],
    ['ControlLeft', 0xe0],
    ['ShiftLeft', 0xe1],
    ['AltLeft', 0xe2],
    ['MetaLeft', 0xe3],
    ['ControlRight', 0xe4],
    ['ShiftRight', 0xe5],
    ['AltRight', 0xe6],
    ['MetaRight', 0xe7],
  ])('%s → 0x%s', (code, usage) => {
    expect(hidUsage(code)).toBe(usage);
  });

  it('returns undefined for keys without a usage', () => {
    expect(hidUsage('Fn')).toBeUndefined();
    expect(hidUsage('Unidentified')).toBeUndefined();
  });

  it('recognizes modifier usages', () => {
    expect(isModifierUsage(0xe0)).toBe(true);
    expect(isModifierUsage(0xe7)).toBe(true);
    expect(isModifierUsage(0x04)).toBe(false);
  });
});

describe('modifierBits', () => {
  it('maps event flags to protocol bits', () => {
    const state = (keys: string[]) => ({
      shiftKey: keys.includes('shift'),
      ctrlKey: keys.includes('ctrl'),
      altKey: keys.includes('alt'),
      metaKey: keys.includes('meta'),
      getModifierState: (key: string) => keys.includes(key),
    });
    expect(modifierBits(state([]))).toBe(0);
    expect(modifierBits(state(['shift']))).toBe(Modifier.shift);
    expect(modifierBits(state(['ctrl', 'alt', 'meta']))).toBe(Modifier.control | Modifier.option | Modifier.command);
    expect(modifierBits(state(['CapsLock', 'Fn']))).toBe(Modifier.capsLock | Modifier.function);
  });
});
