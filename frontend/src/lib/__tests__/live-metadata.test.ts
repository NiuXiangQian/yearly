// @vitest-environment happy-dom
import { expect, it } from "vitest";
import { inspectFile, appleContentIdentifier } from "../metadata";
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
function appleNote(identifier: string, little = false) {
  const note = new Uint8Array(32 + identifier.length + 1);
  note.set(new TextEncoder().encode("Apple iOS\0\0\x01" + (little ? "II" : "MM")));
  const view = new DataView(note.buffer);
  view.setUint16(14, 1, little);
  view.setUint16(16, 0x0011, little);
  view.setUint16(18, 2, little);
  view.setUint32(20, identifier.length + 1, little);
  view.setUint32(24, 32, little);
  note.set(new TextEncoder().encode(identifier), 32);
  return note;
}
it("extracts Apple pairing identifiers and rejects truncated or unrelated MakerNotes", () => {
  const id = "8D815CBE-496E-4F20-AB68-28C5C09B0C5D";
  for (const little of [false, true]) {
    const note = appleNote(id, little);
    expect(appleContentIdentifier(note)).toBe(id);
    expect(appleContentIdentifier(join(new Uint8Array(7), note).subarray(7))).toBe(id);
    expect(appleContentIdentifier(note.slice(0, 35))).toBeNull();
  }
  expect(appleContentIdentifier(new Uint8Array(40))).toBeNull();
  expect(appleContentIdentifier(undefined)).toBeNull();
});
it("reads a Live Photo identifier through real EXIF parsing and matches the MOV identifier", async () => {
  const id = "8D815CBE-496E-4F20-AB68-28C5C09B0C5D";
  const note = appleNote(id);
  const tiff = new Uint8Array(44 + note.length);
  const view = new DataView(tiff.buffer);
  tiff.set([0x49, 0x49, 42, 0, 8, 0, 0, 0]);
  view.setUint16(8, 1, true);
  view.setUint16(10, 0x8769, true);
  view.setUint16(12, 4, true);
  view.setUint32(14, 1, true);
  view.setUint32(18, 26, true);
  view.setUint16(26, 1, true);
  view.setUint16(28, 0x927c, true);
  view.setUint16(30, 7, true);
  view.setUint32(32, note.length, true);
  view.setUint32(36, 44, true);
  tiff.set(note, 44);
  const app1 = join(new TextEncoder().encode("Exif\0\0"), tiff);
  const length = app1.length + 2;
  const jpeg = join(new Uint8Array([255, 216, 255, 225, length >> 8, length & 255]), app1, new Uint8Array([255, 217]));
  const photo = await inspectFile(new File([jpeg], "photo.jpg", { type: "image/jpeg" }));
  expect(photo.pairId, JSON.stringify(photo.raw)).toBe(id);
  expect(photo.raw).toMatchObject({ ContentIdentifier: id });
  const key = "com.apple.quicktime.content.identifier";
  const keys = new Uint8Array(16 + key.length);
  new DataView(keys.buffer).setUint32(4, 1);
  new DataView(keys.buffer).setUint32(8, 8 + key.length);
  keys.set(new TextEncoder().encode("mdta" + key), 12);
  const trackKey = "com.apple.quicktime.camera.lens_model";
  const trackKeys = new Uint8Array(16 + trackKey.length);
  new DataView(trackKeys.buffer).setUint32(4, 1);
  new DataView(trackKeys.buffer).setUint32(8, 8 + trackKey.length);
  trackKeys.set(new TextEncoder().encode("mdta" + trackKey), 12);
  const track = box("trak", box("meta", box("keys", trackKeys)));
  for (const prefix of [new Uint8Array(4), new Uint8Array(0)]) {
    const movie = new File([box("moov", join(track, box("meta", join(prefix, box("keys", keys), box("ilst", box("\0\0\0\x01", box("data", join(new Uint8Array(8), new TextEncoder().encode(id)))))))))], "different-name.MOV");
    expect((await inspectFile(movie)).pairId).toBe(photo.pairId);
  }
});
