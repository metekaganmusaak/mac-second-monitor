import {
  type Bye,
  type Bytes,
  type ClientStats,
  decodeJSON,
  encodeAck,
  encodeJSON,
  encodeMessage,
  encodePing,
  encodePong,
  type ErrorInfo,
  type Hello,
  type Message,
  MessageDecoder,
  MessageType,
  type PairRequest,
  parsePing,
  parsePong,
  parseVideo,
  type StreamConfig,
  type VideoMessage,
  type Welcome,
} from './protocol';

export type CloseReason =
  | { kind: 'error'; code: string; message: string }
  | { kind: 'bye'; reason: string }
  /** The socket failed, closed without BYE, or the host went silent. */
  | { kind: 'network'; everOpened: boolean };

export interface ConnectionHandlers {
  welcome(welcome: Welcome): void;
  pairRequest(request: PairRequest): void;
  config(config: StreamConfig): void;
  video(frame: VideoMessage): void;
  stats(stats: ClientStats): void;
  closed(reason: CloseReason): void;
}

/** Per-second numbers the decoder side contributes to STATS. */
export interface FrameStatsProvider {
  (seconds: number): { fps: number; decodeMs: number; latencyMs?: number; droppedFrames: number };
}

const CONNECT_TIMEOUT_MS = 6000;
const SILENCE_TIMEOUT_MS = 5000;
const TICK_MS = 1000;

/** Microseconds on this page's monotonic clock (not comparable with the host clock). */
export function nowMicros(): number {
  return Math.round(performance.now() * 1000);
}

/**
 * Host clock estimate from PING / PONG (docs/PROTOCOL.md): keeps the offset of the sample
 * with the lowest round trip, which has the least queueing and therefore the least error.
 */
export class ClockSync {
  rttMicros: number | undefined;
  /** hostClock − clientClock, µs. */
  offsetMicros: number | undefined;
  private bestRtt = Number.POSITIVE_INFINITY;

  pong(echoedTime: number, responderTime: number, now: number): void {
    if (now < echoedTime) return;
    const rtt = now - echoedTime;
    this.rttMicros = rtt;
    if (rtt <= this.bestRtt) {
      this.bestRtt = rtt;
      this.offsetMicros = responderTime - (echoedTime + rtt / 2);
    }
  }

  /** Slowly forgets the best sample so the offset can follow clock drift. */
  age(): void {
    if (Number.isFinite(this.bestRtt)) this.bestRtt += 200;
  }

  /** Capture-to-`atMicros` latency of a frame in ms, once an offset is known. */
  latencyMs(captureTime: number, atMicros: number): number | undefined {
    if (this.offsetMicros === undefined) return undefined;
    return (atMicros + this.offsetMicros - captureTime) / 1000;
  }
}

/** One WebSocket session with the host: handshake, keep-alive, clock sync and STATS. */
export class Connection {
  readonly clock = new ClockSync();
  private readonly socket: WebSocket;
  private readonly decoder = new MessageDecoder();
  private timer: ReturnType<typeof setInterval> | undefined;
  private connectTimer: ReturnType<typeof setTimeout> | undefined;
  private finished = false;
  private opened = false;
  private lastReceived = performance.now();
  private windowStart = performance.now();
  private windowBytes = 0;

  constructor(
    url: string,
    private readonly hello: Hello,
    private readonly handlers: ConnectionHandlers,
    private readonly frameStats: FrameStatsProvider,
  ) {
    this.socket = new WebSocket(url);
    this.socket.binaryType = 'arraybuffer';
    this.socket.addEventListener('open', this.onOpen);
    this.socket.addEventListener('message', this.onMessage);
    this.socket.addEventListener('close', this.onClose);
    this.connectTimer = setTimeout(() => {
      this.fail({ kind: 'network', everOpened: false });
      this.socket.close();
    }, CONNECT_TIMEOUT_MS);
  }

  get isOpen(): boolean {
    return this.opened && !this.finished;
  }

  sendPairingCode(code: string): void {
    this.send(encodeJSON(MessageType.pair, { code }));
  }

  acknowledge(seq: number): void {
    this.send(encodeAck(seq));
  }

  requestKeyframe(): void {
    this.send(encodeMessage(MessageType.keyframeRequest));
  }

