import { api } from "./api";
import { cacheScope, cacheRevision, cachedImage, saveCachedImage } from "./local-cache";

export type MediaResource = {
  url: string | null;
  status: "ready" | "pending" | "processing" | "failed" | "archived" | "restoring";
  message?: string;
  mime_type?: string;
  file_size?: number;
};
const cache = new Map<string, { expires: number; value: MediaResource }>();
const pending = new Map<string, Promise<MediaResource>>();
const references = new Map<string, number>();
function retain(value: MediaResource) {
  if (value.url?.startsWith("blob:"))
    references.set(value.url, (references.get(value.url) ?? 0) + 1);
  return value;
}
export function releaseMediaResource(url: string | null | undefined) {
  if (!url?.startsWith("blob:")) return;
  const remaining = (references.get(url) ?? 1) - 1;
  if (remaining > 0) { references.set(url, remaining); return; }
  references.delete(url);
  URL.revokeObjectURL(url);
  for (const [key, entry] of cache)
    if (entry.value.url === url) cache.delete(key);
}
export function clearMediaResources() {
  for (const url of references.keys()) URL.revokeObjectURL(url);
  references.clear();
  cache.clear();
  pending.clear();
}
export async function cachedMediaResource(
  path: string,
  image: boolean,
  refresh = false,
): Promise<MediaResource> {
  const scope = cacheScope(path);
  const key = `${scope}|${path}`;
  const cached = cache.get(key);
  if (!refresh && cached && cached.expires > Date.now()) return retain(cached.value);
  if (!refresh && pending.has(key)) return retain(await pending.get(key)!);
  const revision = cacheRevision();
  const request = (async () => {
    let value: MediaResource;
    const blob = !refresh && scope ? await cachedImage(scope, path) : undefined;
    if (blob) value = { url: URL.createObjectURL(blob), status: "ready", mime_type: blob.type };
    else {
      value = await api<MediaResource>(path);
      if (value.url && (image || value.mime_type?.startsWith("image/")) && scope) {
        try {
          const response = await fetch(value.url, { credentials: "omit", referrerPolicy: "no-referrer" });
          if (response.ok && response.headers.get("Content-Type")?.startsWith("image/")) {
            const downloaded = await response.blob();
            if (revision === cacheRevision() && scope === cacheScope(path)) {
              await saveCachedImage(scope, path, downloaded);
              value = { ...value, url: URL.createObjectURL(downloaded) };
            }
          }
        } catch { /* Images can still use their authorized URL if CORS prevents blob storage. */ }
      }
    }
    if (value.url && revision === cacheRevision() && scope === cacheScope(path)) {
      if (cache.size >= 200) {
        const oldest = cache.keys().next().value!;
        const url = cache.get(oldest)?.value.url;
        if (url?.startsWith("blob:") && !references.has(url)) URL.revokeObjectURL(url);
        cache.delete(oldest);
      }
      cache.set(key, {
        value,
        expires: Date.now() + (value.url.startsWith("blob:") ? 7 * 24 * 60 * 60_000 : 240_000),
      });
    }
    return value;
  })();
  pending.set(key, request);
  try { return retain(await request); }
  finally { if (pending.get(key) === request) pending.delete(key); }
}
export async function mediaResource(
  mid: number,
  fid: number,
  purpose: "thumbnail" | "preview" | "original",
  refresh = false,
) {
  const path = `/media/${mid}/files/${fid}/url?purpose=${purpose}`;
  if (purpose === "original") return api<MediaResource>(path);
  return cachedMediaResource(path, purpose === "thumbnail", refresh);
}
