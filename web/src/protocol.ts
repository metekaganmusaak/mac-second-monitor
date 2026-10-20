// Wire protocol v1 (docs/PROTOCOL.md): framing, message payloads and INPUT encoding.

export const PROTOCOL_VERSION = 1;
export const HEADER_SIZE = 6;
export const MAX_PAYLOAD_SIZE = 16 * 1024 * 1024;
export const KEYFRAME_FLAG = 0x01;

export const MessageType = {
  hello: 0x01,
  welcome: 0x02,
  pairRequest: 0x03,
  pair: 0x04,
  error: 0x05,
  config: 0x10,
  video: 0x11,
  keyframeRequest: 0x12,
  ack: 0x13,
  input: 0x20,
  ping: 0x30,
  pong: 0x31,
  stats: 0x32,
  bye: 0x7f,
} as const;
export type MessageType = (typeof MessageType)[keyof typeof MessageType];

const knownTypes = new Set<number>(Object.values(MessageType));

export interface Message {
  type: MessageType;
  flags: number;
  payload: Uint8Array;
}

export class ProtocolError extends Error {}

/** Bytes backed by a plain ArrayBuffer (what WebSocket.send and appendBuffer accept). */
export type Bytes = Uint8Array<ArrayBuffer>;

// MARK: JSON payloads

export interface DisplayInfo {
  width: number;
  height: number;
  dpi: number;
  refreshRate: number;
}

export interface Hello {
  protocol: number;
  deviceId: string;
  deviceName: string;
  platform: 'web';
  appVersion: string;
  display: DisplayInfo;
  codecs: string[];
  locale?: string;
  token?: string;
}

export interface Welcome {
  protocol: number;
  hostName: string;
  sessionId: string;
  transport: string;
  token?: string;
}

export interface PairRequest {
  codeLength: number;
  attemptsLeft: number;
  retry: boolean;
}

export interface ErrorInfo {
  code: string;
  message: string;
}

export interface StreamConfig {
  codec: string;
  codecString: string;
  width: number;
  height: number;
  fps: number;
  mode: string;
}

export interface ClientStats {
  fps: number;
  decodeMs: number;
  latencyMs?: number;
  rttMs?: number;
  droppedFrames: number;
  bitrateKbps: number;
}

export interface Bye {
  reason: string;
}

// MARK: Framing

export function encodeMessage(type: MessageType, payload: Uint8Array = new Uint8Array(0), flags = 0): Bytes {
  const out = new Uint8Array(HEADER_SIZE + payload.length);
  const view = new DataView(out.buffer);
  view.setUint8(0, type);
  view.setUint8(1, flags);
  view.setUint32(2, payload.length);
  out.set(payload, HEADER_SIZE);
  return out;
}

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder();

export function encodeJSON(type: MessageType, value: unknown): Bytes {
  return encodeMessage(type, textEncoder.encode(JSON.stringify(value)));
}

export function decodeJSON<T>(message: Message): T {
  try {
    return JSON.parse(textDecoder.decode(message.payload)) as T;
  } catch (error) {
    throw new ProtocolError(`invalid JSON in message 0x${message.type.toString(16)}: ${String(error)}`);
  }
}

/**
 * Incremental parser for a stream of framed messages. Unknown message types are skipped so
 * newer hosts keep working with this client.
 */
export class MessageDecoder {
  private buffer = new Uint8Array(0);
  private offset = 0;

  append(chunk: Uint8Array): void {
    const available = this.buffer.length - this.offset;
    if (available === 0) {
      this.buffer = chunk.slice();
      this.offset = 0;
      return;
    }
    const merged = new Uint8Array(available + chunk.length);
    merged.set(this.buffer.subarray(this.offset));
    merged.set(chunk, available);
    this.buffer = merged;
    this.offset = 0;
  }

  /** Returns the next complete message, or null when more bytes are needed. */
  next(): Message | null {
    for (;;) {
      const available = this.buffer.length - this.offset;
      if (available < HEADER_SIZE) return null;
      const view = new DataView(this.buffer.buffer, this.buffer.byteOffset + this.offset, HEADER_SIZE);
      const type = view.getUint8(0);
      const flags = view.getUint8(1);
      const length = view.getUint32(2);
      if (length > MAX_PAYLOAD_SIZE) {
        throw new ProtocolError(`payload too large: ${length}`);
      }
      if (available < HEADER_SIZE + length) return null;
      const start = this.offset + HEADER_SIZE;
      const payload = this.buffer.subarray(start, start + length);
      this.offset = start + length;
      if (knownTypes.has(type)) {
        return { type: type as MessageType, flags, payload };
      }
    }
  }
}

// MARK: Binary payloads

// u64 values (µs clocks) stay below 2^53, so two u32 halves are exact without BigInt.
function setU64(view: DataView, offset: number, value: number): void {
  const v = Math.max(0, Math.floor(value));
  view.setUint32(offset, Math.floor(v / 0x1_0000_0000));
  view.setUint32(offset + 4, v % 0x1_0000_0000);
}

function getU64(view: DataView, offset: number): number {
  return view.getUint32(offset) * 0x1_0000_0000 + view.getUint32(offset + 4);
}

