import { type CloseReason, Connection, type ConnectionHandlers } from './connection';
import { MsePipeline } from './decoder/mse';
import type { PipelineCallbacks, PipelineKind, VideoPipeline } from './decoder/types';
import { WebCodecsPipeline } from './decoder/webcodecs';
import {
  currentDisplaySize,
  deviceId,
  deviceName,
  displayInfo,
  estimateRefreshRate,
  type Size,
  sizeChangedSubstantially,
} from './device';
import { t } from './i18n';
import { KeyboardInput } from './input/keyboard';
import { PointerInput } from './input/pointer';
import { type Bytes, type ClientStats, type Hello, PROTOCOL_VERSION, type StreamConfig, type Welcome } from './protocol';
import { FrameCounter } from './stats';
import { storage } from './storage';
import { fullscreenSupported, isFullscreen, onFullscreenChange, toggleFullscreen } from './ui/fullscreen';
import { Notice } from './ui/notice';
import { Screens } from './ui/screens';
import { StatsOverlay } from './ui/stats';
import { Surface } from './ui/surface';
import { Toolbar } from './ui/toolbar';
import { ScreenWakeLock } from './ui/wakelock';

type Phase = 'connecting' | 'pairing' | 'waiting' | 'streaming' | 'reconnecting' | 'stopped' | 'failed';

const KNOWN_ERRORS = new Set([
  'permission_missing',
  'pairing_failed',
  'pairing_timeout',
  'unsupported_protocol',
  'display_unavailable',
  'rejected',
  'internal',
]);
const MAX_RECONNECT_DELAY_MS = 15_000;
const RESIZE_DEBOUNCE_MS = 1000;
const STATS_VISIBLE_KEY = 'msm.stats';

export interface Endpoint {
  /** host:port, also the key for the pairing token. */
  host: string;
  url: string;
}

/** `ws(s)://<page host>/ws`, or `?host=IP:PORT` (e.g. when the page comes from `vite dev`). */
export function endpointFor(params: URLSearchParams, page: Location): Endpoint | null {
  const host = params.get('host') || page.host;
  if (!host) return null;
  const scheme = page.protocol === 'https:' ? 'wss' : 'ws';
  return { host, url: `${scheme}://${host}/ws` };
}

function tokenKey(host: string): string {
  return `msm.token.${host}`;
}

/** Ties the connection, the video pipeline, input and the UI together. */
export class App {
  private readonly surface: Surface;
  private readonly screens: Screens;
  private readonly toolbar: Toolbar;
  private readonly statsOverlay: StatsOverlay;
  private readonly notice: Notice;
  private readonly keyboard: KeyboardInput;
  private readonly pointer: PointerInput;
  private readonly wakeLock = new ScreenWakeLock();
  private readonly frames = new FrameCounter();

