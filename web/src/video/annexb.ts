// H.264 Annex-B helpers: NAL unit splitting, length-prefixed conversion and SPS parsing.

import type { Bytes } from '../protocol';

export const NalType = {
  slice: 1,
  idr: 5,
  sei: 6,
  sps: 7,
  pps: 8,
  aud: 9,
} as const;

export function nalType(nal: Uint8Array): number {
  return (nal[0] ?? 0) & 0x1f;
}

/** Splits an Annex-B byte stream into NAL units (start codes removed). */
export function splitAnnexB(data: Uint8Array): Uint8Array[] {
  const units: Uint8Array[] = [];
  let start = -1;
  let i = 0;
  const n = data.length;
  while (i + 2 < n) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      if (start >= 0) pushTrimmed(units, data, start, i);
      i += 3;
      start = i;
    } else if (data[i + 2]! > 1) {
      // No start code can begin at i, i + 1 or i + 2.
      i += 3;
    } else {
      i += 1;
    }
  }
  if (start >= 0) pushTrimmed(units, data, start, n);
  return units;
}

// The zero byte of a 4-byte start code (and any trailing_zero_8bits) belongs to the next
// start code; a NAL unit never ends in 0x00.
function pushTrimmed(units: Uint8Array[], data: Uint8Array, start: number, end: number): void {
  let e = end;
  while (e > start && data[e - 1] === 0) e--;
  if (e > start) units.push(data.subarray(start, e));
}

/** NAL units with 4-byte big-endian length prefixes (the MP4 / AVCC sample layout). */
export function toLengthPrefixed(units: Uint8Array[]): Bytes {
  let size = 0;
  for (const unit of units) size += 4 + unit.length;
  const out = new Uint8Array(size);
  const view = new DataView(out.buffer);
  let offset = 0;
  for (const unit of units) {
    view.setUint32(offset, unit.length);
    out.set(unit, offset + 4);
    offset += 4 + unit.length;
  }
  return out;
}

/** Removes emulation prevention bytes (00 00 03 → 00 00). */
export function toRbsp(nal: Uint8Array): Uint8Array {
  const out = new Uint8Array(nal.length);
  let length = 0;
  let zeros = 0;
  for (const byte of nal) {
    if (zeros >= 2 && byte === 3) {
      zeros = 0;
      continue;
    }
    zeros = byte === 0 ? zeros + 1 : 0;
    out[length++] = byte;
  }
  return out.subarray(0, length);
}

class BitReader {
  private bit = 0;

  constructor(private readonly bytes: Uint8Array) {}

  u(count: number): number {
    let value = 0;
    for (let i = 0; i < count; i++) {
      const byte = this.bytes[this.bit >> 3];
      if (byte === undefined) throw new RangeError('SPS truncated');
      value = value * 2 + ((byte >> (7 - (this.bit & 7))) & 1);
      this.bit++;
    }
    return value;
  }

  ue(): number {
    let zeros = 0;
    while (this.u(1) === 0) {
      zeros++;
      if (zeros > 31) throw new RangeError('invalid Exp-Golomb code');
    }
    return 2 ** zeros - 1 + this.u(zeros);
  }

  se(): number {
    const value = this.ue();
    return value & 1 ? (value + 1) / 2 : -(value / 2);
  }
}

export interface SpsInfo {
  profileIdc: number;
  constraintFlags: number;
  levelIdc: number;
  chromaFormatIdc: number;
  bitDepthLuma: number;
  bitDepthChroma: number;
  width: number;
  height: number;
}

const highProfiles = new Set([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]);

export function isHighProfile(profileIdc: number): boolean {
  return highProfiles.has(profileIdc);
}

/** Parses the fields of an H.264 SPS NAL unit (header byte included) that MP4 needs. */
export function parseSps(nal: Uint8Array): SpsInfo {
  const r = new BitReader(toRbsp(nal.subarray(1)));
  const profileIdc = r.u(8);
  const constraintFlags = r.u(8);
  const levelIdc = r.u(8);
  r.ue(); // seq_parameter_set_id
  let chromaFormatIdc = 1;
  let bitDepthLuma = 8;
  let bitDepthChroma = 8;
  let separateColourPlane = 0;
  if (highProfiles.has(profileIdc)) {
    chromaFormatIdc = r.ue();
    if (chromaFormatIdc === 3) separateColourPlane = r.u(1);
    bitDepthLuma = r.ue() + 8;
    bitDepthChroma = r.ue() + 8;
    r.u(1); // qpprime_y_zero_transform_bypass_flag
    if (r.u(1)) {
      const lists = chromaFormatIdc === 3 ? 12 : 8;
      for (let i = 0; i < lists; i++) {
        if (r.u(1)) skipScalingList(r, i < 6 ? 16 : 64);
      }
    }
  }
  r.ue(); // log2_max_frame_num_minus4
  const pocType = r.ue();
  if (pocType === 0) {
    r.ue();
  } else if (pocType === 1) {
    r.u(1);
    r.se();
    r.se();
    const cycle = r.ue();
    for (let i = 0; i < cycle; i++) r.se();
  }
  r.ue(); // max_num_ref_frames
  r.u(1); // gaps_in_frame_num_value_allowed_flag
  const widthMbs = r.ue() + 1;
  const heightMapUnits = r.ue() + 1;
  const frameMbsOnly = r.u(1);
  if (!frameMbsOnly) r.u(1);
  r.u(1); // direct_8x8_inference_flag
  let cropLeft = 0;
  let cropRight = 0;
  let cropTop = 0;
  let cropBottom = 0;
  if (r.u(1)) {
    cropLeft = r.ue();
    cropRight = r.ue();
    cropTop = r.ue();
    cropBottom = r.ue();
  }
  const chromaArrayType = separateColourPlane ? 0 : chromaFormatIdc;
  const subWidthC = chromaFormatIdc === 3 ? 1 : 2;
  const subHeightC = chromaFormatIdc === 1 ? 2 : 1;
  const cropUnitX = chromaArrayType === 0 ? 1 : subWidthC;
  const cropUnitY = (chromaArrayType === 0 ? 1 : subHeightC) * (2 - frameMbsOnly);
  return {
    profileIdc,
    constraintFlags,
    levelIdc,
    chromaFormatIdc,
    bitDepthLuma,
    bitDepthChroma,
    width: widthMbs * 16 - cropUnitX * (cropLeft + cropRight),
    height: heightMapUnits * 16 * (2 - frameMbsOnly) - cropUnitY * (cropTop + cropBottom),
  };
}

function skipScalingList(r: BitReader, size: number): void {
  let last = 8;
  let next = 8;
  for (let i = 0; i < size; i++) {
    if (next !== 0) {
      next = (last + r.se() + 256) % 256;
    }
    last = next === 0 ? last : next;
  }
}

/** RFC 6381 codec string (`avc1.PPCCLL`) from an SPS NAL unit. */
export function codecStringFromSps(sps: Uint8Array): string {
  const hex = (value: number | undefined) => (value ?? 0).toString(16).padStart(2, '0').toUpperCase();
  return `avc1.${hex(sps[1])}${hex(sps[2])}${hex(sps[3])}`;
}
