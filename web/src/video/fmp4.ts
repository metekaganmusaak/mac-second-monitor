// Minimal fragmented MP4 (ISO BMFF) muxer for one H.264 video track: an init segment
// (ftyp + moov) and one moof + mdat fragment per access unit.

import type { Bytes } from '../protocol';
import { isHighProfile, parseSps, type SpsInfo } from './annexb';

const TRACK_ID = 1;

function fourcc(code: string): number[] {
  return [code.charCodeAt(0), code.charCodeAt(1), code.charCodeAt(2), code.charCodeAt(3)];
}

function asciiz(text: string): number[] {
  return [...Array.from(text, (c) => c.charCodeAt(0)), 0];
}

class ByteWriter {
  private bytes: number[] = [];

  u8(value: number): this {
    this.bytes.push(value & 0xff);
    return this;
  }

  u16(value: number): this {
    return this.u8(value >>> 8).u8(value);
  }

  u32(value: number): this {
    return this.u8(value >>> 24).u8(value >>> 16).u8(value >>> 8).u8(value);
  }

  u64(value: number): this {
    return this.u32(Math.floor(value / 0x1_0000_0000)).u32(value % 0x1_0000_0000);
  }

  zeros(count: number): this {
    for (let i = 0; i < count; i++) this.bytes.push(0);
    return this;
  }

  raw(data: ArrayLike<number>): this {
    for (let i = 0; i < data.length; i++) this.bytes.push(data[i]!);
    return this;
  }

  toArray(): number[] {
    return this.bytes;
  }
}

function box(type: string, ...children: ArrayLike<number>[]): Bytes {
  let size = 8;
  for (const child of children) size += child.length;
  const out = new Uint8Array(size);
  new DataView(out.buffer).setUint32(0, size);
  out.set(fourcc(type), 4);
  let offset = 8;
  for (const child of children) {
    out.set(child, offset);
    offset += child.length;
  }
  return out;
}

function fullBox(type: string, version: number, flags: number, ...children: ArrayLike<number>[]): Bytes {
  const header = [version, (flags >>> 16) & 0xff, (flags >>> 8) & 0xff, flags & 0xff];
  return box(type, header, ...children);
}

const unityMatrix = new ByteWriter()
  .u32(0x00010000).u32(0).u32(0)
  .u32(0).u32(0x00010000).u32(0)
  .u32(0).u32(0).u32(0x40000000)
  .toArray();

export interface InitOptions {
  sps: Uint8Array;
  pps: Uint8Array;
  timescale: number;
}

/** AVCDecoderConfigurationRecord (ISO/IEC 14496-15 §5.3.3.1). */
export function avcC(sps: Uint8Array, pps: Uint8Array, info: SpsInfo = parseSps(sps)): Uint8Array {
  const w = new ByteWriter()
    .u8(1)
    .u8(sps[1] ?? 0)
    .u8(sps[2] ?? 0)
    .u8(sps[3] ?? 0)
    .u8(0xfc | 3) // lengthSizeMinusOne = 3
    .u8(0xe0 | 1) // one SPS
    .u16(sps.length)
    .raw(sps)
    .u8(1) // one PPS
    .u16(pps.length)
    .raw(pps);
  if (isHighProfile(info.profileIdc)) {
    w.u8(0xfc | info.chromaFormatIdc)
      .u8(0xf8 | (info.bitDepthLuma - 8))
      .u8(0xf8 | (info.bitDepthChroma - 8))
      .u8(0); // no SPS extensions
  }
  return box('avcC', w.toArray());
}

