// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import LivePhotoViewer from "../../components/LivePhotoViewer.vue";
let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  vi.useRealTimers();
  vi.restoreAllMocks();
});
async function render(loadMotion = vi.fn().mockResolvedValue({ url: "/motion.mp4", status: "ready" })) {
  const play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
  const pause = vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(LivePhotoViewer, { src: "/photo.jpg", loadMotion });
  app.mount(host);
  await Promise.resolve(); await Promise.resolve(); await nextTick();
  return { host, play, pause, loadMotion, stage: host.querySelector(".live-photo")!, video: host.querySelector("video")! };
}
function pointer(target: Element | Window, type: string, values: Record<string, unknown> = {}) {
  const event = new Event(type);
  Object.assign(event, { pointerType: "touch", pointerId: 1, isPrimary: true, button: 0, clientX: 50, clientY: 50 }, values);
  target.dispatchEvent(event);
}
it("loads no video bytes before interaction and only fades the still once playback starts", async () => {
  const { host, stage, video, play } = await render();
  expect(video.preload).toBe("none");
  expect(video.hasAttribute("src")).toBe(false);
  expect(video.muted).toBe(false);
  expect(video.hasAttribute("playsinline")).toBe(true);
  expect(play).not.toHaveBeenCalled();
  pointer(stage, "pointerenter", { pointerType: "mouse" });
  expect(play).toHaveBeenCalledOnce();
  await nextTick();
  expect(stage.classList.contains("is-playing")).toBe(false);
  video.dispatchEvent(new Event("playing"));
  await nextTick();
  expect(stage.classList.contains("is-playing")).toBe(true);
  expect(host.querySelector(".live-photo-img")?.getAttribute("src")).toBe("/photo.jpg");
  video.dispatchEvent(new Event("ended"));
  await nextTick();
  expect(stage.classList.contains("is-playing")).toBe(false);
});
it("primes synchronously on touch, reveals after a hold and stops when the finger is released", async () => {
  vi.useFakeTimers();
  const { stage, video, play, pause } = await render();
  pointer(stage, "pointerdown");
  expect(play).toHaveBeenCalledOnce();
  expect(video.muted).toBe(false);
  Object.defineProperty(video, "paused", { configurable: true, value: false });
  Object.defineProperty(video, "readyState", { configurable: true, value: 3 });
  video.dispatchEvent(new Event("playing"));
  await nextTick();
  expect(stage.classList.contains("is-playing")).toBe(false);
  await vi.advanceTimersByTimeAsync(180);
  expect(stage.classList.contains("is-playing")).toBe(true);
  pointer(window, "pointerup");
  await nextTick();
  expect(stage.classList.contains("is-playing")).toBe(false);
  expect(pause).toHaveBeenCalled();
});
it.each(["move", "cancel", "second finger", "release"])("cancels %s and ignores delayed playing events", async (action) => {
  vi.useFakeTimers();
  const { stage, video } = await render();
  pointer(stage, "pointerdown");
  if (action === "move") pointer(stage, "pointermove", { clientX: 70 });
  if (action === "cancel") pointer(stage, "pointercancel");
  if (action === "second finger") pointer(stage, "pointerdown", { pointerId: 2, isPrimary: false });
  if (action === "release") pointer(window, "pointerup");
  await vi.advanceTimersByTimeAsync(250);
  video.dispatchEvent(new Event("playing"));
  await nextTick();
  expect(stage.classList.contains("is-playing")).toBe(false);
});
it("does not start after a cancelled gesture whose signed URL arrived late", async () => {
  let resolve!: (value: any) => void;
  const { stage, play } = await render(vi.fn(() => new Promise(r => { resolve = r; })));
  pointer(stage, "pointerdown");
  pointer(window, "pointerup");
  resolve({ url: "/late.mp4", status: "ready" });
  await Promise.resolve(); await Promise.resolve(); await nextTick();
  expect(play).not.toHaveBeenCalled();
});
it("keeps the photo for pending previews, polls and requires a new gesture to play", async () => {
  vi.useFakeTimers();
  const load = vi.fn().mockResolvedValueOnce({ url: null, status: "pending" })
    .mockResolvedValue({ url: "/ready.mp4", status: "ready" });
  const { host, video, play } = await render(load);
  expect(host.textContent).toContain("动态预览正在准备");
  expect(video.hasAttribute("src")).toBe(false);
  await vi.advanceTimersByTimeAsync(15_000);
  expect(video.hasAttribute("src")).toBe(false);
  expect(play).not.toHaveBeenCalled();
  (host.querySelector(".live-photo-badge") as HTMLButtonElement).click();
  expect(play).toHaveBeenCalledOnce();
  expect(video.getAttribute("src")).toBe("/ready.mp4");
});
it("refreshes the signed preview on error retry without replacing the still", async () => {
  const load = vi.fn().mockResolvedValueOnce({ url: "/expired.mp4", status: "ready" })
    .mockResolvedValue({ url: "/renewed.mp4", status: "ready" });
  const { host, video, play } = await render(load);
  video.dispatchEvent(new Event("error"));
  await nextTick();
  expect(host.textContent).toContain("动态暂时无法播放");
  (host.querySelector(".live-photo-badge") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(play).toHaveBeenCalledOnce());
  expect(load).toHaveBeenLastCalledWith(true);
  expect(video.getAttribute("src")).toBe("/renewed.mp4");
  expect(host.querySelector("img")?.getAttribute("src")).toBe("/photo.jpg");
});
it("shows retry when playback is blocked, and stops playback on background/unmount", async () => {
  const { host, video, play, pause, loadMotion } = await render();
  play.mockRejectedValueOnce(new DOMException("NotAllowed", "NotAllowedError"));
  (host.querySelector(".live-photo-badge") as HTMLButtonElement).click();
  await Promise.resolve(); await nextTick();
  expect(host.textContent).toContain("轻点 LIVE 播放有声实况");
  expect(video.muted).toBe(false);
  (host.querySelector(".live-photo-badge") as HTMLButtonElement).click();
  expect(play).toHaveBeenCalledTimes(2);
  expect(loadMotion).toHaveBeenCalledTimes(1);
  window.dispatchEvent(new Event("blur"));
  expect(pause).toHaveBeenCalled();
  app.unmount();
  expect(video.hasAttribute("src")).toBe(false);
});
it("times out buffering and cleans up pending polling when closed", async () => {
  vi.useFakeTimers();
  const { host } = await render();
  (host.querySelector(".live-photo-badge") as HTMLButtonElement).click();
  await vi.advanceTimersByTimeAsync(20_000);
  expect(host.textContent).toContain("动态暂时无法播放");
  app.unmount();
  expect(vi.getTimerCount()).toBe(0);
});

