// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import CompatibleImage from "../../components/CompatibleImage.vue";
import { heicPreview } from "../heic";

vi.mock("../heic", () => ({ heicPreview: vi.fn() }));
const applications: ReturnType<typeof createApp>[] = [];

afterEach(() => {
  applications.forEach((app) => app.unmount());
  applications.length = 0;
  document.body.innerHTML = "";
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

function render(props: any) {
  const host = document.createElement("div");
  document.body.append(host);
  const app = createApp(CompatibleImage, props);
  applications.push(app);
  app.mount(host);
  return host;
}

it("renders JPEG directly without decoding", () => {
  const host = render({ src: "/photo.jpg", file: { mime_type: "image/jpeg" } });
  expect(host.querySelector("img")?.getAttribute("src")).toBe("/photo.jpg");
  expect(heicPreview).not.toHaveBeenCalled();
});

it("renders a HEIC preview and releases its object URL on unmount", async () => {
  const blob = new Blob(["jpeg"], { type: "image/jpeg" });
  vi.mocked(heicPreview).mockResolvedValue(blob);
  const create = vi
    .spyOn(URL, "createObjectURL")
    .mockReturnValue("blob:preview");
  const revoke = vi.spyOn(URL, "revokeObjectURL");
  const host = render({
    src: "/photo.heic",
    file: { mime_type: "image/heic" },
  });
  await vi.waitFor(() =>
    expect(host.querySelector("img")?.src).toBe("blob:preview"),
  );
  expect(create).toHaveBeenCalledWith(blob);
  applications.pop()!.unmount();
  expect(revoke).toHaveBeenCalledWith("blob:preview");
});

it("keeps the existing fallback available when HEIC decoding fails", async () => {
  vi.mocked(heicPreview).mockRejectedValue(new Error("unsupported image"));
  const error = vi.fn();
  render({
    src: "/photo.heif",
    file: { original_filename: "photo.HEIF" },
    onError: error,
  });
  await vi.waitFor(() => expect(error).toHaveBeenCalledOnce());
});

it("discards a pending conversion after leaving the page", async () => {
  let finish!: (blob: Blob) => void;
  vi.mocked(heicPreview).mockReturnValue(
    new Promise((resolve) => {
      finish = resolve;
    }),
  );
  const create = vi.spyOn(URL, "createObjectURL");
  render({ src: "/photo.heic", file: { mime_type: "image/heic" } });
  applications.pop()!.unmount();
  finish(new Blob(["jpeg"]));
  await nextTick();
  expect(create).not.toHaveBeenCalled();
});
