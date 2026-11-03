import exifr from "exifr";
import { createSHA256, createCRC64 } from "hash-wasm";

export function wallTime(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const match = value.match(
    /^(\d{4})[:-](\d{2})[:-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})/,
  );
  return match
    ? `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}`
    : null;
}
export function offsetMinutes(value: unknown): number | null {
  if (typeof value !== "string") return null;
  if (value.endsWith("Z")) return 0;
  const match = value.match(/([+-])(\d{2}):?(\d{2})$/);
  return match
    ? (match[1] === "-" ? -1 : 1) * (+match[2] * 60 + +match[3])
    : null;
}
const text = (buffer: Uint8Array) =>
  new TextDecoder().decode(buffer).replace(/\0/g, "").trim();

// Read box headers by range, skipping mdat. Never load an entire movie or unbounded moov.
export async function quickTime(file: Blob): Promise<Record<string, any>> {
  const result: Record<string, any> = {},
    keys: string[] = [];
  let boxes = 0,
    metadataBytes = 0;
  async function read(start: number, length: number) {
    return new Uint8Array(
      await file.slice(start, start + length).arrayBuffer(),
    );
  }
  async function walk(
    start: number,
    end: number,
    depth: number,
    path: string,
    track: Record<string, any> | null = null,
  ) {
    if (depth > 12) return;
    let position = start;
    while (position + 8 <= end && ++boxes <= 12000) {
      const header = await read(position, 16),
        view = new DataView(header.buffer);
      const kind = text(header.slice(4, 8));
      let size = view.getUint32(0),
        headerSize = 8;
      if (size === 1) {
        if (header.length < 16) break;
        size = Number(view.getBigUint64(8));
        headerSize = 16;
      }
      if (size === 0) size = end - position;
      if (
        size < headerSize ||
        position + size > end ||
        !Number.isSafeInteger(size)
      )
        break;
      const body = position + headerSize,
        length = size - headerSize;
      if (
        [
          "moov",
          "trak",
          "mdia",
          "minf",
          "stbl",
          "udta",
          "meta",
          "ilst",
        ].includes(kind)
      ) {
        const childTrack = kind === "trak" ? {} : track;
        await walk(
          body + (kind === "meta" ? 4 : 0),
          position + size,
          depth + 1,
          path + "/" + kind,
          childTrack,
        );
        if (kind === "trak" && childTrack) {
          if (childTrack.handler === "vide") {
            Object.assign(result, {
              ImageWidth: childTrack.width,
              ImageHeight: childTrack.height,
              Rotation: childTrack.rotation,
              VideoCodec: childTrack.codec,
            });
            if (childTrack.timescale && childTrack.sampleDelta)
              result.FrameRate = childTrack.timescale / childTrack.sampleDelta;
          }
          if (childTrack.handler === "soun") {
            result.HasAudio = true;
            result.AudioCodec = childTrack.codec;
          }
        }
      } else if (
        length <= 1024 * 1024 &&
        metadataBytes + length <= 8 * 1024 * 1024 &&
        kind !== "mdat"
      ) {
        metadataBytes += length;
        const data = await read(body, length),
          v = new DataView(data.buffer);
        if (kind === "mvhd" && length >= 32) {
          const version = data[0],
            timescale = v.getUint32(version === 1 ? 20 : 12);
          const duration =
            version === 1 ? Number(v.getBigUint64(24)) : v.getUint32(16);
          if (timescale) result.Duration = duration / timescale;
          // QuickTime numeric creation seconds have ambiguous local/UTC provenance. Keep raw only.
          result.QuickTimeCreateDateSeconds =
            version === 1 ? String(v.getBigUint64(4)) : v.getUint32(4);
        }
        if (kind === "tkhd" && track && length >= 84) {
          const width = v.getUint32(length - 8) / 65536,
            height = v.getUint32(length - 4) / 65536;
          if (width && height) {
            track.width = width;
            track.height = height;
            const matrix = data[0] === 1 ? 52 : 40;
            const a = v.getInt32(matrix) / 65536,
              b = v.getInt32(matrix + 4) / 65536;
            track.rotation = Math.round((Math.atan2(b, a) * 180) / Math.PI);
          }
        }
        if (kind === "hdlr" && track && length >= 12)
          track.handler = text(data.slice(8, 12));
        if (kind === "stsd" && track && length >= 16)
          track.codec = text(data.slice(12, 16));
        if (kind === "stts" && track && length >= 16 && v.getUint32(4) === 1)
          track.sampleDelta = v.getUint32(12);
        if (kind === "mdhd" && track && length >= (data[0] === 1 ? 32 : 24))
          track.timescale = v.getUint32(data[0] === 1 ? 20 : 12);
        if (kind === "keys" && length >= 8) {
          let cursor = 8;
          while (cursor + 8 <= length) {
            const len = v.getUint32(cursor);
            if (len < 8 || cursor + len > length) break;
            keys.push(text(data.slice(cursor + 8, cursor + len)));
            cursor += len;
          }
        }
        if (path.endsWith("/ilst") && length >= 16) {
          const index = new DataView(header.buffer).getUint32(4);
          const key = keys[index - 1] || kind;
          const payload = text(data.slice(16));
          result[key] = payload;
        }
        if (kind === "©xyz") result.QuickTimeLocation = text(data.slice(4));
      }
      position += size;
    }
  }
  await walk(0, file.size, 0, "");
  return result;
}

