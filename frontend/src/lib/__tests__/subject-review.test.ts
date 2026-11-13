// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import FaceConsole from "../../views/FaceConsole.vue";
import { api, put } from "../api";
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), put: vi.fn(), localDate: (v: string) => v }));
vi.mock("../../components/MediaCard.vue", () => ({ default: { template: "<div />" } }));
vi.mock("../../components/MediaViewer.vue", () => ({ default: { props: ["media", "initialSeconds"], template: '<div class="preview-test" :data-media="media.id" :data-seconds="initialSeconds" />' } }));
vi.mock("../../components/MemoryInterview.vue", () => ({ default: { template: "<div />" } }));
vi.mock("../../stores/yearly", () => ({ useYearly: () => ({ children: [
  { id: 7, name: "家人甲", profile_type: "person" }, { id: 8, name: "多多", profile_type: "pet", species: "狗" },
] }) }));
vi.mock("../../components/MotionDialog.vue", () => ({ default: {
  props: ["modelValue", "title"], emits: ["update:modelValue"],
  template: '<div v-if="modelValue" role="dialog" :aria-label="title"><slot /><slot name="footer" /><button aria-label="关闭预览" @click="$emit(\'update:modelValue\', false)">关闭</button></div>',
} }));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount(); document.body.innerHTML = ""; vi.resetAllMocks(); });
const media = { id: 42, title: "虚拟合照", timeline_day: "2026-11-13", child_ids: [], files: [] };
const face = { id: 21, media, thumbnail: "", child_id: null, ignored: false, frame_seconds: null, candidates: [{ child_id: 7, name: "家人甲", similarity: .9, reference_thumbnail: "" }] };
const dog = { index: 0, thumbnail: "", child_id: null, ignored: false, appearance: "浅色小狗", frame_seconds: null, candidates: [{ child_id: 8, name: "多多", similarity: .9, reference_thumbnail: "" }] };
const profiles = [{ id: 7, name: "家人甲", profile_type: "person" }, { id: 8, name: "多多", profile_type: "pet", species: "狗" }];
async function mount() {
  vi.mocked(api).mockImplementation(async path => path.startsWith("/faces/") ? { enabled: true, ready: true, message: "", items: [face], pending_faces: 1, pending_memories: 1, unanalysed_photos: 0, next_cursor: 21 }
    : path.startsWith("/pets/") ? { items: [{ media, dogs: [dog] }], pending_pets: 1, unanalysed_media: 0, next_cursor: null } : profiles);
  const host = document.createElement("div"); document.body.append(host); app = createApp(FaceConsole); app.mount(host);
  await vi.waitFor(() => expect(host.querySelectorAll(".review-face")).toHaveLength(2)); return host;
}
it("mixes people and pets in one queue, labels pet detections and confirms against the pet endpoint", async () => {
  const host = await mount();
  expect(host.querySelectorAll('[role="tab"]')).toHaveLength(3);
  expect(host.textContent).not.toContain("狗狗确认");
  const cards = [...host.querySelectorAll<HTMLElement>(".review-face")];
  const pet = cards.find(card => card.textContent!.includes("识别到宠物"))!;
  const person = cards.find(card => card.textContent!.includes("识别到人物"))!;
  expect(pet.querySelector("select")!.textContent).toContain("多多");
  expect(pet.querySelector("select")!.textContent).not.toContain("家人甲");
  expect(person.querySelector("select")!.textContent).not.toContain("多多");
  pet.querySelector<HTMLButtonElement>(".candidate-choice")!.click(); await nextTick();
  vi.mocked(put).mockRejectedValueOnce(new Error("模拟保存失败"));
  pet.querySelector<HTMLButtonElement>(".face-actions button")!.click();
  await vi.waitFor(() => expect(host.textContent).toContain("模拟保存失败"));
  expect(pet.querySelector("select")!.value).toBe("8"); expect(person.querySelector("select")!.value).toBe("");
  vi.mocked(put).mockResolvedValue({}); pet.querySelector<HTMLButtonElement>(".face-actions button")!.click();
  await vi.waitFor(() => expect(put).toHaveBeenLastCalledWith("/pets/media/42/confirm", { index: 0, child_id: 8, ignored: false }));
});
it("does not repeat a finished pet page while people continue to the next page", async () => {
  const host = await mount(); const before = vi.mocked(api).mock.calls.filter(([path]) => path.startsWith("/pets/review")).length;
  [...host.querySelectorAll<HTMLButtonElement>("button")].find(button => button.textContent?.trim() === "下一页")!.click();
  await vi.waitFor(() => expect(api).toHaveBeenCalledWith(expect.stringContaining("before=21")));
  expect(vi.mocked(api).mock.calls.filter(([path]) => path.startsWith("/pets/review"))).toHaveLength(before);
  await vi.waitFor(() => expect(host.querySelectorAll(".review-face")).toHaveLength(1));
});

it("opens source previews from either detection without discarding the selected identity", async () => {
  const host = await mount();
  const person = host.querySelector<HTMLElement>(".review-face")!;
  person.querySelector<HTMLButtonElement>(".candidate-choice")!.click(); await nextTick();
  person.querySelector<HTMLButtonElement>(".source-thumbnail")!.click(); await nextTick();
  expect(host.querySelector('[role="dialog"][aria-label="识别来源"] .preview-test')?.getAttribute("data-media")).toBe("42");
  host.querySelector<HTMLButtonElement>('[aria-label="关闭预览"]')!.click(); await nextTick();
  expect(person.querySelector("select")!.value).toBe("7");
  const pet = [...host.querySelectorAll<HTMLElement>(".review-face")].find(card => card.textContent!.includes("识别到宠物"))!;
  pet.querySelector<HTMLButtonElement>(".source-preview")!.click(); await nextTick();
  expect(host.querySelector('[role="dialog"][aria-label="识别来源"]')).not.toBeNull();
});
it("shows automatic matching counts after each confirmation and stays quiet for zero or old responses", async () => {
  const host = await mount();
  const person = host.querySelector<HTMLElement>(".review-face")!;
  person.querySelector<HTMLButtonElement>(".candidate-choice")!.click(); await nextTick();
  vi.mocked(put).mockResolvedValueOnce({ auto_linked: 3 });
  person.querySelector<HTMLButtonElement>(".face-actions button")!.click();
  await vi.waitFor(() => expect(host.querySelector('[role="dialog"][aria-label="已自动整理相似人脸"]')?.textContent).toContain("另外 3 张"));
  [...host.querySelectorAll<HTMLButtonElement>("button")].find(button => button.textContent?.trim() === "知道了")!.click(); await nextTick();
  for (const response of [{ auto_linked: 0 }, {}]) {
    person.querySelector<HTMLButtonElement>(".candidate-choice")!.click(); await nextTick();
    vi.mocked(put).mockResolvedValueOnce(response);
    person.querySelector<HTMLButtonElement>(".face-actions button")!.click();
    await vi.waitFor(() => expect(host.textContent).toContain("人物确认已保存。"));
    expect(host.querySelector('[role="dialog"][aria-label="已自动整理相似人脸"]')).toBeNull();
  }
});
