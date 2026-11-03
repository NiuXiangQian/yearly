import { it, expect, vi } from "vitest";
import { directUpload } from "../upload";
import { fingerprints } from "../metadata";
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn() }));
import { api, post } from "../api";
it("retries a failed part and skips existing parts when resuming", async () => {
  const file = new File(["abcdefghijk"], "movie.mp4");
  const hash = await fingerprints(file);
  vi.mocked(api).mockResolvedValue({
    status: "uploading",
    parts: [{ number: 1, size: 4 }],
  });
  vi.mocked(post).mockImplementation(async (path) =>
    path.includes("/sign")
      ? { url: "https://private.invalid/part" }
      : { status: "complete" },
  );
  const sent: number[] = [];
  let attempts = 0;
  class XHR {
    status = 200;
    timeout = 0;
    upload: any = {};
    onload: any;
    onerror: any;
    ontimeout: any;
    open() {}
    send(block: Blob) {
      sent.push(block.size);
      queueMicrotask(() => {
        attempts++;
        if (attempts === 1) this.onerror();
        else {
          this.upload.onprogress({
            lengthComputable: true,
            loaded: block.size,
          });
          this.onload();
        }
      });
    }
  }
  vi.stubGlobal("XMLHttpRequest", XHR);
  vi.useFakeTimers();
  const run = directUpload(
    { id: "task", sha256: hash.sha256, file_size: file.size, part_size: 4 },
    { file, hash } as any,
    () => {},
  );
  await vi.runAllTimersAsync();
  await run;
  expect(sent).toEqual([4, 4, 3]);
  expect(
    vi.mocked(post).mock.calls.filter(([p]) => p.includes("/complete")).length,
  ).toBe(1);
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
it("rejects a changed source before uploading a resumed task", async () => {
  const file = new File(["original"], "photo.jpg");
  const hash = await fingerprints(file);
  await expect(
    directUpload(
      { id: "task", sha256: "different", file_size: file.size },
      { file, hash } as any,
      () => {},
    ),
  ).rejects.toThrow("SHA-256");
});
