import type { Bytes, StreamConfig, VideoMessage } from '../protocol';
import { NalType, nalType, splitAnnexB, toLengthPrefixed } from '../video/annexb';
import { concat, initSegment, mediaSegment } from '../video/fmp4';
import { KeyframeRequester, type PipelineCallbacks, type PipelineStats, type VideoPipeline } from './types';

const TIMESCALE = 90_000;
const CHECK_INTERVAL_MS = 250;
/**
 * Lag behind the newest frame, in frame durations, above which playback speeds up, and below
 * which it returns to normal. Chrome resumes from a brief underflow within a frame, so a
 * small target is safe and keeps latency close to WebCodecs'.
 */
const CATCH_UP_FRAMES = 5;
const CATCH_UP_DONE_FRAMES = 3.5;
const MAX_RATE = 2;
/** Above this, jump to the next keyframe (seeking elsewhere would decode from the last one). */
const JUMP_LAG_S = 1;
/** Ask for a fresh keyframe after this much video so old data can be removed. */
const KEYFRAME_REFRESH_S = 20;
const KEEP_BEHIND_S = 2;
const ERROR_WINDOW_MS = 10_000;
const MAX_ERRORS_IN_WINDOW = 5;
const MAX_TRACKED_FRAMES = 240;

interface MediaSourceClass {
  new (): MediaSource;
  isTypeSupported(type: string): boolean;
}

function mediaSourceClass(): MediaSourceClass | null {
  const scope = window as unknown as { MediaSource?: MediaSourceClass; ManagedMediaSource?: MediaSourceClass };
  // iPhone Safari (17.1+) only has ManagedMediaSource.
  return scope.MediaSource ?? scope.ManagedMediaSource ?? null;
}

function pickMimeType(source: MediaSourceClass, codecString: string): string | null {
  // The codec parameter only gates support; the SPS in the init segment is what counts.
  for (const codec of [codecString, 'avc1.640033', 'avc1.4D4033', 'avc1.42E033']) {
    const mime = `video/mp4; codecs="${codec}"`;
    if (source.isTypeSupported(mime)) return mime;
  }
  return null;
}

