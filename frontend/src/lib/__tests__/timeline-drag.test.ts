// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import Timeline from "../../views/Timeline.vue";
import { api, post, notify } from "../api";
import * as reorder from "../reorder";
const family = vi.hoisted(() => ({
  canEdit: true,
  selected: [],
  children: [],
  stats: { media: 2, events: 0, children: 0 },
}));
vi.mock("../../stores/yearly", () => ({ useYearly: () => family }));
vi.mock("vue-router", () => ({
  useRoute: () => ({ path: "/", query: {}, meta: {} }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock("../api", () => ({
  api: vi.fn(),
  post: vi.fn(),
  notify: vi.fn(),
  localDate: (d: string) => d,
}));
vi.mock("../../components/MediaCard.vue", () => ({
  default: {
    props: ["media", "selection"],
    emits: ["select", "open"],
    template:
      "<article :data-media-id=\"media.id\" @click=\"$emit(selection ? 'select' : 'open', media)\">{{ media.id }}</article>",
  },
}));
vi.mock("../../components/MediaDetail.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("../../components/EventEditor.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("../../components/ChildPicker.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("../../components/FolderPanel.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("../../components/FolderMoveDialog.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
vi.mock("element-plus/es/components/popconfirm/style/css", () => ({}));
let app: ReturnType<typeof createApp>, host: HTMLElement;
function drag(el: Element, type: string, x = 50, y = 50) {
  const e = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperties(e, {
    dataTransfer: { value: { setData: vi.fn(), effectAllowed: "" } },
    clientX: { value: x },
    clientY: { value: y },
  });
  el.dispatchEvent(e);
  return e;
}
function button(text: string) {
  return [...document.querySelectorAll("button")].find(
    (b) => b.textContent?.trim() === text,
  )!;
}
async function mount() {
  host = document.createElement("div");
  document.body.append(host);
  app = createApp(Timeline);
  app.component("RouterLink", { template: "<a><slot/></a>" });
  app.mount(host);
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".timeline-entry")).toHaveLength(4),
  );
}
beforeEach(() => {
  family.canEdit = true;
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      observe() {}
      disconnect() {}
    },
  );
  vi.mocked(api).mockResolvedValue({
    items: [
      {
        id: 90,
        kind: "folder",
        name: "同日文件夹",
        timeline_day: "2024-03-31",
        media_count: 1,
        previews: [{ id: 12, folder_id: 90, kind: "media", files: [] }],
      },
      { id: 10, kind: "media", timeline_day: "2024-03-31", files: [] },
      { id: 11, kind: "media", timeline_day: "2024-03-31", files: [] },
      {
        id: 91,
        kind: "folder",
        name: "另一天",
        timeline_day: "2024-03-30",
        media_count: 0,
      },
    ],
    total: 4,
    next_cursor: null,
  });
  vi.mocked(post).mockResolvedValue({ ok: true });
});
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
it("drags a selected same-day batch into a highlighted folder without entering sort mode", async () => {
  await mount();
  button("多选").click();
  await nextTick();
  (host.querySelector('[data-media-id="10"]') as HTMLElement).click();
  (host.querySelector('[data-media-id="11"]') as HTMLElement).click();
  await nextTick();
  const source = host.querySelector('[data-media-id="10"]')!.parentElement!;
  expect(source.getAttribute("draggable")).toBe("true");
  const folder = host.querySelector(
    '[aria-label="打开文件夹 同日文件夹"]',
  )!.parentElement!;
  drag(source, "dragstart");
  drag(folder, "dragover");
  await nextTick();
  expect(folder.classList.contains("drop-into-folder")).toBe(true);
  expect(
    folder.querySelector(".day-folder-card")?.getAttribute("title"),
  ).toContain("松开移入 2 份影像");
  drag(folder, "drop");
  drag(source, "dragend");
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/folders/move-media", {
      media_ids: [10, 11],
      folder_id: 90,
    }),
  );
});
it("reorders on direct drag and rejects dragging to another day", async () => {
  await mount();
  const source = host.querySelector('[data-media-id="10"]')!.parentElement!;
  const anotherDay = host.querySelector(
    '[aria-label="打开文件夹 另一天"]',
  )!.parentElement!;
  drag(source, "dragstart");
  expect(drag(anotherDay, "dragover").defaultPrevented).toBe(false);
  drag(anotherDay, "drop");
  expect(post).not.toHaveBeenCalled();
  const target = host.querySelector('[data-media-id="11"]')!.parentElement!;
  drag(target, "dragover");
  drag(target, "drop");
  drag(source, "dragend");
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/timeline/reorder", {
      items: [{ kind: "media", id: 10 }],
      target: { kind: "media", id: 11 },
      placement: "after",
    }),
  );
});
it("offers a day-scoped reset and prevents read-only dragging", async () => {
  await mount();
  button("恢复默认排序").click();
  await vi.waitFor(() => expect(button("恢复排序")).toBeDefined());
  button("恢复排序").click();
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/media/reset-order", {
      day: "2024-03-31",
    }),
  );
  app.unmount();
  host.remove();
  family.canEdit = false;
  await mount();
  vi.mocked(post).mockClear();
  const source = host.querySelector('[data-media-id="10"]')!.parentElement!;
  expect(source.getAttribute("draggable")).toBe("false");
  expect(drag(source, "dragstart").defaultPrevented).toBe(true);
  expect(post).not.toHaveBeenCalled();
});

