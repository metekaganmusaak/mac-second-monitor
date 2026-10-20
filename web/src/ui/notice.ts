import { t } from '../i18n';
import { h } from './dom';

/** A small dismissible message at the bottom of the screen. */
export class Notice {
  readonly root: HTMLElement;
  private readonly text: HTMLElement;
  private readonly actionButton: HTMLButtonElement;
  private action: (() => void) | null = null;
  private timer: ReturnType<typeof setTimeout> | undefined;

  constructor(parent: HTMLElement) {
    this.text = h('span');
    this.actionButton = h('button', {
      className: 'button',
      attrs: { type: 'button' },
      on: {
        click: () => {
          const action = this.action;
          this.hide();
          action?.();
        },
      },
    });
    this.root = h('div', { className: 'notice', attrs: { role: 'status' } }, this.text, this.actionButton);
    this.root.hidden = true;
    parent.append(this.root);
  }

  /** With `action`, the button runs it; otherwise it just dismisses the notice. */
  show(message: string, options: { actionLabel?: string; action?: () => void; durationMs?: number } = {}): void {
    clearTimeout(this.timer);
    this.text.textContent = message;
    this.action = options.action ?? null;
    this.actionButton.textContent = options.actionLabel ?? t('notice.dismiss');
    this.root.hidden = false;
    if (options.durationMs) this.timer = setTimeout(() => this.hide(), options.durationMs);
  }

  hide(): void {
    clearTimeout(this.timer);
    this.action = null;
    this.root.hidden = true;
  }
}
