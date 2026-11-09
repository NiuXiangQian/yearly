import { afterEach, expect, it, vi } from "vitest";
import { cachedMediaResource, clearMediaResources, releaseMediaResource } from "../media-resource";
import { cachedImage } from "../local-cache";
import { api } from "../api";
const state = vi.hoisted(() => ({ scope: "account:1" }));
vi.mock("../api", () => ({ api: vi.fn() }));
vi.mock("../local-cache", () => ({
  cacheScope: () => state.scope,
  cacheRevision: () => 0,
  cachedImage: vi.fn(async () => new Blob(["synthetic image"], { type: "image/png" })),
  saveCachedImage: vi.fn(),
}));
afterEach(() => {
  clearMediaResources();
  vi.clearAllMocks();
  vi.restoreAllMocks();
  state.scope = "account:1";
});
it("reuses persistent image bytes after clearing the memory cache without requesting another signed URL", async () => {
  const first = await cachedMediaResource("/media/1/files/2/url?purpose=thumbnail", true);
  expect(first.url).toMatch(/^blob:/);
  clearMediaResources();
  const next = await cachedMediaResource("/media/1/files/2/url?purpose=thumbnail", true);
  expect(next.url).toMatch(/^blob:/);
  expect(cachedImage).toHaveBeenCalledTimes(2);
  expect(api).not.toHaveBeenCalled();
});
it("keeps a shared thumbnail valid until both cards release it", async () => {
  const revoke = vi.spyOn(URL, "revokeObjectURL");
  const [first, second] = await Promise.all([
    cachedMediaResource("/same-thumbnail", true),
    cachedMediaResource("/same-thumbnail", true),
  ]);
  expect(first.url).toBe(second.url);
  expect(cachedImage).toHaveBeenCalledOnce();
  releaseMediaResource(first.url);
  expect(revoke).not.toHaveBeenCalled();
  releaseMediaResource(second.url);
  expect(revoke).toHaveBeenCalledExactlyOnceWith(second.url);
});
it("separates identical media IDs owned by different signed-in accounts", async () => {
  const first = await cachedMediaResource("/same-media-id", true);
  state.scope = "account:2";
  const second = await cachedMediaResource("/same-media-id", true);
  expect(second.url).not.toBe(first.url);
  expect(cachedImage).toHaveBeenLastCalledWith("account:2", "/same-media-id");
});