it("drags a folder thumbnail back to its day", async () => {
  await mount();
  const source = host.querySelector('[aria-label="拖动影像 12"]')!;
  drag(source, "dragstart");
  await nextTick();
  const dropZone = host.querySelector(".day-drop-out")!;
  expect(dropZone.textContent).toContain("松开移回当天时间线");
  drag(dropZone, "drop");
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/folders/move-media", {
      media_ids: [12],
      folder_id: null,
    }),
  );
  await vi.waitFor(() =>
    expect(host.querySelector(".day-drop-out")).toBeNull(),
  );
});
it("moves a folder thumbnail out before reordering against a loose image", async () => {
  await mount();
  const source = host.querySelector('[aria-label="拖动影像 12"]')!;
  const target = host.querySelector('[data-media-id="10"]')!.parentElement!;
  drag(source, "dragstart");
  drag(target, "dragover");
  drag(target, "drop");
  drag(source, "dragend");
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/timeline/reorder", {
      items: [{ kind: "media", id: 12 }],
      target: { kind: "media", id: 10 },
      placement: "after",
    }),
  );
  expect(vi.mocked(post).mock.calls[0]).toEqual([
    "/folders/move-media",
    { media_ids: [12], folder_id: null },
  ]);
});

it("inserts a folder between media with a visible placement indicator", async () => {
  await mount();
  const source = host.querySelector(
    '[aria-label="打开文件夹 同日文件夹"]',
  )!.parentElement!;
  const target = host.querySelector('[data-media-id="10"]')!.parentElement!;
  drag(source, "dragstart");
  drag(target, "dragover");
  await nextTick();
  expect(target.classList.contains("drop-after")).toBe(true);
  expect([...host.querySelectorAll(".timeline-entry")].indexOf(source)).toBe(1);
  expect(post).not.toHaveBeenCalled();
  drag(target, "drop");
  drag(source, "dragend");
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/timeline/reorder", {
      items: [{ kind: "folder", id: 90 }],
      target: { kind: "media", id: 10 },
      placement: "after",
    }),
  );
  expect(post).not.toHaveBeenCalledWith(
    "/folders/move-media",
    expect.anything(),
  );
});
it("uses the final grid position during animation and ignores repeated hover updates", async () => {
  await mount();
  const reorderSpy = vi.spyOn(reorder, "reorderItems");
  const source = host.querySelector('.day-folder-card')!.parentElement!;
  const target = host.querySelector('[data-media-id="10"]')!.parentElement!;
  target.style.transform = "matrix(1, 0, 0, 1, -50, 0)";
  const bounds = vi.spyOn(target, "getBoundingClientRect").mockReturnValue({
    left: 0, top: 0, width: 100, height: 100,
  } as DOMRect);
  drag(source, "dragstart");
  // The card animates across the pointer, but its final slot starts at x = 50.
  drag(target, "dragenter", 25);
  await nextTick();
  expect(reorderSpy).not.toHaveBeenCalled();
  drag(target, "dragover", 75);
  await nextTick();
  expect(target.classList.contains("drop-before")).toBe(true);
  expect(reorderSpy).toHaveBeenCalledTimes(1);
  target.style.transform = "matrix(1, 0, 0, 1, -20, 0)";
  bounds.mockReturnValue({left: 30, top: 0, width: 100, height: 100} as DOMRect);
  drag(target, "dragover", 75);
  drag(target, "dragenter", 75);
  await nextTick();
  expect(reorderSpy).toHaveBeenCalledTimes(1);
  expect(target.classList.contains("drop-before")).toBe(true);
  expect(post).not.toHaveBeenCalled();
  drag(source, "dragend");
});

