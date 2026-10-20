import { describe, expect, it } from 'vitest';
import {
  decodeJSON,
  encodeAck,
  encodeJSON,
  encodeKey,
  encodeMessage,
  encodePing,
  encodePointer,
  encodePong,
  encodeScroll,
  encodeText,
  encodeVideo,
  HEADER_SIZE,
  KeyAction,
  MAX_PAYLOAD_SIZE,
  MessageDecoder,
  MessageType,
  Modifier,
  parsePing,
  parsePong,
  parseVideo,
  PointerAction,
  PointerButton,
  PointerTool,
  ProtocolError,
  ScrollPhase,
  ScrollUnit,
} from '../src/protocol';

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join(' ');
}

function f32(value: number): string {
  const bytes = new Uint8Array(4);
  new DataView(bytes.buffer).setFloat32(0, value);
  return hex(bytes);
}

function drain(decoder: MessageDecoder) {
  const out = [];
  for (let message = decoder.next(); message; message = decoder.next()) out.push(message);
  return out;
}

describe('framing', () => {
  it('writes the 6-byte header: type, flags, big-endian length', () => {
    const bytes = encodeMessage(MessageType.video, new Uint8Array([9, 8, 7]), 0x01);
    expect(hex(bytes)).toBe('11 01 00 00 00 03 09 08 07');
  });

  it('parses messages split at every byte boundary', () => {
    const stream = new Uint8Array([
      ...encodeMessage(MessageType.ping, new Uint8Array(8).fill(1)),
      ...encodeJSON(MessageType.bye, { reason: 'user' }),
      ...encodeMessage(MessageType.keyframeRequest),
    ]);
    for (let split = 1; split < stream.length; split++) {
      const decoder = new MessageDecoder();
      decoder.append(stream.subarray(0, split));
      const first = drain(decoder);
      decoder.append(stream.subarray(split));
      const messages = [...first, ...drain(decoder)];
      expect(messages.map((m) => m.type)).toEqual([MessageType.ping, MessageType.bye, MessageType.keyframeRequest]);
      expect(decodeJSON<{ reason: string }>(messages[1]!).reason).toBe('user');
      expect(messages[2]!.payload.length).toBe(0);
    }
  });

  it('parses byte-by-byte input', () => {
    const stream = encodeJSON(MessageType.welcome, { hostName: 'Mac' });
    const decoder = new MessageDecoder();
    const messages = [];
    for (const byte of stream) {
      decoder.append(new Uint8Array([byte]));
      messages.push(...drain(decoder));
    }
    expect(messages).toHaveLength(1);
    expect(decodeJSON<{ hostName: string }>(messages[0]!).hostName).toBe('Mac');
  });

  it('skips unknown message types', () => {
    const unknown = new Uint8Array([0x6e, 0x00, 0x00, 0x00, 0x00, 0x02, 0xaa, 0xbb]);
    const decoder = new MessageDecoder();
    decoder.append(new Uint8Array([...unknown, ...encodeAck(5), ...unknown]));
    const messages = drain(decoder);
    expect(messages.map((m) => m.type)).toEqual([MessageType.ack]);
  });

  it('rejects payloads over 16 MiB', () => {
    const header = new Uint8Array(HEADER_SIZE);
    const view = new DataView(header.buffer);
    view.setUint8(0, MessageType.video);
    view.setUint32(2, MAX_PAYLOAD_SIZE + 1);
    const decoder = new MessageDecoder();
    decoder.append(header);
    expect(() => decoder.next()).toThrow(ProtocolError);
  });
});

describe('HELLO', () => {
  it('is a JSON payload behind a HELLO header', () => {
    const hello = {
      protocol: 1,
      deviceId: 'abc',
      deviceName: 'Chrome on Windows',
      platform: 'web',
      appVersion: '0.1.0',
      display: { width: 2560, height: 1600, dpi: 192, refreshRate: 60 },
      codecs: ['h264'],
      locale: 'tr-TR',
    };
    const bytes = encodeJSON(MessageType.hello, hello);
    const json = new TextEncoder().encode(JSON.stringify(hello));
    expect(bytes[0]).toBe(0x01);
    expect(bytes[1]).toBe(0x00);
    expect(new DataView(bytes.buffer).getUint32(2)).toBe(json.length);
    expect(bytes.subarray(HEADER_SIZE)).toEqual(json);
    const decoder = new MessageDecoder();
    decoder.append(bytes);
    expect(decodeJSON(decoder.next()!)).toEqual(hello);
  });
});

describe('INPUT layouts', () => {
  it('POINTER is 17 bytes', () => {
    const bytes = encodePointer(PointerAction.down, PointerButton.right, PointerTool.stylus, 0.25, 0.75, 0.5);
    expect(hex(bytes.subarray(0, HEADER_SIZE))).toBe('20 00 00 00 00 11');
    const payload = bytes.subarray(HEADER_SIZE);
    expect(payload.length).toBe(17);
    expect(hex(payload)).toBe(`01 01 01 02 00 ${f32(0.25)} ${f32(0.75)} ${f32(0.5)}`);
  });

  it('SCROLL is 21 bytes', () => {
    const bytes = encodeScroll(ScrollPhase.momentum, ScrollUnit.lines, 0.5, 0.125, -1.5, 3);
    const payload = bytes.subarray(HEADER_SIZE);
    expect(payload.length).toBe(21);
    expect(hex(payload)).toBe(`02 04 01 00 00 ${f32(0.5)} ${f32(0.125)} ${f32(-1.5)} ${f32(3)}`);
  });

  it('KEY is 7 bytes with big-endian usage and modifiers', () => {
    const payload = encodeKey(KeyAction.up, 0x28, Modifier.shift | Modifier.command).subarray(HEADER_SIZE);
    expect(payload.length).toBe(7);
    expect(hex(payload)).toBe('03 02 00 00 28 00 09');
  });

  it('TEXT is the kind byte followed by UTF-8', () => {
    const payload = encodeText('ğü€').subarray(HEADER_SIZE);
    expect(hex(payload)).toBe('04 c4 9f c3 bc e2 82 ac');
  });
});

describe('binary messages', () => {
  it('ACK carries a u32 sequence number', () => {
    expect(hex(encodeAck(0x01020304))).toBe('13 00 00 00 00 04 01 02 03 04');
  });

  it('PING / PONG carry u64 microseconds beyond 32 bits', () => {
    const time = 987_654_321_012_345;
    const ping = encodePing(time);
    expect(ping.length).toBe(HEADER_SIZE + 8);
    const decoder = new MessageDecoder();
    decoder.append(ping);
    expect(parsePing(decoder.next()!)).toBe(time);

    decoder.append(encodePong({ echoedTime: time, responderTime: time + 1 }));
    expect(parsePong(decoder.next()!)).toEqual({ echoedTime: time, responderTime: time + 1 });
  });

  it('VIDEO: seq, capture time, keyframe flag and Annex-B data', () => {
    const data = new Uint8Array([0, 0, 0, 1, 0x65, 0x88]);
    const bytes = encodeVideo({ seq: 42, captureTime: 123_456_789_000, keyframe: true, data });
    expect(bytes[1]).toBe(0x01);
    const decoder = new MessageDecoder();
    decoder.append(bytes);
    const frame = parseVideo(decoder.next()!);
    expect(frame).toEqual({ seq: 42, captureTime: 123_456_789_000, keyframe: true, data });
  });
});
