import { t } from '../i18n';
import { type Bytes, encodeKey, encodeText, KeyAction } from '../protocol';
import { hidUsage, modifierBits } from './hid';

const USAGE_RETURN = 0x28;
const USAGE_BACKSPACE = 0x2a;
const USAGE_DELETE_FORWARD = 0x4c;
const USAGE_LEFT_GUI = 0xe3;
const USAGE_RIGHT_GUI = 0xe7;

export interface KeyTarget {
  enabled(): boolean;
  send(bytes: Bytes): void;
}

function isEditable(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLInputElement ||
    target instanceof HTMLTextAreaElement ||
    (target instanceof HTMLElement && target.isContentEditable)
  );
}

/**
 * Hardware keyboards are forwarded as HID usages (physical positions; the Mac's input source
 * picks the character). Soft keyboards type into a hidden field whose committed text is sent
 * as TEXT, with Backspace / Return as KEY events.
 */
export class KeyboardInput {
  readonly softInput: HTMLTextAreaElement;
  private readonly pressed = new Map<string, number>();
  private composing = false;

  constructor(
    private readonly target: KeyTarget,
    container: HTMLElement,
  ) {
    const input = document.createElement('textarea');
    input.className = 'soft-keyboard';
    input.setAttribute('autocapitalize', 'off');
    input.setAttribute('autocomplete', 'off');
    input.setAttribute('autocorrect', 'off');
    input.setAttribute('spellcheck', 'false');
    input.setAttribute('enterkeyhint', 'enter');
    input.setAttribute('aria-label', t('keyboard.inputLabel'));
    input.addEventListener('beforeinput', this.onBeforeInput);
    input.addEventListener('input', this.onInput);
    input.addEventListener('compositionstart', () => (this.composing = true));
    input.addEventListener('compositionend', this.onCompositionEnd);
    container.append(input);
    this.softInput = input;

    window.addEventListener('keydown', this.onKeyDown, true);
    window.addEventListener('keyup', this.onKeyUp, true);
    window.addEventListener('blur', () => this.releaseAll());
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.releaseAll();
    });
  }

  get softKeyboardOpen(): boolean {
    return document.activeElement === this.softInput;
  }

  /** Must run inside a user gesture, or mobile browsers won't show the keyboard. */
  toggleSoftKeyboard(): boolean {
    if (this.softKeyboardOpen) {
      this.softInput.blur();
      return false;
    }
    this.softInput.value = '';
    this.softInput.focus({ preventScroll: true });
    return true;
  }

  /** Sends key-up for everything still held (focus loss, disconnect). */
  releaseAll(): void {
    if (this.target.enabled()) {
      for (const usage of this.pressed.values()) {
        this.target.send(encodeKey(KeyAction.up, usage, 0));
      }
    }
    this.pressed.clear();
  }

  private readonly onKeyDown = (event: KeyboardEvent) => {
    if (!this.target.enabled()) return;
    if (isEditable(event.target) && event.target !== this.softInput) return;
    if (event.isComposing || event.keyCode === 229) return;
    const usage = hidUsage(event.code);
    if (usage === undefined) return;
    // Printable keys in the soft-keyboard field arrive as text through `beforeinput`.
    if (event.target === this.softInput && !this.isCommandKey(event)) return;
    event.preventDefault();
    this.pressed.set(event.code, usage);
    this.target.send(encodeKey(KeyAction.down, usage, modifierBits(event)));
  };

  private readonly onKeyUp = (event: KeyboardEvent) => {
    const usage = this.pressed.get(event.code);
    if (usage === undefined || !this.target.enabled()) return;
    event.preventDefault();
    this.pressed.delete(event.code);
    if (usage === USAGE_LEFT_GUI || usage === USAGE_RIGHT_GUI) {
      // macOS browsers swallow key-ups of other keys while Command is held.
      for (const [code, other] of this.pressed) {
        this.target.send(encodeKey(KeyAction.up, other, modifierBits(event)));
        this.pressed.delete(code);
      }
    }
    this.target.send(encodeKey(KeyAction.up, usage, modifierBits(event)));
  };

  private isCommandKey(event: KeyboardEvent): boolean {
    if (event.ctrlKey || event.metaKey) return true;
    return event.key.length > 1 && event.key !== 'Unidentified' && event.key !== 'Process' && event.key !== 'Dead';
  }

  private tapKey(usage: number): void {
    this.target.send(encodeKey(KeyAction.down, usage, 0));
    this.target.send(encodeKey(KeyAction.up, usage, 0));
  }

  private sendText(text: string): void {
    if (text) this.target.send(encodeText(text));
  }

  private readonly onBeforeInput = (event: InputEvent) => {
    if (!this.target.enabled()) return;
    switch (event.inputType) {
      case 'insertText':
        if (!event.isComposing && event.data) {
          event.preventDefault();
          this.sendText(event.data);
        }
        break;
      case 'insertLineBreak':
      case 'insertParagraph':
        event.preventDefault();
        this.tapKey(USAGE_RETURN);
        break;
      case 'deleteContentBackward':
        if (!this.composing) {
          event.preventDefault();
          this.tapKey(USAGE_BACKSPACE);
        }
        break;
      case 'deleteContentForward':
        if (!this.composing) {
          event.preventDefault();
          this.tapKey(USAGE_DELETE_FORWARD);
        }
        break;
      default:
        // Composition (IMEs, predictive keyboards) finishes in `compositionend`.
        break;
    }
  };

  /** Fallback for browsers where `beforeinput` could not be cancelled. */
  private readonly onInput = (event: Event) => {
    if (this.composing || (event as InputEvent).isComposing) return;
    const value = this.softInput.value;
    if (value && this.target.enabled()) this.sendText(value);
    this.softInput.value = '';
  };

  private readonly onCompositionEnd = (event: CompositionEvent) => {
    this.composing = false;
    if (this.target.enabled()) this.sendText(event.data);
    // Clearing synchronously confuses some IMEs that are still finishing the composition.
    setTimeout(() => {
      if (!this.composing) this.softInput.value = '';
    }, 0);
  };
}