/** ftyp + moov. Durations are zero and there is no mehd: the stream is live. */
export function initSegment({ sps, pps, timescale }: InitOptions): Bytes {
  const info = parseSps(sps);
  const { width, height } = info;

  const ftyp = box(
    'ftyp',
    new ByteWriter().raw(fourcc('isom')).u32(0x200).raw(fourcc('isom')).raw(fourcc('iso6')).raw(fourcc('avc1')).raw(fourcc('mp41')).toArray(),
  );

  const mvhd = fullBox(
    'mvhd', 0, 0,
    new ByteWriter()
      .u32(0).u32(0) // creation, modification time
      .u32(timescale)
      .u32(0) // duration
      .u32(0x00010000) // rate 1.0
      .u16(0x0100) // volume 1.0
      .zeros(10)
      .raw(unityMatrix)
      .zeros(24)
      .u32(TRACK_ID + 1) // next_track_ID
      .toArray(),
  );

  const tkhd = fullBox(
    'tkhd', 0, 0x000003, // enabled, in movie
    new ByteWriter()
      .u32(0).u32(0)
      .u32(TRACK_ID)
      .u32(0)
      .u32(0) // duration
      .zeros(8)
      .u16(0).u16(0) // layer, alternate_group
      .u16(0) // volume (video)
      .u16(0)
      .raw(unityMatrix)
      .u32(width * 0x10000)
      .u32(height * 0x10000)
      .toArray(),
  );

  const mdhd = fullBox(
    'mdhd', 0, 0,
    new ByteWriter().u32(0).u32(0).u32(timescale).u32(0).u16(0x55c4 /* 'und' */).u16(0).toArray(),
  );
  const hdlr = fullBox(
    'hdlr', 0, 0,
    new ByteWriter().u32(0).raw(fourcc('vide')).zeros(12).raw(asciiz('VideoHandler')).toArray(),
  );
  const vmhd = fullBox('vmhd', 0, 1, new ByteWriter().u16(0).u16(0).u16(0).u16(0).toArray());
  const dinf = box('dinf', fullBox('dref', 0, 0, new ByteWriter().u32(1).toArray(), fullBox('url ', 0, 1)));

  const avc1 = box(
    'avc1',
    new ByteWriter()
      .zeros(6)
      .u16(1) // data_reference_index
      .u16(0).u16(0)
      .zeros(12)
      .u16(width)
      .u16(height)
      .u32(0x00480000) // 72 dpi
      .u32(0x00480000)
      .u32(0)
      .u16(1) // frame_count
      .zeros(32) // compressorname
      .u16(0x0018) // depth
      .u16(0xffff) // pre_defined = -1
      .toArray(),
    avcC(sps, pps, info),
  );
  const stsd = fullBox('stsd', 0, 0, new ByteWriter().u32(1).toArray(), avc1);
  const empty = new ByteWriter().u32(0).toArray();
  const stbl = box(
    'stbl',
    stsd,
    fullBox('stts', 0, 0, empty),
    fullBox('stsc', 0, 0, empty),
    fullBox('stsz', 0, 0, new ByteWriter().u32(0).u32(0).toArray()),
    fullBox('stco', 0, 0, empty),
  );
  const minf = box('minf', vmhd, dinf, stbl);
  const mdia = box('mdia', mdhd, hdlr, minf);
  const trak = box('trak', tkhd, mdia);

  const trex = fullBox('trex', 0, 0, new ByteWriter().u32(TRACK_ID).u32(1).u32(0).u32(0).u32(0).toArray());
  const mvex = box('mvex', trex);
  const moov = box('moov', mvhd, trak, mvex);

  return concat([ftyp, moov]);
}

export interface Sample {
  /** Length-prefixed NAL units. */
  data: Uint8Array;
  /** In timescale units. */
  decodeTime: number;
  duration: number;
  keyframe: boolean;
}

const SAMPLE_FLAGS_SYNC = 0x02000000; // sample_depends_on = 2 (independent)
const SAMPLE_FLAGS_NON_SYNC = 0x01010000; // sample_depends_on = 1, sample_is_non_sync_sample

/** moof + mdat carrying one sample. */
export function mediaSegment(sequenceNumber: number, sample: Sample): Bytes {
  const mfhd = fullBox('mfhd', 0, 0, new ByteWriter().u32(sequenceNumber).toArray());
  const tfhd = fullBox('tfhd', 0, 0x020000 /* default-base-is-moof */, new ByteWriter().u32(TRACK_ID).toArray());
  const tfdt = fullBox('tfdt', 1, 0, new ByteWriter().u64(sample.decodeTime).toArray());
  // data-offset, sample-duration, sample-size, sample-flags present.
  const trunFlags = 0x000001 | 0x000100 | 0x000200 | 0x000400;
  const trunSize = 12 + 4 + 4 + 12;
  const moofSize = 8 + mfhd.length + 8 + tfhd.length + tfdt.length + trunSize;
  const trun = fullBox(
    'trun', 0, trunFlags,
    new ByteWriter()
      .u32(1) // sample_count
      .u32(moofSize + 8) // data_offset: first byte of mdat payload, from the start of moof
      .u32(sample.duration)
      .u32(sample.data.length)
      .u32(sample.keyframe ? SAMPLE_FLAGS_SYNC : SAMPLE_FLAGS_NON_SYNC)
      .toArray(),
  );
  const traf = box('traf', tfhd, tfdt, trun);
  const moof = box('moof', mfhd, traf);
  const mdat = box('mdat', sample.data);
  return concat([moof, mdat]);
}

export function concat(parts: Uint8Array[]): Bytes {
  let size = 0;
  for (const part of parts) size += part.length;
  const out = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