function viewOf(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

export interface VideoMessage {
  seq: number;
  /** µs, host clock. */
  captureTime: number;
  keyframe: boolean;
  /** One access unit, Annex-B. */
  data: Uint8Array;
}

export function parseVideo(message: Message): VideoMessage {
  if (message.payload.length < 12) throw new ProtocolError('truncated VIDEO');
  const view = viewOf(message.payload);
  return {
    seq: view.getUint32(0),
    captureTime: getU64(view, 4),
    keyframe: (message.flags & KEYFRAME_FLAG) !== 0,
    data: message.payload.subarray(12),
  };
}

export function encodeVideo(frame: VideoMessage): Bytes {
  const payload = new Uint8Array(12 + frame.data.length);
  const view = viewOf(payload);
  view.setUint32(0, frame.seq);
  setU64(view, 4, frame.captureTime);
  payload.set(frame.data, 12);
  return encodeMessage(MessageType.video, payload, frame.keyframe ? KEYFRAME_FLAG : 0);
}

export function encodeAck(seq: number): Bytes {
  const payload = new Uint8Array(4);
  viewOf(payload).setUint32(0, seq >>> 0);
  return encodeMessage(MessageType.ack, payload);
}

export function encodePing(time: number): Bytes {
  const payload = new Uint8Array(8);
  setU64(viewOf(payload), 0, time);
  return encodeMessage(MessageType.ping, payload);
}

export function parsePing(message: Message): number {
  if (message.payload.length < 8) throw new ProtocolError('truncated PING');
  return getU64(viewOf(message.payload), 0);
}

export interface Pong {
  echoedTime: number;
  responderTime: number;
}

export function encodePong(pong: Pong): Bytes {
  const payload = new Uint8Array(16);
  const view = viewOf(payload);
  setU64(view, 0, pong.echoedTime);
  setU64(view, 8, pong.responderTime);
  return encodeMessage(MessageType.pong, payload);
}

export function parsePong(message: Message): Pong {
  if (message.payload.length < 16) throw new ProtocolError('truncated PONG');
  const view = viewOf(message.payload);
  return { echoedTime: getU64(view, 0), responderTime: getU64(view, 8) };
}

// MARK: INPUT

export const PointerAction = { move: 0, down: 1, up: 2, cancel: 3 } as const;
export type PointerAction = (typeof PointerAction)[keyof typeof PointerAction];

export const PointerButton = { left: 0, right: 1, middle: 2 } as const;
export type PointerButton = (typeof PointerButton)[keyof typeof PointerButton];

export const PointerTool = { mouse: 0, finger: 1, stylus: 2 } as const;
export type PointerTool = (typeof PointerTool)[keyof typeof PointerTool];

export const ScrollPhase = { none: 0, began: 1, changed: 2, ended: 3, momentum: 4, momentumEnded: 5 } as const;
export type ScrollPhase = (typeof ScrollPhase)[keyof typeof ScrollPhase];

export const ScrollUnit = { normalized: 0, lines: 1 } as const;
export type ScrollUnit = (typeof ScrollUnit)[keyof typeof ScrollUnit];

export const KeyAction = { down: 1, up: 2 } as const;
export type KeyAction = (typeof KeyAction)[keyof typeof KeyAction];

export const Modifier = {
  shift: 1 << 0,
  control: 1 << 1,
  option: 1 << 2,
  command: 1 << 3,
  capsLock: 1 << 4,
  function: 1 << 5,
} as const;

const InputKind = { pointer: 0x01, scroll: 0x02, key: 0x03, text: 0x04 } as const;

export function encodePointer(
  action: PointerAction,
  button: PointerButton,
  tool: PointerTool,
  x: number,
  y: number,
  pressure = 1,
): Bytes {
  const payload = new Uint8Array(17);
  const view = viewOf(payload);
  view.setUint8(0, InputKind.pointer);
  view.setUint8(1, action);
  view.setUint8(2, button);
  view.setUint8(3, tool);
  view.setUint8(4, 0);
  view.setFloat32(5, x);
  view.setFloat32(9, y);
  view.setFloat32(13, pressure);
  return encodeMessage(MessageType.input, payload);
}

export function encodeScroll(
  phase: ScrollPhase,
  unit: ScrollUnit,
  x: number,
  y: number,
  dx: number,
  dy: number,
): Bytes {
  const payload = new Uint8Array(21);
  const view = viewOf(payload);
  view.setUint8(0, InputKind.scroll);
  view.setUint8(1, phase);
  view.setUint8(2, unit);
  view.setUint16(3, 0);
  view.setFloat32(5, x);
  view.setFloat32(9, y);
  view.setFloat32(13, dx);
  view.setFloat32(17, dy);
  return encodeMessage(MessageType.input, payload);
}

export function encodeKey(action: KeyAction, usage: number, modifiers: number): Bytes {
  const payload = new Uint8Array(7);
  const view = viewOf(payload);
  view.setUint8(0, InputKind.key);
  view.setUint8(1, action);
  view.setUint8(2, 0);
  view.setUint16(3, usage);
  view.setUint16(5, modifiers);
  return encodeMessage(MessageType.input, payload);
}

export function encodeText(text: string): Bytes {
  const utf8 = textEncoder.encode(text);
  const payload = new Uint8Array(1 + utf8.length);
  payload[0] = InputKind.text;
  payload.set(utf8, 1);
  return encodeMessage(MessageType.input, payload);
}
