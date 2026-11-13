// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, h } from "vue";
import PetReviewConsole from "../../components/PetReviewConsole.vue";
import { api, post, put } from "../api";
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), put: vi.fn(), del: vi.fn(), localDate: (v: string) => v }));
vi.mock("../../stores/yearly", () => ({ useYearly: () => ({ children: [
  { id: 7, name: "示例狗狗", profile_type: "pet", species: "狗" },
  { id: 8, name: "示例人物", profile_type: "person" },
] }) }));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount(); document.body.innerHTML = ""; vi.resetAllMocks(); });
const media = { id: 42, title: "虚拟狗狗照片", timeline_day: "2026-11-13", child_ids: [], files: [] };
const queue = { items: [{ media, dogs: [{ index: 0, child_id: null, ignored: false, appearance: "棕白色竖耳狗", thumbnail: "data:image/jpeg;base64,aA==", frame_seconds: null,
  candidates: [{ child_id: 7, name: "示例狗狗", similarity: .9, reference_thumbnail: "data:image/jpeg;base64,aA==" }] }] }], pending_pets: 1, unanalysed_media: 1, next_cursor: null };
function button(host: HTMLElement, text: string) { return [...host.querySelectorAll("button")].find(b => b.textContent?.trim() === text)!; }
async function mount() {
  vi.mocked(api).mockResolvedValue(queue);
  const saved = vi.fn(), choose = vi.fn(), host = document.createElement("div"); document.body.append(host);
  app = createApp({ render: () => h(PetReviewConsole, { all: false, onSaved: saved, onChoose: choose }) }); app.mount(host);
  await vi.waitFor(() => expect(host.textContent).toContain("棕白色竖耳狗"));
  return { host, saved, choose };
}
it("reads cached detections and requires explicit confirmation of a pet candidate", async () => {
  const { host, saved, choose } = await mount();
  expect(post).not.toHaveBeenCalled(); expect(put).not.toHaveBeenCalled();
  expect(host.querySelector("select")!.value).toBe("");
  expect(host.querySelector("select")!.textContent).not.toContain("示例人物");
  expect(button(host, "确认宠物").disabled).toBe(true);
  host.querySelector<HTMLButtonElement>(".pet-candidate")!.click();
  await vi.waitFor(() => expect(button(host,"确认宠物").disabled).toBe(false));
  vi.mocked(put).mockResolvedValue({});
  button(host,"确认宠物").click();
  await vi.waitFor(() => expect(put).toHaveBeenCalledWith("/pets/media/42/confirm", { index: 0, child_id: 7, ignored: false }));
  await vi.waitFor(() => expect(saved).toHaveBeenCalledWith(42));
  button(host,"查看照片与智能标签").click(); expect(choose).toHaveBeenCalledWith(media);
});
it("preserves a pending choice when pet analysis fails", async () => {
  const { host } = await mount();
  host.querySelector<HTMLButtonElement>(".pet-candidate")!.click();
  vi.mocked(post).mockRejectedValue(new Error("模拟分析失败"));
  button(host,"分析狗狗影像").click();
  await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain("模拟分析失败"));
  expect(host.querySelector("select")!.value).toBe("7"); expect(put).not.toHaveBeenCalled();
});