  send(bytes: Bytes): void {
    if (this.isOpen && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(bytes);
    }
  }

  /** Ends the session from this side. Handlers are not called. */
  close(reason = 'user'): void {
    if (this.finished) return;
    const bye: Bye = { reason };
    this.send(encodeJSON(MessageType.bye, bye));
    this.finish();
    this.socket.close(1000);
  }

  private readonly onOpen = () => {
    if (this.finished) return;
    clearTimeout(this.connectTimer);
    this.opened = true;
    this.lastReceived = performance.now();
    this.windowStart = performance.now();
    this.send(encodeJSON(MessageType.hello, this.hello));
    this.ping();
    this.timer = setInterval(this.tick, TICK_MS);
  };

  private readonly onMessage = (event: MessageEvent) => {
    if (this.finished || !(event.data instanceof ArrayBuffer)) return;
    this.lastReceived = performance.now();
    this.windowBytes += event.data.byteLength;
    this.decoder.append(new Uint8Array(event.data));
    try {
      for (let message = this.decoder.next(); message; message = this.decoder.next()) {
        this.handle(message);
        if (this.finished) return;
      }
    } catch (error) {
      console.warn('Protocol error', error);
      this.fail({ kind: 'network', everOpened: true });
      this.socket.close();
    }
  };

  private readonly onClose = () => {
    this.fail({ kind: 'network', everOpened: this.opened });
  };

  private handle(message: Message): void {
    switch (message.type) {
      case MessageType.welcome:
        this.handlers.welcome(decodeJSON<Welcome>(message));
        break;
      case MessageType.pairRequest:
        this.handlers.pairRequest(decodeJSON<PairRequest>(message));
        break;
      case MessageType.error: {
        const info = decodeJSON<ErrorInfo>(message);
        this.fail({ kind: 'error', code: info.code, message: info.message });
        this.socket.close();
        break;
      }
      case MessageType.config:
        this.handlers.config(decodeJSON<StreamConfig>(message));
        break;
      case MessageType.video:
        this.handlers.video(parseVideo(message));
        break;
      case MessageType.ping:
        this.send(encodePong({ echoedTime: parsePing(message), responderTime: nowMicros() }));
        break;
      case MessageType.pong: {
        const pong = parsePong(message);
        this.clock.pong(pong.echoedTime, pong.responderTime, nowMicros());
        break;
      }
      case MessageType.bye: {
        let reason = 'bye';
        try {
          reason = decodeJSON<Bye>(message).reason;
        } catch {
          // An unreadable BYE is still a BYE.
        }
        this.fail({ kind: 'bye', reason });
        this.socket.close();
        break;
      }
      default:
        // Client-to-host types; ignore.
        break;
    }
  }

  private ping(): void {
    this.send(encodePing(nowMicros()));
  }

  private readonly tick = () => {
    const now = performance.now();
    if (now - this.lastReceived > SILENCE_TIMEOUT_MS) {
      // A dropped Wi-Fi link can leave the socket open for a long time.
      this.fail({ kind: 'network', everOpened: true });
      this.socket.close();
      return;
    }
    this.ping();
    this.clock.age();

    const seconds = (now - this.windowStart) / 1000;
    if (seconds <= 0) return;
    const frames = this.frameStats(seconds);
    const stats: ClientStats = {
      fps: round(frames.fps, 1),
      decodeMs: round(frames.decodeMs, 2),
      droppedFrames: frames.droppedFrames,
      bitrateKbps: round((this.windowBytes * 8) / seconds / 1000, 0),
    };
    if (frames.latencyMs !== undefined) stats.latencyMs = round(frames.latencyMs, 1);
    if (this.clock.rttMicros !== undefined) stats.rttMs = round(this.clock.rttMicros / 1000, 2);
    this.send(encodeJSON(MessageType.stats, stats));
    this.handlers.stats(stats);
    this.windowStart = now;
    this.windowBytes = 0;
  };

  private fail(reason: CloseReason): void {
    if (this.finished) return;
    this.finish();
    this.handlers.closed(reason);
  }

  private finish(): void {
    this.finished = true;
    clearTimeout(this.connectTimer);
    clearInterval(this.timer);
    this.socket.removeEventListener('message', this.onMessage);
  }
}

function round(value: number, digits: number): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}