// Container dimensions without decoding a full-resolution bitmap.
export async function imageDimensions(
  file: Blob,
): Promise<{ width?: number; height?: number }> {
  const head = new Uint8Array(await file.slice(0, 32).arrayBuffer());
  const view = new DataView(head.buffer);
  if (
    head.length >= 24 &&
    head[0] === 0x89 &&
    text(head.slice(1, 4)) === "PNG"
  ) {
    return { width: view.getUint32(16), height: view.getUint32(20) };
  }
  if (
    head.length >= 30 &&
    text(head.slice(0, 4)) === "RIFF" &&
    text(head.slice(8, 12)) === "WEBP"
  ) {
    const kind = text(head.slice(12, 16));
    if (kind === "VP8X")
      return {
        width: 1 + head[24] + (head[25] << 8) + (head[26] << 16),
        height: 1 + head[27] + (head[28] << 8) + (head[29] << 16),
      };
    if (
      kind === "VP8 " &&
      head[23] === 0x9d &&
      head[24] === 0x01 &&
      head[25] === 0x2a
    )
      return {
        width: view.getUint16(26, true) & 0x3fff,
        height: view.getUint16(28, true) & 0x3fff,
      };
    if (kind === "VP8L" && head[20] === 0x2f)
      return {
        width: 1 + head[21] + ((head[22] & 0x3f) << 8),
        height:
          1 + (head[22] >> 6) + (head[23] << 2) + ((head[24] & 0x0f) << 10),
      };
  }
  if (head[0] === 0xff && head[1] === 0xd8) {
    let cursor = 2;
    for (let segment = 0; segment < 2000 && cursor + 4 < file.size; segment++) {
      const bytes = new Uint8Array(
        await file.slice(cursor, cursor + 9).arrayBuffer(),
      );
      if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] === 0xda) break;
      if (bytes[1] === 0xff) {
        cursor++;
        continue;
      }
      const length = (bytes[2] << 8) + bytes[3];
      if (length < 2) break;
      if (
        [
          0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd,
          0xce, 0xcf,
        ].includes(bytes[1]) &&
        bytes.length >= 9
      ) {
        return {
          width: (bytes[7] << 8) + bytes[8],
          height: (bytes[5] << 8) + bytes[6],
        };
      }
      cursor += 2 + length;
    }
  }
  return {};
}

