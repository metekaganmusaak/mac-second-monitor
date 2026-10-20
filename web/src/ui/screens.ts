import { plural, t } from '../i18n';
import type { PairRequest } from '../protocol';
import { h } from './dom';

export interface ScreenAction {
  label: string;
  primary?: boolean;
  run(): void;
}

export interface StatusOptions {
  title?: string;
  detail?: string;
  spinner?: boolean;
  actions?: ScreenAction[];
  /** Keep the last picture visible behind the card. */
  translucent?: boolean;
}

/** Centered card for connection status, errors and pairing. */
export class Screens {
  readonly root: HTMLElement;
  private readonly card: HTMLElement;
  private pairing: PairingForm | null = null;

  constructor(parent: HTMLElement) {
    this.card = h('div', { className: 'card', attrs: { role: 'status', 'aria-live': 'polite' } });
    this.root = h('div', { className: 'screen' }, this.card);
    parent.append(this.root);
  }

  get visible(): boolean {
    return !this.root.hidden;
  }

  status(message: string, options: StatusOptions = {}): void {
    this.pairing = null;
    const children: Node[] = [];
    if (options.spinner) children.push(h('div', { className: 'spinner', attrs: { 'aria-hidden': 'true' } }));
    if (options.title) children.push(h('h1', { text: options.title }));
    children.push(h('p', { className: 'message', text: message }));
    if (options.detail) children.push(h('p', { className: 'detail', text: options.detail }));
    if (options.actions?.length) {
      children.push(
        h(
          'div',
          { className: 'actions' },
          ...options.actions.map((action) =>
            h('button', {
              className: action.primary ? 'button primary' : 'button',
              text: action.label,
              attrs: { type: 'button' },
              on: { click: () => action.run() },
            }),
          ),
        ),
      );
    }
    this.show(children, options.translucent ?? false);
  }

  /** Changes the text of the current status card without rebuilding it (countdowns). */
  updateMessage(message: string): void {
    const element = this.card.querySelector('.message');
    if (element) element.textContent = message;
  }

  /** Shows the code entry, or updates it after a wrong code. */
  pair(request: PairRequest, submit: (code: string) => void): void {
    if (!this.pairing || !this.visible) {
      this.pairing = new PairingForm(submit);
      this.show([this.pairing.root], false);
    }
    this.pairing.update(request);
  }

  hide(): void {
    this.pairing = null;
    this.root.hidden = true;
  }

  private show(children: Node[], translucent: boolean): void {
    this.card.replaceChildren(...children);
    this.root.classList.toggle('translucent', translucent);
    this.root.hidden = false;
  }
}

class PairingForm {
  readonly root: HTMLFormElement;
  private readonly input: HTMLInputElement;
  private readonly button: HTMLButtonElement;
  private readonly message: HTMLElement;
  private readonly error: HTMLElement;
  private codeLength = 6;

  constructor(private readonly submit: (code: string) => void) {
    this.message = h('p', { className: 'message' });
    this.error = h('p', { className: 'error', attrs: { role: 'alert' } });
    this.input = h('input', {
      className: 'code',
      attrs: {
        type: 'text',
        inputmode: 'numeric',
        pattern: '[0-9]*',
        autocomplete: 'one-time-code',
        enterkeyhint: 'done',
        'aria-label': t('pairing.codeLabel'),
      },
    });
    this.button = h('button', { className: 'button primary', text: t('pairing.submit'), attrs: { type: 'submit' } });
    this.input.addEventListener('input', () => {
      const digits = this.input.value.replace(/\D/g, '').slice(0, this.codeLength);
      if (digits !== this.input.value) this.input.value = digits;
      this.button.disabled = digits.length !== this.codeLength;
      if (digits.length === this.codeLength) this.send();
    });
    this.root = h('form', { className: 'pairing' }, h('h1', { text: t('pairing.title') }), this.message, this.error, this.input, this.button);
    this.root.addEventListener('submit', (event) => {
      event.preventDefault();
      this.send();
    });
  }

  update(request: PairRequest): void {
    this.codeLength = request.codeLength;
    this.input.maxLength = request.codeLength;
    this.input.placeholder = '•'.repeat(request.codeLength);
    this.message.textContent = t('pairing.message', { length: request.codeLength });
    this.error.textContent = request.retry
      ? `${t('pairing.wrongCode')} ${plural('pairing.attemptsLeft', request.attemptsLeft)}`
      : '';
    this.input.value = '';
    this.input.disabled = false;
    this.button.disabled = true;
    this.button.textContent = t('pairing.submit');
    requestAnimationFrame(() => this.input.focus());
  }

  private send(): void {
    const code = this.input.value;
    if (code.length !== this.codeLength || this.input.disabled) return;
    this.input.disabled = true;
    this.button.disabled = true;
    this.button.textContent = t('pairing.checking');
    this.submit(code);
  }
}
