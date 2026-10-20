import { describe, expect, it } from 'vitest';
import { initSegment, mediaSegment } from '../src/video/fmp4';
import { pps, sps640x400 } from './fixtures';

interface Box {
  type: string;
  start: number;
  size: number;
  body: Uint8Array;
  children: Box[];
}

const containers = new Set(['moov', 'trak', 'mdia', 'minf', 'dinf', 'stbl', 'mvex', 'moof', 'traf']);
/** Boxes whose children follow a fixed-size header. */
const headerSizes: Record<string, number> = { stsd: 8, dref: 8, avc1: 78 };

function parse(data: Uint8Array, offset = 0, end = data.length): Box[] {
  const boxes: Box[] = [];
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  while (offset < end) {
    const size = view.getUint32(offset);
    const type = String.fromCharCode(...data.subarray(offset + 4, offset + 8));
    expect(size).toBeGreaterThanOrEqual(8);
    expect(offset + size).toBeLessThanOrEqual(end);
    const body = data.subarray(offset + 8, offset + size);
    let children: Box[] = [];
    if (containers.has(type)) children = parse(data, offset + 8, offset + size);
    else if (type in headerSizes) children = parse(data, offset + 8 + headerSizes[type]!, offset + size);
    boxes.push({ type, start: offset, size, body, children });
    offset += size;
  }
  expect(offset).toBe(end);
  return boxes;
}

function find(boxes: Box[], path: string): Box {
  let current: Box | undefined;
  let list = boxes;
  for (const type of path.split('/')) {
    current = list.find((box) => box.type === type);
    if (!current) throw new Error(`missing ${path}`);
    list = current.children;
  }
  return current!;
}

function u32(box: Box, offset: number): number {
  return new DataView(box.body.buffer, box.body.byteOffset).getUint32(offset);
}

describe('init segment', () => {
  const boxes = parse(initSegment({ sps: sps640x400, pps, timescale: 90_000 }));

  it('is ftyp + moov with one video track and fragment defaults', () => {
    expect(boxes.map((box) => box.type)).toEqual(['ftyp', 'moov']);
    const moov = find(boxes, 'moov');
    expect(moov.children.map((box) => box.type)).toEqual(['mvhd', 'trak', 'mvex']);
    expect(find(boxes, 'moov/trak').children.map((box) => box.type)).toEqual(['tkhd', 'mdia']);
    expect(find(boxes, 'moov/trak/mdia').children.map((box) => box.type)).toEqual(['mdhd', 'hdlr', 'minf']);
    expect(find(boxes, 'moov/trak/mdia/minf/stbl').children.map((box) => box.type)).toEqual(['stsd', 'stts', 'stsc', 'stsz', 'stco']);
    expect(find(boxes, 'moov/mvex/trex')).toBeDefined();
    expect(String.fromCharCode(...find(boxes, 'moov/trak/mdia/hdlr').body.subarray(8, 12))).toBe('vide');
  });

  it('has a zero duration (live) and the timescale', () => {
    const mvhd = find(boxes, 'moov/mvhd');
    expect(u32(mvhd, 12)).toBe(90_000); // version/flags, creation, modification, timescale
    expect(u32(mvhd, 16)).toBe(0);
    expect(u32(find(boxes, 'moov/trak/mdia/mdhd'), 12)).toBe(90_000);
  });

  it('stores the picture size in tkhd and avc1', () => {
    const tkhd = find(boxes, 'moov/trak/tkhd');
    expect(u32(tkhd, 76) / 0x10000).toBe(640);
    expect(u32(tkhd, 80) / 0x10000).toBe(400);
    const avc1 = find(boxes, 'moov/trak/mdia/minf/stbl/stsd/avc1');
    const view = new DataView(avc1.body.buffer, avc1.body.byteOffset);
    expect([view.getUint16(24), view.getUint16(26)]).toEqual([640, 400]);
  });

  it('carries SPS and PPS in avcC', () => {
    const avcC = find(boxes, 'moov/trak/mdia/minf/stbl/stsd/avc1/avcC').body;
    expect(Array.from(avcC.subarray(0, 6))).toEqual([1, 0x64, 0x0c, 0x1f, 0xff, 0xe1]);
    const spsLength = (avcC[6]! << 8) | avcC[7]!;
    expect(avcC.subarray(8, 8 + spsLength)).toEqual(sps640x400);
    const ppsAt = 8 + spsLength;
    expect(avcC[ppsAt]).toBe(1);
    expect(avcC.subarray(ppsAt + 3, ppsAt + 3 + pps.length)).toEqual(pps);
    // High profile extension: 4:2:0, 8-bit, no SPS extensions.
    expect(Array.from(avcC.subarray(ppsAt + 3 + pps.length))).toEqual([0xfd, 0xf8, 0xf8, 0x00]);
  });
});

describe('media segment', () => {
  const sample = new Uint8Array([0, 0, 0, 3, 0x65, 0x11, 0x22]);
  const segment = mediaSegment(7, { data: sample, decodeTime: 2 ** 33 + 1500, duration: 1500, keyframe: true });
  const boxes = parse(segment);

  it('is moof (mfhd, traf: tfhd, tfdt, trun) + mdat', () => {
    expect(boxes.map((box) => box.type)).toEqual(['moof', 'mdat']);
    expect(find(boxes, 'moof').children.map((box) => box.type)).toEqual(['mfhd', 'traf']);
    expect(find(boxes, 'moof/traf').children.map((box) => box.type)).toEqual(['tfhd', 'tfdt', 'trun']);
    expect(u32(find(boxes, 'moof/mfhd'), 4)).toBe(7);
  });

  it('uses a 64-bit tfdt', () => {
    const tfdt = find(boxes, 'moof/traf/tfdt');
    expect(tfdt.body[0]).toBe(1);
    expect(u32(tfdt, 4) * 2 ** 32 + u32(tfdt, 8)).toBe(2 ** 33 + 1500);
  });

  it('points trun data_offset at the mdat payload', () => {
    const trun = find(boxes, 'moof/traf/trun');
    expect(u32(trun, 4)).toBe(1); // sample_count
    const dataOffset = u32(trun, 8);
    const mdat = find(boxes, 'mdat');
    expect(dataOffset).toBe(mdat.start + 8);
    expect(segment.subarray(dataOffset)).toEqual(sample);
    expect([u32(trun, 12), u32(trun, 16), u32(trun, 20)]).toEqual([1500, sample.length, 0x02000000]);
  });

  it('marks delta frames as non-sync', () => {
    const delta = parse(mediaSegment(8, { data: sample, decodeTime: 0, duration: 1500, keyframe: false }));
    expect(u32(find(delta, 'moof/traf/trun'), 20)).toBe(0x01010000);
  });
});
