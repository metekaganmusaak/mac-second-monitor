// Parameter sets captured from the macOS host encoder (VideoToolbox, H.264 Constrained High).
export function fromHex(text: string): Uint8Array {
  return new Uint8Array(text.match(/../g)!.map((byte) => parseInt(byte, 16)));
}

/** 640 × 400, avc1.640C1F */
export const sps640x400 = fromHex('27640c1fac1314100280ce9a80808083c2010842');
/** 1920 × 1080 (coded 1920 × 1088 with bottom cropping), avc1.640C2A */
export const sps1920x1080 = fromHex('27640c2aac1314501e0089f966a0202020f0804258');
export const pps = fromHex('28ee3cb0');
