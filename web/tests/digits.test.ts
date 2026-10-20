import { describe, expect, it } from 'vitest';
import { asciiDigits } from '../src/ui/digits';

describe('asciiDigits', () => {
  it('keeps ASCII digits and drops everything else', () => {
    expect(asciiDigits('48-29 13')).toBe('482913');
  });

  it('converts full-width and Arabic-Indic digits', () => {
    expect(asciiDigits('４８２９１３')).toBe('482913');
    expect(asciiDigits('٤٨٢٩١٣')).toBe('482913');
    expect(asciiDigits('۴۸۲۹۱۳')).toBe('482913');
  });
});
