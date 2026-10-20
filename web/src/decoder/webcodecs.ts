import type { StreamConfig, VideoMessage } from '../protocol';
import { KeyframeRequester, type PipelineCallbacks, type PipelineStats, type VideoPipeline } from './types';

/** ACKs are held back while more chunks than this wait inside the decoder. */
const MAX_DECODE_QUEUE = 2;
const ACK_HOLD_LIMIT_MS = 250;
/** Frames kept while the decoder is being configured (the first keyframe arrives right away). */
const MAX_BACKLOG = 30;
const ERROR_WINDOW_MS = 10_000;
const MAX_ERRORS_IN_WINDOW = 5;

export async function findDecoderConfig(config: StreamConfig): Promise<VideoDecoderConfig | null> {
  for (const hardwareAcceleration of ['prefer-hardware', 'no-preference'] as const) {
    // No `description`: chunks are Annex-B with in-band SPS / PPS on keyframes.
    const candidate: VideoDecoderConfig = {
      codec: config.codecString,
      codedWidth: config.width,
      codedHeight: config.height,
      optimizeForLatency: true,
      hardwareAcceleration,
    };
    try {
      const support = await VideoDecoder.isConfigSupported(candidate);
      if (support.supported) return candidate;
    } catch {
      // Invalid config for this browser; try the next one.
    }
  }
  return null;
}

/** WebCodecs decoder drawing into a canvas: at most one frame per display refresh, newest wins. */
export class WebCodecsPipeline implements VideoPipeline {
  readonly kind = 'webcodecs';
  readonly element: HTMLCanvasElement;
  private readonly context: CanvasRenderingContext2D;
  private readonly keyframes: KeyframeRequester;
  private decoder: VideoDecoder | null = null;
  private decoderConfig: VideoDecoderConfig | null = null;
  private configureToken = 0;
  private configuring = false;
  private backlog: VideoMessage[] = [];
  private waitingForKeyframe = true;
  private pending: VideoFrame | null = null;
  private frameRequest = 0;
  private readonly decodeStarted = new Map<number, number>();
  private heldAcks: number[] = [];
  private holdTimer: ReturnType<typeof setTimeout> | undefined;
  private errorTimes: number[] = [];
  private decodeTotalMs = 0;
  private decodeCount = 0;
  private dropped = 0;
  private destroyed = false;

  static isAvailable(): boolean {
    return window.isSecureContext && typeof VideoDecoder === 'function' && typeof EncodedVideoChunk === 'function';
  }

  constructor(private readonly callbacks: PipelineCallbacks) {
    this.element = document.createElement('canvas');
    this.element.className = 'video';
    const context = this.element.getContext('2d', { alpha: false, desynchronized: true });
    if (!context) throw new Error('2D canvas unavailable');
    this.context = context;
    this.keyframes = new KeyframeRequester(() => callbacks.requestKeyframe());
  }

  configure(config: StreamConfig): void {
    const token = ++this.configureToken;
    this.closeDecoder();
    this.configuring = true;
    this.waitingForKeyframe = true;
    findDecoderConfig(config).then(
      (found) => {
        if (token !== this.configureToken || this.destroyed) return;
        this.configuring = false;
        if (!found) {
          this.callbacks.fatal(new Error(`WebCodecs cannot decode ${config.codecString}`));
          return;
        }
        this.decoderConfig = found;
        if (!this.openDecoder()) return;
        const backlog = this.backlog;
        this.backlog = [];
        for (const frame of backlog) this.decode(frame, true);
        // Frames but no keyframe among them; with no frames yet, the host's first keyframe is on its way.
        if (this.waitingForKeyframe && backlog.length) this.keyframes.request(true);
      },
      (error: unknown) => {
        if (token === this.configureToken) this.callbacks.fatal(error);
      },
    );
  }

  push(frame: VideoMessage): void {
    if (this.configuring || !this.decoder) {
      if (frame.keyframe) this.backlog = [];
      this.backlog.push(frame);
      if (this.backlog.length > MAX_BACKLOG) {
        this.dropped += this.backlog.length;
        this.backlog = [];
      }
      this.callbacks.ack(frame.seq);
      return;
    }
    this.decode(frame, false);
  }

  refresh(): void {
    if (this.decoderConfig && (!this.decoder || this.decoder.state === 'closed')) {
      this.openDecoder();
    }
    this.keyframes.request(true);
  }

  resume(): void {
    // Canvas rendering needs no gesture.
  }

  takeStats(): PipelineStats {
    const stats = {
      decodeMs: this.decodeCount ? this.decodeTotalMs / this.decodeCount : 0,
      droppedFrames: this.dropped,
    };
    this.decodeTotalMs = 0;
    this.decodeCount = 0;
    this.dropped = 0;
    return stats;
  }

  destroy(): void {
    this.destroyed = true;
    this.configureToken++;
    this.closeDecoder();
    cancelAnimationFrame(this.frameRequest);
    this.pending?.close();
    this.pending = null;
    this.element.remove();
  }