it("keeps the preview on drop while saving, then restores it if saving fails", async () => {
  let rejectSave!: (error: Error) => void;
  vi.mocked(post).mockImplementationOnce(
    () =>
      new Promise((_, reject) => {
        rejectSave = reject;
      }),
  );
  await mount();
  const source = host.querySelector('[data-media-id="10"]')!.parentElement!;
  const target = host.querySelector('[data-media-id="11"]')!.parentElement!;
  const original = [...host.querySelectorAll(".timeline-entry")];
  drag(source, "dragstart");
  drag(target, "dragover");
  await nextTick();
  expect([...host.querySelectorAll(".timeline-entry")]).toEqual([
    original[0],
    target,
    source,
    original[3],
  ]);
  expect(post).not.toHaveBeenCalled();
  // The reordered source now occupies the pointer's position.
  expect(drag(source, "dragenter").defaultPrevented).toBe(true);
  drag(source, "drop");
  drag(source, "dragend");
  await nextTick();
  expect(post).toHaveBeenCalledTimes(1);
  expect([...host.querySelectorAll(".timeline-entry")][2]).toBe(source);
  rejectSave(new Error("保存失败"));
  await vi.waitFor(() => {
    expect([...host.querySelectorAll(".timeline-entry")]).toEqual(original);
    expect(notify).toHaveBeenCalled();
  });
});
it("restores a cancelled drag without saving and previews selected media in order", async () => {
  await mount();
  button("多选").click();
  await nextTick();
  (host.querySelector('[data-media-id="10"]') as HTMLElement).click();
  (host.querySelector('[data-media-id="11"]') as HTMLElement).click();
  await nextTick();
  const original = [...host.querySelectorAll(".timeline-entry")];
  const [folder, source, second] = original;
  vi.spyOn(folder, "getBoundingClientRect").mockReturnValue({
    left: 0,
    width: 100,
  } as DOMRect);
  drag(source, "dragstart");
  drag(folder, "dragover", 5);
  await nextTick();
  expect([...host.querySelectorAll(".timeline-entry")]).toEqual([
    source,
    second,
    folder,
    original[3],
  ]);
  drag(source, "dragend");
  await nextTick();
  expect([...host.querySelectorAll(".timeline-entry")]).toEqual(original);
  expect(post).not.toHaveBeenCalled();
});
it("inserts a photo at a folder edge instead of moving it into the folder", async () => {
  await mount();
  const source = host.querySelector('[data-media-id="10"]')!.parentElement!;
  const target = host.querySelector(
    '[aria-label="打开文件夹 同日文件夹"]',
  )!.parentElement!;
  vi.spyOn(target, "getBoundingClientRect").mockReturnValue({
    left: 0,
    width: 100,
  } as DOMRect);
  drag(source, "dragstart");
  drag(target, "dragover", 5);
  await nextTick();
  expect(target.classList.contains("drop-before")).toBe(true);
  expect(target.classList.contains("drop-into-folder")).toBe(false);
  drag(target, "drop");
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/timeline/reorder", {
      items: [{ kind: "media", id: 10 }],
      target: { kind: "folder", id: 90 },
      placement: "before",
    }),
  );
});

it("uses one date mode at a time, including leap days and year boundaries", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2024, 1, 29, 12));
  try {
    await mount();
    const lastRange = () =>
      new URLSearchParams(
        String(vi.mocked(api).mock.calls.at(-1)?.[0]).split("?")[1],
      );
    button("今天").click();
    await nextTick();
    expect(lastRange().get("start")).toBe("2024-02-29T00:00:00");
    expect(lastRange().get("end")).toBe("2024-03-01T00:00:00");
    button("按月").click();
    await nextTick();
    expect(lastRange().get("start")).toBe("2024-02-01T00:00:00");
    expect(lastRange().get("end")).toBe("2024-03-01T00:00:00");
    button("全部时间").click();
    await nextTick();
    expect(lastRange().has("start")).toBe(false);
    expect(lastRange().has("end")).toBe(false);
    vi.setSystemTime(new Date(2024, 11, 31, 12));
    button("本月").click();
    await nextTick();
    (
      host.querySelector('[aria-label="下一段日期"]') as HTMLButtonElement
    ).click();
    await nextTick();
    expect(lastRange().get("start")).toBe("2025-01-01T00:00:00");
    expect(lastRange().get("end")).toBe("2025-02-01T00:00:00");
    button("按年").click();
    await nextTick();
    expect(lastRange().get("start")).toBe("2025-01-01T00:00:00");
    expect(lastRange().get("end")).toBe("2026-01-01T00:00:00");
  } finally {
    vi.useRealTimers();
  }
});
