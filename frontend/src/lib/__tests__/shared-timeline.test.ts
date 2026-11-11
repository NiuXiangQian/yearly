// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import SharedTimeline from "../../views/SharedTimeline.vue";
import { api, post } from "../api";
import { clearMediaResources } from "../media-resource";
import { setLocale } from "../i18n";
vi.mock("vue-router", () => ({
  useRoute: () => ({ params: { token: "virtual" } }),
}));
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), notify: vi.fn() }));
vi.mock("../../components/SharedThumbnail.vue", () => ({
  default: { template: '<span class="thumbnail" />' },
}));
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
let app: ReturnType<typeof createApp> | undefined, host: HTMLElement;
const observers = new Map<Element, (entries: { isIntersecting: boolean }[]) => void>();
function intersect(element: Element) {
  observers.get(element)!([{ isIntersecting: true }]);
}
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
  vi.mocked(post).mockResolvedValue({ ok: true });
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false }));
  vi.stubGlobal("IntersectionObserver", class {
    target?: Element;
    constructor(private callback: (entries: { isIntersecting: boolean }[]) => void) {}
    observe(target: Element) { this.target = target; observers.set(target, this.callback); }
    disconnect() { if (this.target) observers.delete(this.target); }
  });
  vi.mocked(api).mockResolvedValue(response());
});
afterEach(() => {
  app?.unmount();
  clearMediaResources();
  document.body.innerHTML = "";
  vi.clearAllMocks();
  localStorage.clear();
  observers.clear();
  vi.unstubAllGlobals();
});
it("keeps the share title when changing language and restores page metadata on exit", async () => {
  document.title = "Site title";
  const meta = document.createElement("meta");
  meta.setAttribute("property", "og:title");
  meta.content = "Site metadata";
  document.head.append(meta);
  await mount();
  await vi.waitFor(() => expect(document.title).toBe("Family"));
  expect(meta.content).toBe("Family");
  setLocale("en");
  await nextTick();
  expect(document.title).toBe("Family");
  expect(meta.content).toBe("Family");
  app?.unmount();
  app = undefined;
  expect(document.title).toBe("Site title");
  expect(meta.content).toBe("Site metadata");
  meta.remove();
  setLocale("zh-CN");
});
it("provides a family-sharing title and the site logo for an untitled share", async () => {
  const data = response();
  data.share.title = "";
  vi.mocked(api).mockResolvedValue(data);
  await mount();
  await vi.waitFor(() => expect(document.title).toBe("我们的家庭时光"));
  expect(host.querySelector(".shared-brand img")?.getAttribute("src")).toBe("/share-logo.png");
});
it("shows the selected person's title and avatar and updates the expiry countdown", async () => {
  const timestamp = Date.now();
  const date = vi.spyOn(Date, "now").mockReturnValue(timestamp);
  const data = response();
  const share = { ...data.share, card_title: "小禾的时光", profile_name: "小禾", has_avatar: true,
    expires_at: new Date(timestamp + 7200000).toISOString() };
  vi.mocked(api).mockResolvedValue({ ...data, share });
  try {
    await mount();
    await vi.waitFor(() => expect(host.querySelector("h1")?.textContent).toBe("小禾的时光"));
    expect(document.title).toBe("小禾的时光");
    expect(host.querySelector(".shared-avatar")?.getAttribute("src")).toBe("/api/public/shares/virtual/avatar");
    expect(host.querySelector(".share-countdown time")?.textContent).toBe("02:00:00");
    date.mockReturnValue(timestamp + 1000);
    await vi.waitFor(() => expect(host.querySelector(".share-countdown time")?.textContent).toBe("01:59:59"), { timeout: 2000 });
  } finally {
    date.mockRestore();
  }
});
it("automatically fills a day at its end without a manual expand button", async () => {
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  expect(host.textContent).not.toContain("展开更多");
  vi.mocked(api).mockResolvedValueOnce({ items: items.slice(8), total: 12 });
  intersect(host.querySelector(".shared-day .scroll-loader")!);
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  expect(vi.mocked(api)).toHaveBeenLastCalledWith(
    "/public/shares/virtual/days/2024-01-02?offset=8&order=desc",
  );
  await vi.waitFor(() => expect(button("展开其余 4 项")).toBeDefined());
  button("展开其余 4 项").click();
  await nextTick();
  expect(host.querySelectorAll(".shared-card")).toHaveLength(13);
  expect(host.querySelector(".shared-day .scroll-loader")).toBeNull();
  expect(post).toHaveBeenCalledExactlyOnceWith("/public/shares/virtual/visits");
});

it("keeps loading while the day end stays visible and stops at its total", async () => {
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  vi.mocked(api)
    .mockResolvedValueOnce({ items: items.slice(8, 10), total: 12 })
    .mockResolvedValueOnce({ items: items.slice(10), total: 12 });
  intersect(host.querySelector(".shared-day .scroll-loader")!);
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  await vi.waitFor(() => expect(api).toHaveBeenCalledWith("/public/shares/virtual/days/2024-01-02?offset=10&order=desc"));
  await nextTick();
  expect(api).toHaveBeenCalledTimes(4);
});

