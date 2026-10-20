/**
 * Keyboards in some languages type other digits: full-width (４８２), Arabic-Indic (٤٨٢) or
 * Extended Arabic-Indic (۴۸۲). The Mac expects 0–9.
 */
export function asciiDigits(text: string): string {
  return text
    .normalize('NFKC')
    .replace(/[٠-٩]/g, (digit) => String(digit.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (digit) => String(digit.charCodeAt(0) - 0x06f0))
    .replace(/\D/g, '');
}
