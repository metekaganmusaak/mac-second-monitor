import { fitRect, type Rect } from '../input/geometry';
import { h } from './dom';

/** Full-window stage that letterboxes the video element. */
export class Surface {
  readonly stage: HTMLElement;
  private element: HTMLElement | null = null;
  private contentWidth = 0;
  private contentHeight = 0;

  constructor(parent: HTMLElement) {
    this.stage = h('div', { className: 'stage' });
    parent.append(this.stage);
    window.addEventListener('resize', () => this.layout());
    window.visualViewport?.addEventListener('resize', () => this.layout());
  }

  attach(element: HTMLElement): void {
    if (this.element === element) return;
    this.element?.remove();
    this.element = element;
    this.stage.append(element);
    this.layout();
  }

  setContentSize(width: number, height: number): void {
    if (width === this.contentWidth && height === this.contentHeight) return;
    this.contentWidth = width;
    this.contentHeight = height;
    this.layout();
  }

  /** The video picture in client coordinates. */
  videoRect(): Rect {
    const rect = (this.element ?? this.stage).getBoundingClientRect();
    return { left: rect.left, top: rect.top, width: rect.width, height: rect.height };
  }

  layout(): void {
    const element = this.element;
    if (!element) return;
    const rect = fitRect(this.contentWidth, this.contentHeight, this.stage.clientWidth, this.stage.clientHeight, window.devicePixelRatio || 1);
    element.style.left = `${rect.left}px`;
    element.style.top = `${rect.top}px`;
    element.style.width = `${rect.width}px`;
    element.style.height = `${rect.height}px`;
  }
}
