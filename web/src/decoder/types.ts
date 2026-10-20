import type { StreamConfig, VideoMessage } from '../protocol';

export type PipelineKind = 'webcodecs' | 'mse';

export interface PipelineCallbacks {
  /** The frame reached the decoder; the host may send the next one. */
  ack(seq: number): void;
  requestKeyframe(): void;
  /** A frame was put on screen at `atMs` (performance.now clock). */
  presented(captureTime: number, atMs: number): void;
  /** Intrinsic size of the decoded picture changed. */
  videoSize(width: number, height: number): void;
  /** The pipeline cannot work in this browser; the app picks another one. */
  fatal(error: unknown): void;
  /** Playback needs a user gesture (autoplay was blocked). */
  needsGesture(): void;
}

export interface PipelineStats {
  /** Average time from handing a frame over to it being ready for display, ms. */
  decodeMs: number;
  droppedFrames: number;
  /** Frames shown, when the pipeline counts them itself (otherwise `presented` calls are counted). */
  presentedFrames?: number;
}

export interface VideoPipeline {
  readonly kind: PipelineKind;
  readonly element: HTMLCanvasElement | HTMLVideoElement;
  configure(config: StreamConfig): void;
  push(frame: VideoMessage): void;
  /** Recover after the page was in the background (decoders may have been reclaimed). */
  refresh(): void;
  /** Called from a user gesture after `needsGesture`. */
  resume(): void;
  /** Counters since the previous call. */
  takeStats(): PipelineStats;
  destroy(): void;
}

/** Limits KEYFRAME_REQ to one per interval: a request is answered within a frame or two. */
export class KeyframeRequester {
  private last = Number.NEGATIVE_INFINITY;

  constructor(
    private readonly send: () => void,
    private readonly intervalMs = 500,
  ) {}

  request(force = false): void {
    const now = performance.now();
    if (!force && now - this.last < this.intervalMs) return;
    this.last = now;
    this.send();
  }
}
