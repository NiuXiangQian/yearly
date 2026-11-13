// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import FaceReview from "../../components/FaceReview.vue";
import { api, post, put, del } from "../api";
import { locale } from "../i18n";
const { store } = vi.hoisted(() => ({ store: { children: [
  { id: 1, name: "小宝", profile_type: "child" },
  { id: 2, name: "奶奶", profile_type: "person" },
  { id: 9, name: "小猫", profile_type: "pet" },
] } }));
vi.mock("../../stores/yearly", () => ({ useYearly: () => store }));
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), put: vi.fn(), del: vi.fn() }));
vi.mock("../../components/MotionDialog.vue", () => ({ default: {
  props: ["modelValue", "title"], emits: ["update:modelValue"],
  template: '<div v-if="modelValue" role="dialog" :aria-label="title"><slot /><slot name="footer" /><button aria-label="关闭预览" @click="$emit(\'update:modelValue\', false)">关闭</button></div>',
} }));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount(); document.body.innerHTML = ""; vi.resetAllMocks(); locale.value = "zh-CN"; });
const image = "data:image/jpeg;base64,AAAA";
function state(overrides: Record<string, unknown> = {}) {
  return { enabled: true, ready: true, message: "", analyzed: true, reference_people: 1, child_ids: [7], faces: [
    { id: 21, thumbnail: image, frame_seconds: null, child_id: null, ignored: false,
      candidates: [{ child_id: 1, name: "小宝", similarity: 0.67, reference_thumbnail: image }] },
  ], ...overrides };
}
function button(host: HTMLElement, text: string) {
  return [...host.querySelectorAll("button")].find(b => b.textContent?.trim() === text)!;
}
async function mount(value = state()) {
  vi.mocked(api).mockResolvedValue(value);
  const updated = vi.fn(), processing = vi.fn();
  const host = document.createElement("div"); document.body.append(host);
  app = createApp(FaceReview, { mediaId: 42, linkedIds: [7, 9, 12], onUpdated: updated, onProcessing: processing });
  app.mount(host);
  expect(api).not.toHaveBeenCalled();
  button(host, "人脸匹配确认这里面有谁").click();
  await vi.waitFor(() => expect(api).toHaveBeenCalledWith("/faces/media/42"));
  await nextTick();
  return { host, updated, processing };
}
it("shows references without selecting automatically, and saves a reviewed identity while keeping draft/manual links", async () => {
  const second = { ...state().faces[0], id: 22 };
  const { host, updated } = await mount(state({ faces: [state().faces[0], second] }));
  const select = host.querySelector("select")!;
  expect(select.value).toBe("");
  expect([...select.options].map(o => o.text)).not.toContain("小猫");
  expect(host.textContent).toContain("可能是 小宝");
  expect(host.textContent).toContain("相似度 0.67");
  button(host, "选择").click(); await nextTick();
  expect(select.value).toBe("1"); expect(put).not.toHaveBeenCalled();
  vi.mocked(put).mockResolvedValue(state({ auto_linked: 2, child_ids: [7, 1], faces: [{ ...state().faces[0], child_id: 1, candidates: [] }] }));
  button(host, "确认人物").click();
  await vi.waitFor(() => expect(updated).toHaveBeenCalledWith([7, 9, 12, 1]));
  expect(put).toHaveBeenCalledWith("/faces/media/42/confirm", { assignments: [{ face_id: 21, child_id: 1, ignored: false }] });
  expect(host.textContent).toContain("另自动关联 2 张");
  expect(button(host, "确认人物").disabled).toBe(true);
});
it("keeps choices on a failed confirmation and supports ignoring a face", async () => {
  const { host } = await mount();
  const select = host.querySelector("select")!;
  select.value = "ignore"; select.dispatchEvent(new Event("change")); await nextTick();
  vi.mocked(put).mockRejectedValueOnce(new Error("保存失败，请重试"));
  button(host, "确认人物").click();
  await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain("保存失败"));
  expect(select.value).toBe("ignore");
  expect(put).toHaveBeenCalledWith("/faces/media/42/confirm", { assignments: [{ face_id: 21, child_id: null, ignored: true }] });
});
it("shows a cached empty result without analyzing again, and clearing requires an explicit action", async () => {
  const { host, updated } = await mount(state({ faces: [], child_ids: [7] }));
  expect(host.textContent).toContain("未检测到清晰人脸");
  expect(post).not.toHaveBeenCalled();
  button(host, "清除本影像的人脸样本").click(); await nextTick();
  expect(del).not.toHaveBeenCalled();
  vi.mocked(del).mockResolvedValue(state({ analyzed: false, faces: [], child_ids: [7] }));
  button(host, "清除样本").click();
  await vi.waitFor(() => expect(updated).toHaveBeenCalled());
  expect(del).toHaveBeenCalledWith("/faces/media/42");
  expect(host.textContent).toContain("查找这份影像中的人脸");
});
it("explains disabled setup and translates the review controls", async () => {
  const { host } = await mount(state({ enabled: false, analyzed: false, faces: [], message: "人脸匹配尚未启用" }));
  expect(button(host, "查找这份影像中的人脸").disabled).toBe(true);
  expect(host.textContent).toContain("人脸匹配尚未启用");
  locale.value = "en"; await nextTick();
  expect(host.textContent).toContain("Face matching");
  expect(host.textContent).toContain("Face matching is not enabled");
});

it("refreshes cached faces without clearing reviewed identities, and protects unsaved choices", async () => {
  const { host, updated } = await mount(state({ refresh_supported: true }));
  const refresh = button(host, "重新查找人脸");
  expect(refresh.disabled).toBe(false);
  button(host, "选择").click(); await nextTick();
  expect(refresh.disabled).toBe(true);
  const select = host.querySelector("select")!;
  select.value = ""; select.dispatchEvent(new Event("change")); await nextTick();
  vi.mocked(post).mockResolvedValue(state({ refresh_supported: true, child_ids: [7, 2], faces: [
    state().faces[0], { ...state().faces[0], id: 22, child_id: 2 },
  ] }));
  refresh.click();
  await vi.waitFor(() => expect(post).toHaveBeenCalledWith("/faces/media/42/analyze", { refresh: true }));
  await vi.waitFor(() => expect(host.querySelectorAll("select")).toHaveLength(2));
  expect(del).not.toHaveBeenCalled();
  expect(updated).toHaveBeenCalledWith([7, 9, 12, 2]);
  locale.value = "en"; await nextTick();
  expect(host.textContent).toContain("Find faces again");
});

it("hides refresh for older servers", async () => {
  const { host } = await mount();
  expect(button(host, "重新查找人脸")).toBeUndefined();
});

it("retains cached faces when refreshing fails", async () => {
  const { host } = await mount(state({ refresh_supported: true }));
  vi.mocked(post).mockRejectedValueOnce(new Error("重新查找失败"));
  button(host, "重新查找人脸").click();
  await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain("重新查找失败"));
  expect(host.querySelectorAll("select")).toHaveLength(1);
  expect(del).not.toHaveBeenCalled();
  expect(button(host, "重新查找人脸").disabled).toBe(false);
});