  private phase: Phase = 'connecting';
  private connection: Connection | null = null;
  private pipeline: VideoPipeline | null = null;
  private config: StreamConfig | null = null;
  private webCodecsFailed = false;
  private hasPicture = false;
  private refreshRate = 60;
  private helloSize: Size | null = null;
  private attempts = 0;
  private everConnected = false;
  private insecureNoticeShown = false;
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined;
  private countdownTimer: ReturnType<typeof setInterval> | undefined;
  private resizeTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    root: HTMLElement,
    private readonly params: URLSearchParams,
    private readonly endpoint: Endpoint | null,
  ) {
    this.surface = new Surface(root);
    const inputTarget = {
      videoRect: () => this.surface.videoRect(),
      enabled: () => this.phase === 'streaming' && this.connection !== null,
      send: (bytes: Bytes) => this.connection?.send(bytes),
    };
    this.pointer = new PointerInput(this.surface.stage, inputTarget);
    this.keyboard = new KeyboardInput(inputTarget, root);
    this.keyboard.softInput.addEventListener('blur', () => this.toolbar.setKeyboardActive(false));

    this.statsOverlay = new StatsOverlay(root);
    this.toolbar = new Toolbar(
      root,
      {
        fullscreen: () => void toggleFullscreen(),
        keyboard: () => this.toolbar.setKeyboardActive(this.keyboard.toggleSoftKeyboard()),
        stats: () => {
          const visible = this.statsOverlay.toggle();
          this.toolbar.setStatsActive(visible);
          storage.set(STATS_VISIBLE_KEY, visible ? '1' : '0');
        },
        disconnect: () => this.disconnect(),
      },
      fullscreenSupported(),
    );
    if (params.get('stats') === '1' || storage.get(STATS_VISIBLE_KEY) === '1') {
      this.statsOverlay.toggle();
      this.toolbar.setStatsActive(true);
    }
    this.notice = new Notice(root);
    this.screens = new Screens(root);

    onFullscreenChange(() => this.toolbar.setFullscreen(isFullscreen()));
    window.addEventListener('resize', this.onResize);
    document.addEventListener('visibilitychange', this.onVisibilityChange);
    // Free the Mac's display right away instead of after the host's silence timeout.
    window.addEventListener('pagehide', () => this.closeConnection());
    window.addEventListener('pageshow', (event) => {
      // Restored from the back/forward cache: the old session is gone.
      if (event.persisted && this.phase !== 'stopped' && this.phase !== 'failed') this.connect();
    });
  }

  async start(): Promise<void> {
    if (!this.endpoint) {
      this.fail(t('error.noHost'), undefined, false);
      return;
    }
    this.screens.status(t('status.connecting', { host: this.endpoint.host }), { spinner: true });
    this.refreshRate = await estimateRefreshRate();
    this.connect();
  }

  // MARK: Connection lifecycle

  private connect(resizing = false): void {
    const endpoint = this.endpoint;
    if (!endpoint) return;
    this.clearTimers();
    this.closeConnection();
    if (!this.pipelineKind()) {
      this.fail(t('error.decoder'), undefined, false);
      return;
    }

    this.phase = 'connecting';
    this.screens.status(resizing ? t('status.resizing') : t('status.connecting', { host: endpoint.host }), {
      spinner: true,
      translucent: this.hasPicture,
    });
    const display = displayInfo(this.refreshRate);
    this.helloSize = { width: display.width, height: display.height };
    // Start the new session's STATS from zero.
    this.frames.take(0);
    this.pipeline?.takeStats();
    const token = storage.get(tokenKey(endpoint.host));
    const hello: Hello = {
      protocol: PROTOCOL_VERSION,
      deviceId: deviceId(),
      deviceName: deviceName(),
      platform: 'web',
      appVersion: __APP_VERSION__,
      display,
      codecs: ['h264'],
      locale: navigator.language,
      ...(token ? { token } : {}),
    };
    const connection: Connection = new Connection(
      endpoint.url,
      hello,
      this.handlers(() => this.connection === connection),
      (seconds) => this.frameStats(seconds),
    );
    this.connection = connection;
  }

  private handlers(isCurrent: () => boolean): ConnectionHandlers {
    return {
      welcome: (welcome) => isCurrent() && this.onWelcome(welcome),
      pairRequest: (request) => {
        if (!isCurrent()) return;
        this.phase = 'pairing';
        this.screens.pair(request, (code) => this.connection?.sendPairingCode(code));
      },
      config: (config) => isCurrent() && this.onConfig(config),
      video: (frame) => {
        if (!isCurrent()) return;
        if (this.pipeline) this.pipeline.push(frame);
        else this.connection?.acknowledge(frame.seq);
      },
      stats: (stats) => isCurrent() && this.onStats(stats),
      closed: (reason) => isCurrent() && this.onClosed(reason),
    };
  }

  private onWelcome(welcome: Welcome): void {
    if (welcome.token && this.endpoint) storage.set(tokenKey(this.endpoint.host), welcome.token);
    this.attempts = 0;
    this.everConnected = true;
    this.phase = 'waiting';
    this.screens.status(t('status.waitingForVideo', { hostName: welcome.hostName }), {
      spinner: true,
      translucent: this.hasPicture,
    });
    this.wakeLock.acquire();
  }

  private onConfig(config: StreamConfig): void {
    this.config = config;
    this.surface.setContentSize(config.width, config.height);
    this.ensurePipeline().configure(config);
  }

  private onStats(stats: ClientStats): void {
    const config = this.config;
    this.statsOverlay.update(
      stats,
      config && this.pipeline ? { decoder: this.pipeline.kind, width: config.width, height: config.height } : null,
    );
  }

  private onClosed(reason: CloseReason): void {
    this.connection = null;
    this.keyboard.releaseAll();
    this.pointer.reset();
    this.toolbar.setEnabled(false);
    switch (reason.kind) {
      case 'error': {
        const known = KNOWN_ERRORS.has(reason.code);
        const detail = !known || reason.code === 'internal' ? reason.message : '';
        this.fail(t(known ? `error.${reason.code}` : 'error.internal'), detail ? t('error.hostMessage', { message: detail }) : undefined);
        break;
      }
      case 'bye':
        // "shutdown": the Mac app quit; retrying in a loop can't bring it back.
        if (reason.reason === 'user' || reason.reason === 'shutdown') this.stopped(t('status.disconnected.host'));
        else if (reason.reason === 'replaced') this.stopped(t('status.disconnected.replaced'));
        else this.scheduleReconnect();
        break;
      case 'network':
        this.scheduleReconnect();
        break;
    }
  }

  private scheduleReconnect(): void {
    this.clearTimers();
    this.phase = 'reconnecting';
    this.attempts++;
    const delay = Math.min(MAX_RECONNECT_DELAY_MS, 1000 * 2 ** (this.attempts - 1));
    let seconds = Math.ceil(delay / 1000);
    const message = () =>
      this.everConnected
        ? t('status.reconnecting', { seconds })
        : t('status.unreachable', { host: this.endpoint?.host ?? '', seconds });
    this.screens.status(message(), {
      spinner: true,
      ...(this.everConnected ? {} : { detail: t('status.unreachableHint') }),
      actions: [{ label: t('action.reconnectNow'), primary: true, run: () => this.connect() }],
      translucent: this.hasPicture,
    });
    this.countdownTimer = setInterval(() => {
      seconds = Math.max(1, seconds - 1);
      this.screens.updateMessage(message());
    }, 1000);
    this.reconnectTimer = setTimeout(() => this.connect(), delay);
  }

  private disconnect(): void {
    this.closeConnection();
    this.toolbar.setEnabled(false);
    this.stopped(t('status.disconnected.local'));
  }

  private stopped(message: string): void {
    this.clearTimers();
    this.phase = 'stopped';
    this.wakeLock.release();
    this.screens.status(message, {
      title: t('status.disconnected.title'),
      actions: [
        {
          label: t('action.connect'),
          primary: true,
          run: () => {
            this.attempts = 0;
            this.connect();
          },
        },
      ],
    });
  }

  private fail(message: string, detail?: string, retry = true): void {
    this.clearTimers();
    this.closeConnection();
    this.phase = 'failed';
    this.wakeLock.release();
    this.toolbar.setEnabled(false);
    this.screens.status(message, {
      title: t('error.title'),
      ...(detail ? { detail } : {}),
      actions: retry
        ? [
            {
              label: t('action.retry'),
              primary: true,
              run: () => {
                this.attempts = 0;
                this.connect();
              },
            },
          ]
        : [],
    });
  }

  private closeConnection(): void {
    // Key-ups first, while the session can still deliver them.
    this.keyboard.releaseAll();
    this.pointer.reset();
    const connection = this.connection;
    this.connection = null;
    connection?.close();
  }

  private clearTimers(): void {
    clearTimeout(this.reconnectTimer);
    clearInterval(this.countdownTimer);
    clearTimeout(this.resizeTimer);
  }

  // MARK: Video

  private pipelineKind(): PipelineKind | null {
    const webCodecs = WebCodecsPipeline.isAvailable() && !this.webCodecsFailed;
    const mse = MsePipeline.isAvailable();
    const forced = this.params.get('decoder');
    if (forced === 'mse' && mse) return 'mse';
    if (forced === 'webcodecs' && webCodecs) return 'webcodecs';
    return webCodecs ? 'webcodecs' : mse ? 'mse' : null;
  }

  private ensurePipeline(): VideoPipeline {
    const kind = this.pipelineKind() ?? 'mse';
    if (this.pipeline?.kind === kind) return this.pipeline;
    this.pipeline?.destroy();
    const callbacks = this.pipelineCallbacks(() => this.pipeline === pipeline);
    const pipeline: VideoPipeline = kind === 'webcodecs' ? new WebCodecsPipeline(callbacks) : new MsePipeline(callbacks);
    this.pipeline = pipeline;
    this.hasPicture = false;
    this.surface.attach(pipeline.element);
    return pipeline;
  }

  private pipelineCallbacks(isCurrent: () => boolean): PipelineCallbacks {
    return {
      ack: (seq) => isCurrent() && this.connection?.acknowledge(seq),
      requestKeyframe: () => isCurrent() && this.connection?.requestKeyframe(),
      presented: (captureTime, atMs) => {
        if (!isCurrent()) return;
        this.hasPicture = true;
        this.frames.add(this.connection?.clock.latencyMs(captureTime, atMs * 1000));
        if (this.phase === 'waiting') this.streamingStarted();
      },
      videoSize: (width, height) => isCurrent() && this.surface.setContentSize(width, height),
      fatal: (error) => isCurrent() && this.onPipelineFatal(error),
      needsGesture: () => {
        if (!isCurrent()) return;
        this.screens.status(t('notice.tapToStart'), {
          translucent: true,
          actions: [
            {
              label: t('action.start'),
              primary: true,
              run: () => {
                this.pipeline?.resume();
                this.screens.hide();
              },
            },
          ],
        });
      },
    };
  }

  private streamingStarted(): void {
    this.phase = 'streaming';
    this.screens.hide();
    this.toolbar.setEnabled(true);
    if (this.pipeline?.kind === 'mse' && !window.isSecureContext && !this.insecureNoticeShown) {
      this.insecureNoticeShown = true;
      this.notice.show(t('notice.insecure'), { durationMs: 15_000 });
    }
  }

  private onPipelineFatal(error: unknown): void {
    console.warn('Video pipeline failed', error);
    if (this.pipeline?.kind === 'webcodecs' && MsePipeline.isAvailable()) {
      this.webCodecsFailed = true;
      const pipeline = this.ensurePipeline();
      if (this.config) pipeline.configure(this.config);
      this.connection?.requestKeyframe();
      return;
    }
    this.fail(t('error.decoder'), undefined, false);
  }

  private frameStats(seconds: number) {
    const pipeline = this.pipeline?.takeStats() ?? { decodeMs: 0, droppedFrames: 0 };
    const frames = this.frames.take(seconds);
    return {
      fps: pipeline.presentedFrames !== undefined ? pipeline.presentedFrames / seconds : frames.fps,
      decodeMs: pipeline.decodeMs,
      droppedFrames: pipeline.droppedFrames,
      ...(frames.latencyMs !== undefined ? { latencyMs: frames.latencyMs } : {}),
    };
  }

  // MARK: Environment

  private readonly onResize = () => {
    if (this.phase !== 'waiting' && this.phase !== 'streaming') return;
    clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout(() => {
      if (this.phase !== 'waiting' && this.phase !== 'streaming') return;
      // An on-screen keyboard shrinks the viewport; that is not a new display size.
      if (!this.helloSize || this.keyboard.softKeyboardOpen) return;
      if (sizeChangedSubstantially(this.helloSize, currentDisplaySize())) this.connect(true);
    }, RESIZE_DEBOUNCE_MS);
  };

  private readonly onVisibilityChange = () => {
    if (document.visibilityState !== 'visible') return;
    if (this.phase === 'streaming' || this.phase === 'waiting') this.pipeline?.refresh();
    else if (this.phase === 'reconnecting') this.connect();
  };
}
