// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import FolderPanel from "../../components/FolderPanel.vue";
import { api, post, put, notify } from "../api";
import * as reorder from "../reorder";

vi.mock("../../stores/yearly", () => ({
  useYearly: () => ({ canEdit: true, isAdmin: false, selected: [] }),
}));
vi.mock("vue-router", () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), put: vi.fn(), notify: vi.fn() }));
vi.mock("../../components/MediaCard.vue", () => ({
  default: {
    props: ["media"],
    emits: ["select"],
    template:
      '<article :data-media-id="media.id" @click="$emit(\'select\', media)" />',
  },
}));
vi.mock("../../components/MediaDetail.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("../../components/FolderMoveDialog.vue", () => ({
  default: { template: "<div />" },
}));
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
vi.mock("element-plus/es/components/popconfirm/style/css", () => ({}));

let app: ReturnType<typeof createApp>;
const closed = vi.fn();
const cards = () => [...document.querySelectorAll(".folder-media-grid > div")];
function drag(element: Element, type: string) {
  const event = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clientX", { value: 50 });
  element.dispatchEvent(event);
  return event;
}
beforeEach(async () => {
  vi.mocked(api).mockImplementation(async (path) =>
    path.startsWith("/folders/")
      ? { id: 90, name: "测试文件夹", timeline_day: "2026-11-06", share_allowed: true }
      : { items: [{ id: 10 }, { id: 11 }, { id: 12 }], total: 3 },
  );
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(FolderPanel, { id: 90, onClose: closed });
  app.mount(host);
  await vi.waitFor(() => expect(cards()).toHaveLength(3));
});
afterEach(() => {
  app.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
  vi.restoreAllMocks();
});

it("closes a regular user's folder after making it admin-only without reloading its denied detail", async () => {
  vi.mocked(put).mockResolvedValue({});
  [...document.querySelectorAll("button")].find(b => b.textContent?.trim() === "编辑文件夹")!.click();
  await nextTick();
  const checkbox = document.querySelector("input[type=checkbox]") as HTMLInputElement;
  checkbox.checked = false;
  checkbox.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  document.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  await vi.waitFor(() => expect(closed).toHaveBeenCalledOnce());
  expect(put).toHaveBeenCalledExactlyOnceWith("/folders/90", { name: "测试文件夹", share_allowed: false });
  expect(api).toHaveBeenCalledTimes(2);
  expect(notify).not.toHaveBeenCalled();
});

it("previews folder media immediately and restores cancelled dragging", async () => {
  const [source, target, last] = cards();
  drag(source, "dragstart");
  drag(target, "dragover");
  await nextTick();
  expect(cards()).toEqual([target, source, last]);
  expect(post).not.toHaveBeenCalled();
  drag(source, "dragend");
  await nextTick();
  expect(cards()).toEqual([source, target, last]);
  expect(post).not.toHaveBeenCalled();
});

it("does not restart folder reordering while hovering the same placement", async () => {
  const reorderSpy = vi.spyOn(reorder, "reorderItems");
  const [source, target] = cards();
  drag(source, "dragstart");
  drag(target, "dragover");
  await nextTick();
  drag(target, "dragenter");
  await nextTick();
  drag(target, "dragover");
  await nextTick();
  expect(reorderSpy).toHaveBeenCalledTimes(1);
  expect(post).not.toHaveBeenCalled();
  drag(source, "dragend");
});

it("saves a previewed batch only on release and rolls back a failed save", async () => {
  let rejectSave!: (error: Error) => void;
  vi.mocked(post).mockImplementationOnce(
    () =>
      new Promise((_, reject) => {
        rejectSave = reject;
      }),
  );
  const [source, second, target] = cards();
  (source.querySelector("article") as HTMLElement).click();
  (second.querySelector("article") as HTMLElement).click();
  await nextTick();
  drag(source, "dragstart");
  drag(target, "dragover");
  await nextTick();
  expect(cards()).toEqual([target, source, second]);
  expect(post).not.toHaveBeenCalled();
  expect(drag(source, "dragenter").defaultPrevented).toBe(true);
  drag(source, "drop");
  drag(source, "dragend");
  await nextTick();
  expect(cards()).toEqual([target, source, second]);
  expect(post).toHaveBeenCalledExactlyOnceWith("/media/reorder", {
    media_ids: [10, 11],
    target_id: 12,
    placement: "after",
  });
  rejectSave(new Error("保存失败"));
  await vi.waitFor(() => {
    expect(cards()).toEqual([source, second, target]);
    expect(notify).toHaveBeenCalled();
  });
});
