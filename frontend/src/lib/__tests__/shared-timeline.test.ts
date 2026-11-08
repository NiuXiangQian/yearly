// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createApp } from "vue";
import SharedTimeline from "../../views/SharedTimeline.vue";
import { api } from "../api";
vi.mock("vue-router", () => ({
  useRoute: () => ({ params: { token: "virtual" } }),
}));
vi.mock("../api", () => ({ api: vi.fn(), notify: vi.fn() }));
vi.mock("../../components/SharedThumbnail.vue", () => ({
  default: { template: '<span class="thumbnail" />' },
}));
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
let app: ReturnType<typeof createApp>, host: HTMLElement;
const items = Array.from({ length: 12 }, (_, i) => ({
  id: i + 1,
  kind: "media",
  media_type: "photo",
  title: "Memory " + i,
}));
function response() {
  return {
    dates: ["2024-01-01", "2024-01-02"],
    share: {
      title: "Family",
      start_date: "2024-01-01",
      end_date: "2024-01-02",
      expires_at: new Date(Date.now() + 3600000).toISOString(),
    },
    days: [
      { day: "2024-01-02", total: 12, items: items.slice(0, 8) },
      { day: "2024-01-01", total: 1, items: [items[0]] },
    ],
    next_before: null,
  };
}
async function mount() {
  host = document.createElement("div");
  document.body.append(host);
  app = createApp(SharedTimeline);
  app.mount(host);
  await vi.waitFor(() => expect(vi.mocked(api)).toHaveBeenCalled());
}
function button(text: string) {
  const buttons = [...host.querySelectorAll("button")];
  return (buttons.find((b) => b.textContent?.trim() === text) ||
    buttons.find((b) => b.textContent?.includes(text)))!;
}
beforeEach(() => {
  vi.mocked(api).mockResolvedValue(response());
});
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
  localStorage.clear();
});
it("shows eight entries per day and keeps the next day readable; expands and collapses", async () => {
  await mount();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(9),
  );
  expect(vi.mocked(api)).toHaveBeenCalledWith(
    "/public/shares/virtual?order=desc",
  );
  vi.mocked(api).mockResolvedValueOnce({ items: items.slice(8), total: 12 });
  button("展开更多").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(13),
  );
  expect(vi.mocked(api)).toHaveBeenLastCalledWith(
    "/public/shares/virtual/days/2024-01-02?offset=8&order=desc",
  );
  button("收起").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(9),
  );
  button("展开更多").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(13),
  );
  expect(vi.mocked(api)).toHaveBeenCalledTimes(3);
});
it("displays an unavailable share without private navigation or sign-in", async () => {
  vi.mocked(api).mockRejectedValue(new Error("分享已失效或不存在"));
  await mount();
  await vi.waitFor(() =>
    expect(host.textContent).toContain("请联系分享者获取新的链接"),
  );
  expect(host.querySelectorAll(".shared-card")).toHaveLength(0);
  expect(vi.mocked(api)).toHaveBeenCalledTimes(2);
  expect(host.textContent).not.toContain("上传");
});
it("clears content once the link expires while the page remains open", async () => {
  const data = response();
  data.share.expires_at = new Date(Date.now() + 300).toISOString();
  vi.mocked(api).mockResolvedValue(data);
  await mount();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(9),
  );
  await vi.waitFor(() =>
    expect(host.textContent).toContain("分享已失效或不存在"),
  );
  expect(host.querySelectorAll(".shared-card")).toHaveLength(0);
});

it("switches chronological direction and paginates using the corresponding day cursor", async () => {
  await mount();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-day")).toHaveLength(2),
  );
  const reversed = response();
  reversed.days.reverse();
  vi.mocked(api).mockResolvedValueOnce({
    ...reversed,
    next_before: null,
    next_after: "2024-01-02",
  });
  button("最早在前").click();
  await vi.waitFor(() =>
    expect(host.querySelector(".shared-day h2")?.textContent).toBe(
      "2024.01.01",
    ),
  );
  expect(api).toHaveBeenCalledWith("/public/shares/virtual?order=asc");
  expect(localStorage.getItem("yearly-shared-order")).toBe("asc");
  vi.mocked(api).mockResolvedValueOnce({
    ...reversed,
    days: [],
    next_after: null,
  });
  button("更晚的日子").click();
  await vi.waitFor(() =>
    expect(api).toHaveBeenLastCalledWith(
      "/public/shares/virtual?order=asc&after=2024-01-02",
    ),
  );
});

