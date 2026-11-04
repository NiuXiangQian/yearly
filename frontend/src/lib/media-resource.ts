import { api } from "./api";

export type MediaResource = {
  url: string | null;
  status: "ready" | "pending" | "processing" | "failed";
  mime_type?: string;
  file_size?: number;
};
const cache = new Map<string, { expires: number; value: MediaResource }>();
export function clearMediaResources() {
  cache.clear();
}
export async function mediaResource(
  mid: number,
  fid: number,
  purpose: "thumbnail" | "preview" | "original",
) {
  const key = `${mid}/${fid}/${purpose}`;
  const cached = cache.get(key);
  if (cached && cached.expires > Date.now()) return cached.value;
  const value = await api<MediaResource>(
    `/media/${mid}/files/${fid}/url?purpose=${purpose}`,
  );
  if (value.url && purpose !== "original") {
    if (cache.size >= 200) cache.delete(cache.keys().next().value!);
    cache.set(key, { value, expires: Date.now() + 240_000 });
  }
  return value;
}