it("preserves cards on a failed automatic page and retries only when requested", async () => {
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  vi.mocked(api).mockRejectedValueOnce(new Error("加载失败"));
  intersect(host.querySelector(".shared-day .scroll-loader")!);
  await vi.waitFor(() => expect(host.textContent).toContain("加载失败"));
  expect(host.querySelectorAll(".shared-card")).toHaveLength(9);
  await nextTick();
  expect(api).toHaveBeenCalledTimes(3);
  vi.mocked(api).mockResolvedValueOnce({ items: items.slice(8), total: 12 });
  button("重试").click();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
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
  expect(post).not.toHaveBeenCalled();
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
  reversed.days[0].items = items;
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
  expect(post).toHaveBeenCalledExactlyOnceWith("/public/shares/virtual/visits");
  vi.mocked(api).mockResolvedValueOnce({
    ...reversed,
    days: [],
    next_after: null,
  });
  intersect(host.querySelector("footer .scroll-loader")!);
  await vi.waitFor(() =>
    expect(api).toHaveBeenLastCalledWith(
      "/public/shares/virtual?order=asc&after=2024-01-02",
    ),
  );
});

it("keeps shared content readable when visit recording fails", async () => {
  vi.mocked(post).mockRejectedValue(new Error("网络不可用"));
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  expect(post).toHaveBeenCalledOnce();
  expect(host.textContent).not.toContain("网络不可用");
});

it("folds months without fetching media and preserves the fold when loading another page", async () => {
  vi.mocked(api).mockResolvedValueOnce({
    ...response(),
    days: response().days.map((day) => ({ ...day, total: day.items.length })),
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
  intersect(host.querySelector("footer .scroll-loader")!);
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
    await vi.waitFor(() => expect(
      [...host.querySelectorAll(".shared-day")].map((day) => day.getAttribute("data-day")),
    ).toEqual(["2024-01-02", "2024-01-01", "2023-12-31"]));
    expect(api).toHaveBeenCalledWith(
      "/public/shares/virtual?order=desc&anchor=2023-12-31",
    );
    expect(api).toHaveBeenCalledWith(
      "/public/shares/virtual?order=desc&backward=true&after=2023-12-31",
    );
    expect(rail.getAttribute("aria-valuetext")).toBe("2023-12-31");
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
    await vi.waitFor(() => expect(play).toHaveBeenCalledOnce());
    (document.querySelector(".live-photo-badge") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(play).toHaveBeenCalledTimes(2));
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

it("shows exact selection without implying a date range or month grouping, and keeps pagination", async () => {
  const data = { ...response(), share: { ...response().share, scope: "selection", selected_count: 12 } };
  data.days = [data.days[0]];
  vi.mocked(api).mockResolvedValue(data);
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(8));
  expect(host.textContent).toContain("指定影像分享");
  expect(host.querySelector(".shared-day h2")?.textContent).toBe("所选影像");
  expect(host.querySelector(".month-controls")).toBeNull();
  expect(host.querySelector(".shared-sort")).toBeNull();
  expect(host.querySelector(".rail-hint")).toBeNull();
  vi.mocked(api).mockResolvedValue({ items: items.slice(8), total: 12 });
  intersect(host.querySelector(".shared-day .scroll-loader")!);
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(12));
});

it("fills unfinished days when a fast scroll reaches the footer before loading later dates", async () => {
  vi.mocked(api).mockResolvedValue({ ...response(), next_before: "2024-01-01" });
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  vi.mocked(api)
    .mockResolvedValueOnce({ items: items.slice(8), total: 12 })
    .mockResolvedValueOnce({ ...response(), days: [], next_before: null });
  intersect(host.querySelector("footer .scroll-loader")!);
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(9));
  await vi.waitFor(() => expect(host.querySelector("footer .scroll-loader")).toBeNull());
  const calls = vi.mocked(api).mock.calls.map(([path]) => path);
  expect(calls.slice(-2)).toEqual([
    "/public/shares/virtual/days/2024-01-02?offset=8&order=desc",
    "/public/shares/virtual?order=desc&before=2024-01-01",
  ]);
});

it("automatically appends shared folder contents when its end becomes visible", async () => {
  const data = response();
  data.days = [{ day: "2024-01-02", total: 1, items: [{
    id: 90, kind: "folder", name: "合成文件夹", previews: [], media_count: 12,
  } as any] }];
  vi.mocked(api).mockResolvedValue(data);
  await mount();
  await vi.waitFor(() => expect(host.querySelectorAll(".shared-card")).toHaveLength(1));
  vi.mocked(api).mockResolvedValueOnce({ id: 90, name: "合成文件夹", items: items.slice(0, 8), total: 12 });
  (host.querySelector(".shared-card") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(document.querySelectorAll(".shared-folder-dialog .shared-card")).toHaveLength(8));
  vi.mocked(api).mockResolvedValueOnce({ id: 90, name: "合成文件夹", items: items.slice(8), total: 12 });
  intersect(document.querySelector(".shared-folder-dialog .scroll-loader")!);
  await vi.waitFor(() => expect(document.querySelectorAll(".shared-folder-dialog .shared-card")).toHaveLength(12));
  expect(api).toHaveBeenLastCalledWith("/public/shares/virtual/folders/90?offset=8&order=desc");
});
