import { t } from '../i18n';
import { h, icon } from './dom';
import { icons } from './icons';

export interface ToolbarActions {
  fullscreen(): void;
  keyboard(): void;
  stats(): void;
  disconnect(): void;
}

const HIDE_AFTER_MS = 3000;
/** The mouse near the top edge reveals the toolbar. */
const REVEAL_ZONE_PX = 24;

/** Small auto-hiding toolbar at the top centre; a handle stays visible to bring it back on touch screens. */
export class Toolbar {
  readonly root: HTMLElement;
  private readonly bar: HTMLElement;
  private readonly fullscreenButton: HTMLButtonElement;
  private readonly keyboardButton: HTMLButtonElement;
  private readonly statsButton: HTMLButtonElement;
  private hideTimer: ReturnType<typeof setTimeout> | undefined;
  private hovered = false;

  constructor(parent: HTMLElement, actions: ToolbarActions, fullscreenAvailable: boolean) {
    this.fullscreenButton = this.button(icons.enterFullscreen, t('toolbar.fullscreen.enter'), actions.fullscreen);
    this.fullscreenButton.hidden = !fullscreenAvailable;
    this.keyboardButton = this.button(icons.keyboard, t('toolbar.keyboard'), actions.keyboard);
    this.statsButton = this.button(icons.stats, t('toolbar.stats'), actions.stats);
    const disconnect = this.button(icons.disconnect, t('toolbar.disconnect'), actions.disconnect);
    disconnect.classList.add('danger');

    this.bar = h(
      'div',
      { className: 'toolbar-bar', attrs: { role: 'toolbar', 'aria-label': t('toolbar.label') } },
      this.fullscreenButton,
      this.keyboardButton,
      this.statsButton,
      disconnect,
    );
    const handle = h('button', {
      className: 'toolbar-handle',
      attrs: { type: 'button', 'aria-label': t('toolbar.show'), title: t('toolbar.show') },
      on: { click: () => this.reveal() },
    });
    this.root = h('div', { className: 'toolbar' }, handle, this.bar);
    this.root.hidden = true;
    this.root.addEventListener('pointerenter', () => {
      this.hovered = true;
      this.reveal();
    });
    this.root.addEventListener('pointerleave', () => {
      this.hovered = false;
      this.scheduleHide();
    });
    window.addEventListener('pointermove', (event) => {
      if (event.pointerType === 'mouse' && event.clientY <= REVEAL_ZONE_PX && !this.root.hidden) this.reveal();
    });
    parent.append(this.root);
  }

  /** Shown only while a stream is up. */
  setEnabled(enabled: boolean): void {
    if (this.root.hidden === !enabled) return;
    this.root.hidden = !enabled;
    if (enabled) this.reveal();
  }

  setFullscreen(active: boolean): void {
    const label = t(active ? 'toolbar.fullscreen.exit' : 'toolbar.fullscreen.enter');
    this.fullscreenButton.replaceChildren(icon(active ? icons.exitFullscreen : icons.enterFullscreen));
    this.fullscreenButton.setAttribute('aria-label', label);
    this.fullscreenButton.title = label;
  }

  setKeyboardActive(active: boolean): void {
    this.keyboardButton.setAttribute('aria-pressed', String(active));
  }

  setStatsActive(active: boolean): void {
    this.statsButton.setAttribute('aria-pressed', String(active));
  }

  reveal(): void {
    this.root.classList.add('open');
    this.scheduleHide();
  }

  private scheduleHide(): void {
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      if (!this.hovered) this.root.classList.remove('open');
    }, HIDE_AFTER_MS);
  }

  private button(paths: readonly string[], label: string, action: () => void): HTMLButtonElement {
    const button = h('button', {
      className: 'toolbar-button',
      attrs: { type: 'button', 'aria-label': label, title: label },
    });
    button.append(icon(paths));
    // Don't take focus: the soft-keyboard field must stay focused while it is open.
    button.addEventListener('mousedown', (event) => event.preventDefault());
    button.addEventListener('click', () => {
      action();
      this.reveal();
    });
    return button;
  }
}
