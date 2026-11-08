import { afterEach, expect, it, vi } from "vitest";
import { api } from "../api";
import { clearMediaResources, mediaResource } from "../media-resource";
vi.mock("../api", () => ({ api: vi.fn() }));
afterEach(() => { clearMediaResources(); vi.clearAllMocks(); });
it("refreshes a failed signed URL even while its preview cache entry is valid", async () => {
  vi.mocked(api).mockResolvedValueOnce({ url: "/expired.mp4", status: "ready" })
    .mockResolvedValueOnce({ url: "/fresh.mp4", status: "ready" });
  await mediaResource(1, 3, "preview");
  expect((await mediaResource(1, 3, "preview")).url).toBe("/expired.mp4");
  expect(api).toHaveBeenCalledTimes(1);
  expect((await mediaResource(1, 3, "preview", true)).url).toBe("/fresh.mp4");
  expect((await mediaResource(1, 3, "preview")).url).toBe("/fresh.mp4");
  expect(api).toHaveBeenCalledTimes(2);
  expect(api).toHaveBeenLastCalledWith("/media/1/files/3/url?purpose=preview");
});
it("does not cache pending motion or fall back to original", async () => {
  vi.mocked(api).mockResolvedValueOnce({ url: null, status: "pending" })
    .mockResolvedValueOnce({ url: "/ready.mp4", status: "ready" });
  expect((await mediaResource(1, 3, "preview")).status).toBe("pending");
  expect((await mediaResource(1, 3, "preview")).url).toBe("/ready.mp4");
  expect(api).toHaveBeenCalledTimes(2);
  expect(api).not.toHaveBeenCalledWith(expect.stringContaining("original"));
});