function sameBytes(a: Uint8Array | null, b: Uint8Array): boolean {
  if (!a || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function remember(map: Map<number, number>, key: number, value: number): void {
  map.set(key, value);
  if (map.size > MAX_TRACKED_FRAMES) {
    const oldest = map.keys().next();
    if (!oldest.done) map.delete(oldest.value);
  }
}

/**
 * Media Source Extensions fallback for insecure contexts: each access unit becomes one fMP4
 * fragment on a synthetic, gap-free timeline (one frame duration per frame), so a static
 * screen just pauses at the live edge instead of leaving holes in the buffer.
 */
export class MsePipeline implements VideoPipeline {
  readonly kind = 'mse';
  readonly element: HTMLVideoElement;
  private readonly keyframes: KeyframeRequester;
  private mediaSource: MediaSource | null = null;
  private sourceBuffer: SourceBuffer | null = null;
  private objectUrl: string | null = null;
  private mime = '';
  private config: StreamConfig | null = null;
  private frameDuration = TIMESCALE / 60;

  private sps: Uint8Array | null = null;
  private pps: Uint8Array | null = null;
  private hasInit = false;
  private waitingForKeyframe = true;
  private fragmentNumber = 1;
  private frameIndex = 0;

  private queue: Bytes[] = [];
  private queuedSeqs: number[] = [];
  private queuedIndices: number[] = [];
  private queuedKeyframeTime: number | null = null;
  private appendingKeyframeTime: number | null = null;
  private lastKeyframeTime = -1;
  private trimEnd = 0;
  private jumpPending = false;
  private framesSinceKeyframe = 0;
  private lastRefreshRequest = 0;

  private readonly captureTimes = new Map<number, number>();
  private readonly appendTimes = new Map<number, number>();
  private started = false;
  private blocked = false;
  private readonly timer: ReturnType<typeof setInterval>;
  private errorTimes: number[] = [];
  private decodeTotalMs = 0;
  private decodeCount = 0;
  private dropped = 0;
  private reportedDropped = 0;
  private reportedTotal = 0;
  private destroyed = false;

  static isAvailable(): boolean {
    const source = mediaSourceClass();
    return !!source && pickMimeType(source, 'avc1.42E01F') !== null;
  }

  constructor(private readonly callbacks: PipelineCallbacks) {
    const video = document.createElement('video');
    video.className = 'video';
    video.muted = true;
    video.defaultMuted = true;
    video.autoplay = true;
    video.playsInline = true;
    video.controls = false;
    video.disablePictureInPicture = true;
    // Required for ManagedMediaSource unless an AirPlay alternative is provided.
    video.disableRemotePlayback = true;
    video.setAttribute('playsinline', '');
    video.setAttribute('muted', '');
    video.addEventListener('error', this.onMediaError);
    video.addEventListener('resize', () => this.callbacks.videoSize(video.videoWidth, video.videoHeight));
    this.element = video;
    this.keyframes = new KeyframeRequester(() => callbacks.requestKeyframe());
    this.timer = setInterval(() => this.chaseLiveEdge(), CHECK_INTERVAL_MS);
    this.watchPresentedFrames();
  }

  configure(config: StreamConfig): void {
    const previous = this.config;
    this.config = config;
    const changed =
      !previous ||
      previous.codecString !== config.codecString ||
      previous.width !== config.width ||
      previous.height !== config.height ||
      previous.fps !== config.fps;
    if (changed || !this.mediaSource) this.rebuild();
    this.waitingForKeyframe = true;
  }

  push(frame: VideoMessage): void {
    if (!this.mediaSource) {
      this.callbacks.ack(frame.seq);
      return;
    }
    let sps: Uint8Array | undefined;
    let pps: Uint8Array | undefined;
    const units: Uint8Array[] = [];
    for (const unit of splitAnnexB(frame.data)) {
      const type = nalType(unit);
      if (type === NalType.sps) sps = unit;
      else if (type === NalType.pps) pps = unit;
      else if (type !== NalType.aud) units.push(unit);
    }
    // Parameter sets live in the init segment ('avc1'), not in the samples.
    if (frame.keyframe && sps && pps && (!this.hasInit || !sameBytes(this.sps, sps) || !sameBytes(this.pps, pps))) {
      this.sps = sps.slice();
      this.pps = pps.slice();
      try {
        this.queue.push(initSegment({ sps: this.sps, pps: this.pps, timescale: TIMESCALE }));
        this.hasInit = true;
      } catch (error) {
        console.warn('Cannot parse SPS', error);
      }
    }
    if (!this.hasInit || units.length === 0 || (this.waitingForKeyframe && !frame.keyframe)) {
      this.dropped++;
      this.callbacks.ack(frame.seq);
      this.keyframes.request();
      return;
    }
    this.waitingForKeyframe = false;

    const index = this.frameIndex++;
    const decodeTime = index * this.frameDuration;
    this.queue.push(
      mediaSegment(this.fragmentNumber++, {
        data: toLengthPrefixed(units),
        decodeTime,
        duration: this.frameDuration,
        keyframe: frame.keyframe,
      }),
    );
    this.queuedSeqs.push(frame.seq);
    this.queuedIndices.push(index);
    remember(this.captureTimes, index, frame.captureTime);
    if (frame.keyframe) {
      this.queuedKeyframeTime = decodeTime / TIMESCALE;
      this.framesSinceKeyframe = 0;
    } else if (++this.framesSinceKeyframe >= KEYFRAME_REFRESH_S * (this.config?.fps ?? 60)) {
      const now = performance.now();
      if (now - this.lastRefreshRequest > 5000) {
        this.lastRefreshRequest = now;
        this.keyframes.request(true);
      }
    }
    this.flush();
  }

  refresh(): void {
    const buffered = this.element.buffered;
    if (buffered.length && buffered.end(buffered.length - 1) - this.element.currentTime > JUMP_LAG_S) {
      this.jumpPending = true;
    }
    this.keyframes.request(true);
    if (this.started && this.element.paused) void this.element.play().catch(() => undefined);
  }

  resume(): void {
    this.blocked = false;
    this.startPlayback();
  }

  takeStats(): PipelineStats {
    const stats: PipelineStats = {
      decodeMs: this.decodeCount ? this.decodeTotalMs / this.decodeCount : 0,
      droppedFrames: this.dropped,
    };
    // requestVideoFrameCallback can fire less often than frames are shown (it follows the
    // compositor), so count frames from the media element instead.
    const quality = this.element.getVideoPlaybackQuality?.();
    if (quality) {
      const total = quality.totalVideoFrames - this.reportedTotal;
      const dropped = quality.droppedVideoFrames - this.reportedDropped;
      this.reportedTotal = quality.totalVideoFrames;
      this.reportedDropped = quality.droppedVideoFrames;
      if (total >= 0 && dropped >= 0) {
        stats.droppedFrames += dropped;
        stats.presentedFrames = total - dropped;
      }
    }
    this.decodeTotalMs = 0;
    this.decodeCount = 0;
    this.dropped = 0;
    return stats;
  }

  destroy(): void {
    this.destroyed = true;
    clearInterval(this.timer);
    this.teardown();
    this.element.remove();
  }

  private rebuild(): void {
    this.teardown();
    const config = this.config;
    const source = mediaSourceClass();
    const mime = source && config ? pickMimeType(source, config.codecString) : null;
    if (!source || !config || !mime) {
      this.callbacks.fatal(new Error('Media Source Extensions cannot play H.264 here'));
      return;
    }
    this.mime = mime;
    this.frameDuration = Math.max(1, Math.round(TIMESCALE / Math.max(1, config.fps)));
    const mediaSource = new source();
    this.mediaSource = mediaSource;
    this.objectUrl = URL.createObjectURL(mediaSource);
    mediaSource.addEventListener('sourceopen', () => this.onSourceOpen(mediaSource), { once: true });
    this.element.src = this.objectUrl;
  }

  private teardown(): void {
    for (const seq of this.queuedSeqs) this.callbacks.ack(seq);
    this.queue = [];
    this.queuedSeqs = [];
    this.queuedIndices = [];
    this.queuedKeyframeTime = null;
    this.appendingKeyframeTime = null;
    this.sourceBuffer?.removeEventListener('updateend', this.onUpdateEnd);
    this.sourceBuffer = null;
    this.mediaSource = null;
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl);
      this.objectUrl = null;
      this.element.removeAttribute('src');
      this.element.load();
    }
    this.sps = null;
    this.pps = null;
    this.hasInit = false;
    this.waitingForKeyframe = true;
    this.fragmentNumber = 1;
    this.frameIndex = 0;
    this.lastKeyframeTime = -1;
    this.trimEnd = 0;
    this.jumpPending = false;
    this.framesSinceKeyframe = 0;
    this.captureTimes.clear();
    this.appendTimes.clear();
    this.started = false;
    this.reportedTotal = 0;
    this.reportedDropped = 0;
  }

  private onSourceOpen(mediaSource: MediaSource): void {
    if (mediaSource !== this.mediaSource || this.destroyed) return;
    try {
      const buffer = mediaSource.addSourceBuffer(this.mime);
      buffer.mode = 'segments';
      buffer.addEventListener('updateend', this.onUpdateEnd);
      this.sourceBuffer = buffer;
    } catch (error) {
      this.callbacks.fatal(error);
      return;
    }
    this.flush();
  }

  private flush(): void {
    const buffer = this.sourceBuffer;
    if (!buffer || buffer.updating || this.mediaSource?.readyState !== 'open') return;
    if (this.queue.length) {
      const data = this.queue.length === 1 ? this.queue[0]! : concat(this.queue);
      const seqs = this.queuedSeqs;
      const now = performance.now();
      for (const index of this.queuedIndices) remember(this.appendTimes, index, now);
      this.appendingKeyframeTime = this.queuedKeyframeTime;
      this.queue = [];
      this.queuedSeqs = [];
      this.queuedIndices = [];
      this.queuedKeyframeTime = null;
      try {
        buffer.appendBuffer(data);
      } catch (error) {
        // Typically QuotaExceededError: start over from a fresh keyframe.
        console.warn('appendBuffer failed', error);
        for (const seq of seqs) this.callbacks.ack(seq);
        this.recover(error);
        return;
      }
      for (const seq of seqs) this.callbacks.ack(seq);
      return;
    }
    if (this.trimEnd > 0) {
      const end = this.trimEnd;
      this.trimEnd = 0;
      try {
        buffer.remove(0, end);
      } catch (error) {
        console.warn('SourceBuffer.remove failed', error);
      }
    }
  }

  private readonly onUpdateEnd = () => {
    if (this.appendingKeyframeTime !== null) {
      this.lastKeyframeTime = this.appendingKeyframeTime;
      this.appendingKeyframeTime = null;
      if (this.jumpPending) {
        this.jumpPending = false;
        this.element.currentTime = this.lastKeyframeTime;
      }
    }
    if (!this.started) this.startPlayback();
    this.scheduleTrim();
    this.flush();
    this.chaseLiveEdge();
  };

  private startPlayback(): void {
    if (this.blocked || !this.mediaSource) return;
    this.started = true;
    this.element.play().catch((error: unknown) => {
      if (error instanceof DOMException && error.name === 'NotAllowedError') {
        this.blocked = true;
        this.started = false;
        this.callbacks.needsGesture();
      }
    });
  }

  /** Old data can only be removed up to a keyframe: removal extends to the next random access point. */
  private scheduleTrim(): void {
    const keyframe = this.lastKeyframeTime;
    const buffered = this.element.buffered;
    if (keyframe <= 0 || !buffered.length) return;
    if (this.element.currentTime > keyframe + KEEP_BEHIND_S && buffered.start(0) < keyframe - 0.5) {
      // Stop half a frame early so the keyframe itself is the random access point that ends the removal.
      this.trimEnd = keyframe - this.frameDuration / TIMESCALE / 2;
    }
  }

  private chaseLiveEdge(): void {
    const video = this.element;
    const buffered = video.buffered;
    if (!this.started || !buffered.length) return;
    const start = buffered.start(0);
    const end = buffered.end(buffered.length - 1);
    if (video.currentTime < start) {
      video.currentTime = start;
      return;
    }
    const lag = end - video.currentTime;
    if (lag > JUMP_LAG_S && !this.jumpPending) {
      this.jumpPending = true;
      this.keyframes.request(true);
    }
    const frame = this.frameDuration / TIMESCALE;
    let rate = video.playbackRate;
    if (lag > CATCH_UP_FRAMES * frame) {
      rate = Math.min(MAX_RATE, 1 + Math.max(0.05, (lag - CATCH_UP_DONE_FRAMES * frame) * 3));
    } else if (lag < CATCH_UP_DONE_FRAMES * frame) {
      rate = 1;
    }
    if (video.playbackRate !== rate) video.playbackRate = rate;
    if (video.paused && !this.blocked) void video.play().catch(() => undefined);
  }

  private watchPresentedFrames(): void {
    const video = this.element;
    if (typeof video.requestVideoFrameCallback !== 'function') return;
    const onFrame: VideoFrameRequestCallback = (_now, metadata) => {
      if (this.destroyed) return;
      const index = Math.round((metadata.mediaTime * TIMESCALE) / this.frameDuration);
      const capture = this.captureTimes.get(index);
      if (capture !== undefined) {
        this.captureTimes.delete(index);
        this.callbacks.presented(capture, metadata.expectedDisplayTime);
      }
      const appended = this.appendTimes.get(index);
      if (appended !== undefined) {
        this.appendTimes.delete(index);
        this.decodeTotalMs += metadata.presentationTime - appended;
        this.decodeCount++;
      }
      video.requestVideoFrameCallback(onFrame);
    };
    video.requestVideoFrameCallback(onFrame);
  }

  private readonly onMediaError = () => {
    // Errors from a source that was already replaced are stale.
    if (!this.mediaSource || this.destroyed || this.element.currentSrc !== this.objectUrl) return;
    console.warn('Video element error', this.element.error);
    this.recover(this.element.error);
  };

  private recover(error: unknown): void {
    const now = performance.now();
    this.errorTimes = this.errorTimes.filter((time) => now - time < ERROR_WINDOW_MS);
    this.errorTimes.push(now);
    if (this.errorTimes.length >= MAX_ERRORS_IN_WINDOW) {
      this.teardown();
      this.callbacks.fatal(error);
      return;
    }
    this.rebuild();
    this.keyframes.request(true);
  }
}