it("restarts from zero on every photo or LIVE click, including while playing and after ending", async () => {
  const { host, stage, video, play } = await render();
  for (const target of [stage, host.querySelector(".live-photo-badge")!, stage]) {
    video.currentTime = 1.5;
    target.dispatchEvent(new MouseEvent("click"));
    expect(video.currentTime).toBe(0);
    video.dispatchEvent(new Event("playing"));
    await nextTick();
    expect(stage.classList.contains("is-playing")).toBe(true);
  }
  expect(play).toHaveBeenCalledTimes(3);
  video.dispatchEvent(new Event("ended"));
  stage.dispatchEvent(new MouseEvent("click"));
  expect(play).toHaveBeenCalledTimes(4);
});
it("does not restart after a long press or a scrolling gesture generates a click", async () => {
  vi.useFakeTimers();
  const { stage, play } = await render();
  pointer(stage, "pointerdown");
  await vi.advanceTimersByTimeAsync(180);
  pointer(window, "pointerup");
  stage.dispatchEvent(new MouseEvent("click"));
  expect(play).toHaveBeenCalledTimes(1);
  pointer(stage, "pointerdown");
  pointer(stage, "pointermove", { clientX: 70 });
  pointer(window, "pointerup");
  stage.dispatchEvent(new MouseEvent("click"));
  expect(play).toHaveBeenCalledTimes(2);
});
