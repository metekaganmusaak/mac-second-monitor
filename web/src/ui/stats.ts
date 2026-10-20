import { formatNumber, t } from '../i18n';
import type { ClientStats } from '../protocol';
import { h } from './dom';

export interface StatsContext {
  decoder: 'webcodecs' | 'mse';
  width: number;
  height: number;
}

/** Corner overlay with the once-per-second numbers that are also sent to the host. */
export class StatsOverlay {
  readonly root: HTMLElement;
  private readonly list: HTMLElement;

  constructor(parent: HTMLElement) {
    this.list = h('dl');
    this.root = h('div', { className: 'stats', attrs: { 'aria-live': 'off' } }, this.list);
    this.root.hidden = true;
    parent.append(this.root);
  }

  get visible(): boolean {
    return !this.root.hidden;
  }

  toggle(): boolean {
    this.root.hidden = !this.root.hidden;
    return !this.root.hidden;
  }

  update(stats: ClientStats, context: StatsContext | null): void {
    if (this.root.hidden) return;
    const none = t('stats.value.none');
    const ms = (value: number | undefined, digits = 0) =>
      value === undefined ? none : t('stats.value.ms', { value: formatNumber(value, digits) });
    const rows: Array<[string, string]> = [
      [t('stats.fps'), t('stats.value.fps', { value: formatNumber(stats.fps) })],
      [t('stats.latency'), ms(stats.latencyMs)],
      [t('stats.rtt'), ms(stats.rttMs, 1)],
      [t('stats.bitrate'), t('stats.value.mbps', { value: formatNumber(stats.bitrateKbps / 1000, 1) })],
      [t('stats.decode'), ms(stats.decodeMs, 1)],
      [t('stats.dropped'), formatNumber(stats.droppedFrames)],
    ];
    if (context) {
      rows.push([t('stats.resolution'), t('stats.value.resolution', { width: context.width, height: context.height })]);
      rows.push([t('stats.decoder'), t(`stats.decoder.${context.decoder}`)]);
    }
    this.list.replaceChildren(...rows.flatMap(([label, value]) => [h('dt', { text: label }), h('dd', { text: value })]));
  }
}
