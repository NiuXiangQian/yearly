// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import MediaViewer from "../../components/MediaViewer.vue";
import ImageViewer from "../../components/ImageViewer.vue";
import VideoPlayer from "../../components/VideoPlayer.vue";
import { mediaResource } from "../media-resource";
import { heicPreview } from "../heic";
vi.mock("../media-resource", () => ({ mediaResource: vi.fn() }));
vi.mock("../heic", () => ({ heicPreview: vi.fn() }));
const applications: ReturnType<typeof createApp>[] = [];
afterEach(() => {
  applications.forEach((app) => app.unmount());
  applications.length = 0;
  document.body.innerHTML = "";
  vi.clearAllMocks();
  vi.restoreAllMocks();
});
function render(component: any, props: any) {
  const host = document.createElement("div");
  document.body.append(host);
  const app = createApp(component, props);
  applications.push(app);
  app.mount(host);
  return host;
}
const photo = {
  id: 1,
  media_type: "photo",
  files: [
    {
      id: 2,
      file_role: "original",
      mime_type: "image/heic",
      original_filename: "photo.heic",
      file_size: 3000000,
    },
  ],
};
it("plays the paired motion preview from LIVE and returns to the still photo", async () => {
  vi.mocked(mediaResource).mockImplementation(async (_mid, fid, purpose) => ({
    url: fid === 3 && purpose === "preview" ? "/motion.mp4" : "/still.jpg",
    status: "ready",
  }));
  const play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
  const host = render(MediaViewer, { media: {
    ...photo, media_type: "live_photo",
    files: [...photo.files, { id: 3, file_role: "live_video", mime_type: "video/quicktime", file_size: 5000 }],
  } });
  await vi.waitFor(() => expect(host.querySelector("img")?.getAttribute("src")).toBe("/still.jpg"));
  (host.querySelectorAll(".viewer-live-tabs button")[1] as HTMLButtonElement).click();
  await vi.waitFor(() => expect(play).toHaveBeenCalledOnce());
  expect(host.querySelector("video")?.muted).toBe(true);
  expect(host.querySelector("video")?.getAttribute("src")).toBe("/motion.mp4");
  expect(mediaResource).not.toHaveBeenCalledWith(1, 3, "original");
  (host.querySelector(".viewer-live-tabs button") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(host.querySelector("img")?.getAttribute("src")).toBe("/still.jpg"));
  expect(host.querySelector("video")).toBeNull();
});
it("loads compressed HEIC previews without downloading or decoding the original; original is opt in", async () => {
  vi.mocked(mediaResource).mockImplementation(async (_mid, _fid, purpose) => ({
    url: `/${purpose}.webp`,
    status: "ready",
  }));
  vi.mocked(heicPreview).mockResolvedValue(new Blob(["jpeg"]));
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:original");
  const host = render(MediaViewer, { media: photo });
  await vi.waitFor(() =>
    expect(host.querySelector("img")?.getAttribute("src")).toBe(
      "/preview.webp",
    ),
  );
  expect(heicPreview).not.toHaveBeenCalled();
  expect(mediaResource).not.toHaveBeenCalledWith(1, 2, "original");
  (host.querySelector(".viewer-toolbar button") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(heicPreview).toHaveBeenCalledOnce());
  expect(mediaResource).toHaveBeenCalledWith(1, 2, "original");
});
it("pending videos keep their poster without falling back to original", async () => {
  vi.mocked(mediaResource).mockImplementation(async (_mid, _fid, purpose) =>
    purpose === "thumbnail"
      ? { url: "/poster.jpg", status: "ready" }
      : { url: null, status: "pending" },
  );
  const host = render(MediaViewer, {
    media: {
      ...photo,
      media_type: "video",
      files: [{ ...photo.files[0], mime_type: "video/quicktime" }],
    },
  });
  await vi.waitFor(() =>
    expect(host.textContent).toContain("视频预览正在准备"),
  );
  expect(host.querySelector("video")).toBeNull();
  expect(host.querySelector("img")?.getAttribute("src")).toBe("/poster.jpg");
  expect(mediaResource).not.toHaveBeenCalledWith(1, 2, "original");
});
it("zooms and restores image fit", async () => {
  const host = render(ImageViewer, { src: "/preview.webp" });
  (host.querySelector('[aria-label="放大"]') as HTMLButtonElement).click();
  await nextTick();
  expect(host.textContent).toContain("125%");
  expect(host.querySelector("img")?.style.transform).toContain("scale(1.25)");
  (host.querySelector('[aria-label="适应窗口"]') as HTMLButtonElement).click();
  await nextTick();
  expect(host.textContent).toContain("100%");
});
it("does not load video until play and exposes speed and seek controls", async () => {
  const loadSource = vi.fn().mockResolvedValue("/compressed.mp4");
  const play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
  const host = render(VideoPlayer, { loadSource, poster: "/poster.jpg" });
  expect(host.querySelector("video")?.hasAttribute("src")).toBe(false);
  expect(host.querySelector("video")?.preload).toBe("none");
  expect(loadSource).not.toHaveBeenCalled();
  (host.querySelector('[aria-label="播放视频"]') as HTMLButtonElement).click();
  await vi.waitFor(() => expect(play).toHaveBeenCalledOnce());
  expect(host.querySelector("video")?.getAttribute("src")).toBe(
    "/compressed.mp4",
  );
  const rate = host.querySelector("select")!;
  rate.value = "1.5";
  rate.dispatchEvent(new Event("change"));
  expect(host.querySelector("video")?.playbackRate).toBe(1.5);
  expect(host.querySelector('[aria-label="播放进度"]')).not.toBeNull();
});

it("expands within the window when native fullscreen is unavailable and exits without interrupting playback", async () => {
  const host = render(VideoPlayer, {
    loadSource: vi.fn().mockResolvedValue("/compressed.mp4"),
  });
  (host.querySelector('[aria-label="全屏"]') as HTMLButtonElement).click();
  await nextTick();
  expect(host.querySelector(".yearly-player.expanded")).not.toBeNull();
  expect(host.querySelector(".player-error")).toBeNull();
  (host.querySelector('[aria-label="退出全屏"]') as HTMLButtonElement).click();
  await nextTick();
  expect(host.querySelector(".yearly-player.expanded")).toBeNull();
});