export async function fingerprints(
  file: Blob,
  progress?: (value: number) => void,
) {
  const [sha, crc] = await Promise.all([createSHA256(), createCRC64()]);
  sha.init();
  crc.init();
  const chunk = 4 * 1024 * 1024;
  for (let start = 0; start < file.size; start += chunk) {
    const block = new Uint8Array(
      await file.slice(start, start + chunk).arrayBuffer(),
    );
    sha.update(block);
    crc.update(block);
    progress?.(
      Math.min(100, Math.round(((start + block.length) / file.size) * 100)),
    );
  }
  return {
    sha256: sha.digest("hex"),
    crc64: BigInt("0x" + crc.digest("hex")).toString(),
  };
}

export async function inspectFile(
  file: File,
  progress?: (value: number) => void,
) {
  let raw: Record<string, any> = {},
    error = "";
  const video = /\.(mov|mp4)$/i.test(file.name);
  try {
    raw = video
      ? await quickTime(file)
      : (await exifr.parse(file, {
          tiff: true,
          exif: true,
          gps: true,
          ifd1: true,
          xmp: true,
          iptc: true,
          icc: false,
          translateValues: true,
          reviveValues: false,
          sanitize: false,
        })) || {};
  } catch (e) {
    error = e instanceof Error ? e.message : "解析失败";
  }
  const original = wallTime(raw.DateTimeOriginal),
    other = wallTime(raw.CreateDate);
  const qtDate = raw["com.apple.quicktime.creationdate"] || raw.CreationDate;
  const taken = original || other || wallTime(qtDate);
  const modified = new Date(file.lastModified);
  const fallback = Number.isFinite(modified.getTime())
    ? `${modified.getFullYear()}-${String(modified.getMonth() + 1).padStart(2, "0")}-${String(modified.getDate()).padStart(2, "0")}T${String(modified.getHours()).padStart(2, "0")}:${String(modified.getMinutes()).padStart(2, "0")}:${String(modified.getSeconds()).padStart(2, "0")}`
    : null;
  const coordinates = String(
    raw["com.apple.quicktime.location.ISO6709"] || raw.QuickTimeLocation || "",
  ).match(/([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?/);
  const pairId =
    raw.ContentIdentifier ||
    raw["com.apple.quicktime.content.identifier"] ||
    raw["Content Identifier"] ||
    null;
  const dimensions = video ? {} : await imageDimensions(file);
  let altitude = raw.GPSAltitude ?? (coordinates?.[3] ? +coordinates[3] : null);
  if (
    raw.GPSAltitude != null &&
    (raw.GPSAltitudeRef === 1 || raw.GPSAltitudeRef?.[0] === 1)
  )
    altitude = -Math.abs(raw.GPSAltitude);
  const hash = await fingerprints(file, progress);
  return {
    file,
    hash,
    raw: {
      ...raw,
      OriginalFilename: file.name,
      MIME: file.type,
      FileSize: file.size,
      FileModified: modified.toISOString(),
      parse_status: error
        ? "partial"
        : Object.keys(raw).length
          ? "parsed"
          : "unsupported",
      parse_error: error || null,
    },
    pairId,
    video,
    original_taken_at_local: taken || fallback,
    original_offset_minutes: taken
      ? offsetMinutes(raw.OffsetTimeOriginal || qtDate)
      : null,
    time_source: original
      ? "EXIF.DateTimeOriginal"
      : other
        ? "EXIF.CreateDate"
        : wallTime(qtDate)
          ? "QuickTime.CreationDate"
          : fallback
            ? "file_modified"
            : "unknown",
    time_confidence: taken ? "high" : fallback ? "low" : "unknown",
    latitude: raw.latitude ?? (coordinates ? +coordinates[1] : null),
    longitude: raw.longitude ?? (coordinates ? +coordinates[2] : null),
    altitude,
    width: raw.ImageWidth || raw.ExifImageWidth || dimensions.width || null,
    height: raw.ImageHeight || raw.ExifImageHeight || dimensions.height || null,
    duration_ms: raw.Duration ? Math.round(raw.Duration * 1000) : null,
    device_make: raw.Make || raw["com.apple.quicktime.make"] || null,
    device_model: raw.Model || raw["com.apple.quicktime.model"] || null,
  };
}
export type Inspected = Awaited<ReturnType<typeof inspectFile>>;
