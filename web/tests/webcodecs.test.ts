import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { PipelineCallbacks } from '../src/decoder/types';
import type { StreamConfig, VideoMessage } from '../src/protocol';

// Minimal stand-ins for the browser APIs the pipeline touches.
class FakeDecoder {
  static instances: FakeDecoder[] = [];
  static async isConfigSupported(config: unknown) {
    return { supported: true, config };
  }
  state = 'unconfigured';
  decodeQueueSize = 0;
  config: Record<string, unknown> | null = null;
  readonly chunks: Array<{ type: string; timestamp: number }> = [];
  private readonly listeners = new Map<string, () => void>();

  constructor(readonly init: { output(frame: unknown): void; error(error: unknown): void }) {
    FakeDecoder.instances.push(this);
  }
  configure(config: Record<string, unknown>) {
    this.config = config;
    this.state = 'configured';
  }
  decode(chunk: { type: string; timestamp: number }) {
    this.chunks.push(chunk);
  }
  close() {
    this.state = 'closed';
  }
  addEventListener(type: string, listener: () => void) {
    this.listeners.set(type, listener);
  }
  removeEventListener(type: string) {
    this.listeners.delete(type);
  }
  dequeue(size: number) {
    this.decodeQueueSize = size;
    this.listeners.get('dequeue')?.();
  }
  fail() {
    this.state = 'closed';
    this.init.error(new Error('decode error'));
  }
}

class FakeChunk {
  constructor(init: object) {
    Object.assign(this, init);
  }
}

const globals = globalThis as Record<string, unknown>;
const saved: Record<string, unknown> = {};

beforeAll(() => {
  for (const name of ['VideoDecoder', 'EncodedVideoChunk', 'document', 'window', 'requestAnimationFrame', 'cancelAnimationFrame']) {
    saved[name] = globals[name];
  }
  globals.VideoDecoder = FakeDecoder;
  globals.EncodedVideoChunk = FakeChunk;
  globals.window = { isSecureContext: true };
  globals.document = {
    visibilityState: 'visible',
    createElement: () => ({ getContext: () => ({ drawImage() {} }), remove() {}, width: 0, height: 0 }),
  };
  globals.requestAnimationFrame = () => 1;
  globals.cancelAnimationFrame = () => undefined;
});

afterAll(() => {
  for (const [name, value] of Object.entries(saved)) globals[name] = value;
});

const config: StreamConfig = { codec: 'h264', codecString: 'avc1.640C33', width: 2560, height: 1600, fps: 60, mode: 'extend' };
const frame = (seq: number, keyframe = false): VideoMessage => ({
  seq,
  captureTime: 1_000_000 + seq * 16_667,
  keyframe,
  data: new Uint8Array([0, 0, 0, 1, keyframe ? 0x65 : 0x41, 0x88]),
});
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('WebCodecsPipeline', () => {
  let acks: number[];
  let keyframeRequests: number;
  let callbacks: PipelineCallbacks;

  beforeEach(() => {
    FakeDecoder.instances = [];
    acks = [];
    keyframeRequests = 0;
    callbacks = {
      ack: (seq) => acks.push(seq),
      requestKeyframe: () => keyframeRequests++,
      presented: () => undefined,
      videoSize: () => undefined,
      fatal: (error) => {
        throw error;
      },
      needsGesture: () => undefined,
    };
  });

  async function configured() {
    const { WebCodecsPipeline } = await import('../src/decoder/webcodecs');
    const pipeline = new WebCodecsPipeline(callbacks);
    pipeline.configure(config);
    await settle();
    return { pipeline, decoder: FakeDecoder.instances.at(-1)! };
  }

  it('configures a low-latency, hardware-preferred Annex-B decoder', async () => {
    const { decoder } = await configured();
    expect(decoder.config).toMatchObject({ codec: 'avc1.640C33', optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware' });
    expect(decoder.config).not.toHaveProperty('description');
  });

  it('acks every frame and drops deltas until a keyframe', async () => {
    const { pipeline, decoder } = await configured();
    const requestsBefore = keyframeRequests;
    pipeline.push(frame(0));
    expect(decoder.chunks).toHaveLength(0);
    expect(keyframeRequests).toBe(requestsBefore + 1);
    pipeline.push(frame(1, true));
    pipeline.push(frame(2));
    expect(decoder.chunks.map((chunk) => chunk.type)).toEqual(['key', 'delta']);
    expect(acks).toEqual([0, 1, 2]);
  });

  it('feeds frames that arrive while the decoder is being configured', async () => {
    const { WebCodecsPipeline } = await import('../src/decoder/webcodecs');
    const pipeline = new WebCodecsPipeline(callbacks);
    pipeline.configure(config);
    pipeline.push(frame(0, true));
    pipeline.push(frame(1));
    expect(acks).toEqual([0, 1]);
    await settle();
    expect(FakeDecoder.instances.at(-1)!.chunks.map((chunk) => chunk.type)).toEqual(['key', 'delta']);
  });

  it('holds acks while the decoder queue is deep', async () => {
    const { pipeline, decoder } = await configured();
    pipeline.push(frame(0, true));
    decoder.decodeQueueSize = 3;
    pipeline.push(frame(1));
    expect(acks).toEqual([0]);
    decoder.dequeue(1);
    expect(acks).toEqual([0, 1]);
  });

  it('recreates the decoder and asks for a keyframe after an error', async () => {
    const { pipeline, decoder } = await configured();
    pipeline.push(frame(0, true));
    const requestsBefore = keyframeRequests;
    decoder.fail();
    const replacement = FakeDecoder.instances.at(-1)!;
    expect(replacement).not.toBe(decoder);
    expect(replacement.state).toBe('configured');
    expect(keyframeRequests).toBe(requestsBefore + 1);
    pipeline.push(frame(1));
    expect(replacement.chunks).toHaveLength(0);
    pipeline.push(frame(2, true));
    expect(replacement.chunks.map((chunk) => chunk.type)).toEqual(['key']);
  });
});
