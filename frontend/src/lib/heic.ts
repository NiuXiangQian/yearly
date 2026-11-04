import { t } from "./i18n";
// Decode one full-resolution image at a time to limit memory use in a gallery.
let decoding: Promise<unknown> = Promise.resolve();
const previews = new Map<string, Promise<Blob>>();

export function heicPreview(source: string, key: string): Promise<Blob> {
  const cached = previews.get(key);
  if (cached) return cached;
  const result = decoding.then(async () => {
    const response = await fetch(source);
    if (!response.ok)
      throw new Error(t("照片读取失败 ({p0})", { p0: response.status }));
    const { heicTo } = await import("heic-to/csp");
    return heicTo({
      blob: await response.blob(),
      type: "image/jpeg",
      quality: 0.88,
    });
  });
  // Reuse previews for duplicate originals and the detail viewer.
  if (previews.size >= 24) previews.delete(previews.keys().next().value!);
  previews.set(key, result);
  decoding = result.catch(() => {
    previews.delete(key);
  });
  return result;
}
