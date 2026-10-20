import { describe, expect, it } from 'vitest';
import { codecStringFromSps, nalType, NalType, parseSps, splitAnnexB, toLengthPrefixed, toRbsp } from '../src/video/annexb';
import { fromHex, pps, sps1920x1080, sps640x400 } from './fixtures';

describe('splitAnnexB', () => {
  it('splits on 3- and 4-byte start codes', () => {
    const data = fromHex('00000001' + '6742' + '000001' + '68ce' + '00000001' + '658899');
    const units = splitAnnexB(data);
    expect(units.map((u) => Array.from(u))).toEqual([[0x67, 0x42], [0x68, 0xce], [0x65, 0x88, 0x99]]);
    expect(units.map(nalType)).toEqual([NalType.sps, NalType.pps, NalType.idr]);
  });

  it('drops trailing zero bytes and ignores data before the first start code', () => {
    const units = splitAnnexB(fromHex('ffff' + '00000001' + '41aa0000' + '00000001' + '41bb'));
    expect(units.map((u) => Array.from(u))).toEqual([[0x41, 0xaa], [0x41, 0xbb]]);
  });

  it('keeps emulation-prevented sequences inside a unit', () => {
    const units = splitAnnexB(fromHex('00000001' + '65000003010203'));
    expect(Array.from(units[0]!)).toEqual([0x65, 0, 0, 3, 1, 2, 3]);
    expect(Array.from(toRbsp(units[0]!))).toEqual([0x65, 0, 0, 1, 2, 3]);
  });

  it('returns nothing without a start code', () => {
    expect(splitAnnexB(fromHex('6588'))).toEqual([]);
  });
});

describe('toLengthPrefixed', () => {
  it('writes 4-byte big-endian lengths', () => {
    const out = toLengthPrefixed([fromHex('65aa'), fromHex('06')]);
    expect(Array.from(out)).toEqual([0, 0, 0, 2, 0x65, 0xaa, 0, 0, 0, 1, 0x06]);
  });
});

describe('parseSps', () => {
  it('reads profile, level and size from a host SPS', () => {
    expect(parseSps(sps640x400)).toEqual({
      profileIdc: 100,
      constraintFlags: 0x0c,
      levelIdc: 0x1f,
      chromaFormatIdc: 1,
      bitDepthLuma: 8,
      bitDepthChroma: 8,
      width: 640,
      height: 400,
    });
  });

  it('applies frame cropping', () => {
    const info = parseSps(sps1920x1080);
    expect([info.width, info.height]).toEqual([1920, 1080]);
  });

  it('derives the RFC 6381 codec string the host sends in CONFIG', () => {
    expect(codecStringFromSps(sps640x400)).toBe('avc1.640C1F');
    expect(codecStringFromSps(sps1920x1080)).toBe('avc1.640C2A');
    expect(nalType(pps)).toBe(NalType.pps);
  });
});
