import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import exifr from "exifr";
import {
  fingerprints,
  wallTime,
  offsetMinutes,
  quickTime,
  inspectFile,
} from "../metadata";
function box(kind: string, data: Uint8Array) {
  const buffer = new Uint8Array(data.length + 8);
  new DataView(buffer.buffer).setUint32(0, buffer.length);
  buffer.set(new TextEncoder().encode(kind), 4);
  buffer.set(data, 8);
  return buffer;
}
function join(...buffers: Uint8Array[]) {
  const value = new Uint8Array(buffers.reduce((n, b) => n + b.length, 0));
  let pos = 0;
  for (const b of buffers) {
    value.set(b, pos);
    pos += b.length;
  }
  return value;
}
describe("original metadata and bounded reads", () => {
  it("keeps local time and explicit offsets independent", () => {
    expect(wallTime("2024:02:29 23:50:00")).toBe("2024-02-29T23:50:00");
    expect(wallTime("2024-02-29T23:50:00+08:00")).toBe("2024-02-29T23:50:00");
    expect(offsetMinutes("+08:00")).toBe(480);
    expect(offsetMinutes("-05:30")).toBe(-330);
    expect(offsetMinutes(undefined)).toBeNull();
    expect(wallTime("unknown")).toBeNull();
  });
  it("reads real EXIF time, GPS, lens, ISO and device from JPEG fixture", async () => {
    const data = readFileSync(
      new URL("../__fixtures__/exif.jpg", import.meta.url),
    );
    const parsed = await exifr.parse(data, { reviveValues: false });
    expect(parsed.DateTimeOriginal).toBe("2024:02:29 23:45:10");
    expect(parsed.Make).toBe("Apple");
    expect(parsed.Model).toBe("Test Camera");
    expect(parsed.LensModel).toBe("Example Lens");
    expect(parsed.ISO).toBe(100);
    expect(parsed.latitude).toBeCloseTo(30.25);
    expect(parsed.longitude).toBeCloseTo(120.5);
  });
  it("hashes incrementally with OSS-compatible CRC64/XZ", async () => {
    const hash = await fingerprints(new Blob(["123456789"]));
    expect(hash.sha256).toBe(
      createHash("sha256").update("123456789").digest("hex"),
    );
    expect(BigInt(hash.crc64).toString(16)).toBe("995dc9bbdf1939fa");
  });
  it("limits hash read buffers to 4 MiB", async () => {
    const blob = new Blob([new Uint8Array(9 * 1024 * 1024 + 7)]);
    const original = blob.slice.bind(blob);
    let largest = 0;
    blob.slice = (start, end) => {
      largest = Math.max(largest, (end || blob.size) - (start || 0));
      return original(start, end);
    };
    await fingerprints(blob);
    expect(largest).toBeLessThanOrEqual(4 * 1024 * 1024);
  });
  it("walks QuickTime metadata without reading mdat payload", async () => {
    const key = "com.apple.quicktime.creationdate",
      value = "2024-02-29T23:50:00+08:00";
    const keydata = new Uint8Array(8 + 8 + key.length);
    const v = new DataView(keydata.buffer);
    v.setUint32(4, 1);
    v.setUint32(8, 8 + key.length);
    keydata.set(new TextEncoder().encode("mdta"), 12);
    keydata.set(new TextEncoder().encode(key), 16);
    const entry = box(
      "data",
      join(new Uint8Array(8), new TextEncoder().encode(value)),
    );
    const entryBox = box("\x00\x00\x00\x01", entry);
    const meta = box(
      "meta",
      join(new Uint8Array(4), box("keys", keydata), box("ilst", entryBox)),
    );
    const blob = new Blob([
      box("mdat", new Uint8Array(20 * 1024 * 1024)),
      box("moov", meta),
    ]);
    const slice = blob.slice.bind(blob);
    let largest = 0;
    blob.slice = (start, end) => {
      largest = Math.max(largest, (end || blob.size) - (start || 0));
      return slice(start, end);
    };
    const data = await quickTime(blob);
    expect(data[key]).toBe(value);
    expect(largest).toBeLessThan(1024);
  });
  it("does not invent a timezone for QuickTime numeric creation time", async () => {
    const mvhd = new Uint8Array(100);
    const v = new DataView(mvhd.buffer);
    v.setUint32(4, 3700000000);
    v.setUint32(12, 1000);
    v.setUint32(16, 15000);
    const result = await quickTime(new Blob([box("moov", box("mvhd", mvhd))]));
    expect(result.Duration).toBe(15);
    expect(result.QuickTimeCreateDateSeconds).toBe(3700000000);
    expect(result.CreationDate).toBeUndefined();
  });
});

it("reads JPEG dimensions without decoding pixels", async () => {
  const { imageDimensions } = await import("../metadata");
  const fixture = readFileSync(
    new URL("../__fixtures__/exif.jpg", import.meta.url),
  );
  expect(await imageDimensions(new Blob([fixture]))).toEqual({
    width: 48,
    height: 32,
  });
});