it("folds months without fetching media and preserves the fold when loading another page", async () => {
  vi.mocked(api).mockResolvedValueOnce({
    ...response(),
    next_before: "2024-01-01",
  });
  await mount();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(9),
  );
  button("全部收起").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(0),
  );
  expect(api).toHaveBeenCalledTimes(2);
  vi.mocked(api).mockResolvedValueOnce({
    ...response(),
    days: [{ day: "2023-12-31", total: 1, items: [items[0]] }],
  });
  button("更早的日子").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".timeline-month")).toHaveLength(2),
  );
  expect(host.querySelectorAll(".shared-card")).toHaveLength(0);
  button("2023年12月").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(1),
  );
  expect(api).toHaveBeenCalledTimes(3);
});

it("reveals a folded date and fetches an unloaded date only on navigation", async () => {
  const data = {
    ...response(),
    dates: ["2023-12-31", "2024-01-01", "2024-01-02"],
  };
  vi.mocked(api).mockResolvedValue(data);
  const scroll = vi.fn();
  host = document.createElement("div");
  const original = HTMLElement.prototype.scrollIntoView;
  HTMLElement.prototype.scrollIntoView = scroll;
  try {
    await mount();
    await vi.waitFor(() =>
      expect(host.querySelectorAll(".shared-day")).toHaveLength(2),
    );
    button("全部收起").click();
    await vi.waitFor(() =>
      expect(host.querySelectorAll(".shared-day")).toHaveLength(0),
    );
    const rail = host.querySelector('[role="slider"]')!;
    rail.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
    );
    await vi.waitFor(() => expect(scroll).toHaveBeenCalled());
    expect(host.querySelectorAll(".shared-day")).toHaveLength(2);
    expect(api).toHaveBeenCalledTimes(2);
    vi.mocked(api).mockResolvedValueOnce({
      ...data,
      days: [{ day: "2023-12-31", total: 1, items: [items[0]] }],
    });
    rail.dispatchEvent(
      new KeyboardEvent("keydown", { key: "End", bubbles: true }),
    );
    await vi.waitFor(() =>
      expect(host.querySelector(".shared-day")?.getAttribute("data-day")).toBe(
        "2023-12-31",
      ),
    );
    expect(api).toHaveBeenCalledWith(
      "/public/shares/virtual?order=desc&anchor=2023-12-31",
    );
    expect(scroll).toHaveBeenCalledTimes(2);
  } finally {
    HTMLElement.prototype.scrollIntoView = original;
  }
});

it("plays layered Live Photos using only share-authorized preview URLs", async () => {
  const data = response();
  data.days = [{ day: "2024-01-02", total: 1, items: [{ ...items[0], media_type: "live_photo" }] }];
  vi.mocked(api).mockImplementation(async (path) => {
    if (path.includes("/url?")) return { url: path.endsWith("live=true") ? "/motion.mp4" : "/still.jpg", status: "ready" };
    return data;
  });
  const play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
  try {
    await mount();
    await vi.waitFor(() => expect(host.querySelector(".shared-card")).not.toBeNull());
    (host.querySelector(".shared-card") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(document.querySelector(".live-photo-img")?.getAttribute("src")).toBe("/still.jpg"));
    expect(play).not.toHaveBeenCalled();
    (document.querySelector(".live-photo-badge") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(play).toHaveBeenCalledOnce());
    expect(document.querySelector(".live-photo-video")?.getAttribute("src")).toBe("/motion.mp4");
    expect(api).toHaveBeenCalledWith("/public/shares/virtual/media/1/url?purpose=preview&live=true");
    expect(vi.mocked(api).mock.calls.every(([path]) => path.startsWith("/public/shares/virtual"))).toBe(true);
  } finally { play.mockRestore(); }
});

it.each(["photo", "video", "live_photo"])("opens a shared %s fullscreen immediately, including while its preview loads", async (mediaType) => {
  const data = response();
  data.days = [{ day: "2024-01-02", total: 1, items: [{ ...items[0], media_type: mediaType }] }];
  vi.mocked(api).mockImplementation(async (path) => {
    if (path.includes("/url?")) return new Promise(() => {});
    return data;
  });
  await mount();
  await vi.waitFor(() => expect(host.querySelector(".shared-card")).not.toBeNull());
  (host.querySelector(".shared-card") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(document.querySelector(".shared-viewer-dialog.is-fullscreen")).not.toBeNull());
  expect(document.querySelector(".shared-media-fullscreen")?.textContent).toContain("正在加载预览");
  (document.querySelector(".shared-media-fullscreen .el-dialog__headerbtn") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(document.querySelector(".shared-viewer")).toBeNull());
  expect(host.querySelectorAll(".shared-card")).toHaveLength(1);
});