  private openDecoder(): boolean {
    this.closeDecoder();
    if (!this.decoderConfig) return false;
    const decoder = new VideoDecoder({
      output: (frame) => this.onOutput(frame),
      error: (error) => this.onError(decoder, error),
    });
    try {
      decoder.configure(this.decoderConfig);
    } catch (error) {
      this.callbacks.fatal(error);
      return false;
    }
    decoder.addEventListener('dequeue', this.releaseAcks);
    this.decoder = decoder;
    this.waitingForKeyframe = true;
    return true;
  }

  private closeDecoder(): void {
    const decoder = this.decoder;
    this.decoder = null;
    if (decoder) {
      decoder.removeEventListener('dequeue', this.releaseAcks);
      if (decoder.state !== 'closed') decoder.close();
    }
    this.decodeStarted.clear();
    this.flushAcks();
  }

  private decode(frame: VideoMessage, alreadyAcked: boolean): void {
    const decoder = this.decoder;
    const ack = () => {
      if (!alreadyAcked) this.callbacks.ack(frame.seq);
    };
    if (!decoder) {
      ack();
      return;
    }
    if (this.waitingForKeyframe) {
      if (!frame.keyframe) {
        this.dropped++;
        ack();
        this.keyframes.request();
        return;
      }
      this.waitingForKeyframe = false;
    }
    try {
      this.decodeStarted.set(frame.captureTime, performance.now());
      if (this.decodeStarted.size > 64) this.decodeStarted.clear();
      decoder.decode(
        new EncodedVideoChunk({
          type: frame.keyframe ? 'key' : 'delta',
          timestamp: frame.captureTime,
          data: frame.data,
        }),
      );
    } catch (error) {
      ack();
      this.onError(decoder, error);
      return;
    }
    if (alreadyAcked) return;
    if (decoder.decodeQueueSize <= MAX_DECODE_QUEUE) {
      this.callbacks.ack(frame.seq);
    } else {
      // A slow decoder must slow the host down rather than build a queue.
      this.heldAcks.push(frame.seq);
      this.holdTimer ??= setTimeout(() => this.flushAcks(), ACK_HOLD_LIMIT_MS);
    }
  }

  private readonly releaseAcks = () => {
    const queued = this.decoder?.decodeQueueSize ?? 0;
    while (this.heldAcks.length && queued <= MAX_DECODE_QUEUE) {
      this.callbacks.ack(this.heldAcks.shift()!);
    }
    if (!this.heldAcks.length) this.clearHoldTimer();
  };

  private flushAcks(): void {
    for (const seq of this.heldAcks) this.callbacks.ack(seq);
    this.heldAcks = [];
    this.clearHoldTimer();
  }

  private clearHoldTimer(): void {
    clearTimeout(this.holdTimer);
    this.holdTimer = undefined;
  }

  private onOutput(frame: VideoFrame): void {
    if (this.destroyed) {
      frame.close();
      return;
    }
    const started = this.decodeStarted.get(frame.timestamp);
    if (started !== undefined) {
      this.decodeStarted.delete(frame.timestamp);
      this.decodeTotalMs += performance.now() - started;
      this.decodeCount++;
    }
    if (this.frameRequest === 0) {
      // Nothing drawn since the last animation frame: show it right away (a desynchronized
      // canvas can present before the next vsync).
      this.draw(frame);
      this.frameRequest = requestAnimationFrame(this.onAnimationFrame);
    } else {
      // Already drew this frame interval: keep only the newest until the next one.
      if (this.pending) {
        this.pending.close();
        if (document.visibilityState === 'visible') this.dropped++;
      }
      this.pending = frame;
    }
    this.releaseAcks();
  }

  private readonly onAnimationFrame = () => {
    this.frameRequest = 0;
    const frame = this.pending;
    if (!frame) return;
    this.pending = null;
    this.draw(frame);
    this.frameRequest = requestAnimationFrame(this.onAnimationFrame);
  };

  private draw(frame: VideoFrame): void {
    const width = frame.displayWidth;
    const height = frame.displayHeight;
    if (this.element.width !== width || this.element.height !== height) {
      this.element.width = width;
      this.element.height = height;
      this.callbacks.videoSize(width, height);
    }
    this.context.drawImage(frame, 0, 0, width, height);
    const captureTime = frame.timestamp;
    frame.close();
    this.callbacks.presented(captureTime, performance.now());
  }

  private onError(decoder: VideoDecoder, error: unknown): void {
    if (decoder !== this.decoder || this.destroyed) return;
    console.warn('Video decoder error', error);
    const now = performance.now();
    this.errorTimes = this.errorTimes.filter((time) => now - time < ERROR_WINDOW_MS);
    this.errorTimes.push(now);
    if (this.errorTimes.length >= MAX_ERRORS_IN_WINDOW) {
      this.closeDecoder();
      this.callbacks.fatal(error);
      return;
    }
    if (this.openDecoder()) this.keyframes.request(true);
  }
}
