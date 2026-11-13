// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, h, nextTick, ref } from "vue";
import MemoryInterview from "../../components/MemoryInterview.vue";
import { api, post } from "../api";
import type { InterviewState, ReviewMedia } from "../memory-review";
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), put: vi.fn() }));
vi.mock("../../components/ChildPicker.vue", () => ({ default: { template: '<div></div>', props: ['modelValue'] } }));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount(); document.body.innerHTML = ""; vi.resetAllMocks(); });
const media: ReviewMedia = { id: 42, title: "公园", media_type: "photo", timeline_day: "2026-11-13", taken_at_local: null, tags: ["原有"], remark: "原有小记", child_ids: [], files: [] };
function state(overrides: Partial<InterviewState> = {}): InterviewState {
  return { media, description: "在公园滑滑梯", confirmed_people: [], identity_questions: [], faces: [], face_enabled: true, face_ready: true,
    messages: [{ role: "assistant", content: "这次是谁一起去的？" }], status: "draft", outdated: false,
    suggestions: { question: "这次是谁一起去的？", options: ["奶奶一起去的"], story: "整理好的补充", tags: [{ name: "公园", source: "visual", evidence: "公园" }] }, ...overrides };
}
function button(host: HTMLElement, text: string) { return [...host.querySelectorAll("button")].find(b => b.textContent?.trim() === text)!; }
async function mount(value = state()) {
  vi.mocked(api).mockResolvedValue(value);
  const selected = ref(media), saved = vi.fn(), reviewPets = vi.fn();
  const host = document.createElement("div"); document.body.append(host);
  app = createApp({ render: () => h(MemoryInterview, { media: selected.value, revision: 0, onSaved: saved, onReviewPets: reviewPets }) });
  app.mount(host); await vi.waitFor(() => expect(host.textContent).toContain("这次是谁一起去的"));
  return { host, selected, saved, reviewPets };
}
it("reopens cached drafts without another model call and saves explicitly reviewed tags and additions", async () => {
  const { host, saved } = await mount();
  expect(post).not.toHaveBeenCalled();
  const note = host.querySelectorAll("textarea")[1];
  expect(note.value).toBe("整理好的补充");
  expect((host.querySelector('input[type="checkbox"]') as HTMLInputElement).checked).toBe(true);
  vi.mocked(post).mockResolvedValue(state({ status: "completed", suggestions: { ...state().suggestions!, story: "" }, media: { ...media, tags: ["原有", "公园"] } }));
  button(host, "保存标签与小记").click();
  await vi.waitFor(() => expect(saved).toHaveBeenCalledWith(42));
  expect(post).toHaveBeenCalledWith("/memory-interviews/42/apply", { tags: ["公园"], remark_addition: "整理好的补充" });
  expect(button(host, "保存标签与小记").disabled).toBe(true);
  vi.mocked(post).mockResolvedValue(state());
  button(host, "补充信息，完善标签").click();
  await vi.waitFor(() => expect(post).toHaveBeenCalledWith("/memory-interviews/42/prepare", { refresh: true }));
});
it("keeps an edited note while asking a followup and preserves reply text after a failure", async () => {
  const { host } = await mount();
  const [answer, note] = host.querySelectorAll("textarea");
  note.value = "我自己修改的小记"; note.dispatchEvent(new Event("input", { bubbles: true }));
  answer.value = "奶奶一起去的"; answer.dispatchEvent(new Event("input", { bubbles: true })); await nextTick();
  vi.mocked(post).mockRejectedValueOnce(new Error("网络暂时不可用"));
  button(host, "补充信息并更新标签").click();
  await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain("网络暂时不可用"));
  expect(answer.value).toBe("奶奶一起去的"); expect(note.value).toBe("我自己修改的小记");
  vi.mocked(post).mockResolvedValue(state({ messages: [...state().messages, { role: "user", content: "奶奶一起去的" }, { role: "assistant", content: "奶奶陪她玩了什么？" }], suggestions: { ...state().suggestions!, question: "奶奶陪她玩了什么？", story: "新的小记草稿" } }));
  button(host, "补充信息并更新标签").click();
  await vi.waitFor(() => expect(host.textContent).toContain("奶奶陪她玩了什么"));
  expect(answer.value).toBe(""); expect(note.value).toBe("我自己修改的小记");
  button(host, "使用新生成的小记草稿").click(); await nextTick();
  expect(note.value).toBe("新的小记草稿");
});
it("keeps per-memory edits when switching selection and honors IME composition in tag input", async () => {
  const { host, selected } = await mount();
  const answer = host.querySelector("textarea")!;
  answer.value = "尚未提交的故事"; answer.dispatchEvent(new Event("input", { bubbles: true })); await nextTick();
  selected.value = { ...media, id: 43 }; await nextTick(); await nextTick();
  selected.value = media; await nextTick(); await nextTick();
  expect(host.querySelector("textarea")!.value).toBe("尚未提交的故事");
  const input = host.querySelector('input[aria-label="补充标签"]') as HTMLInputElement;
  input.value = "滑梯"; input.dispatchEvent(new Event("input", { bubbles: true })); await nextTick();
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true })); await nextTick();
  expect(input.value).toBe("滑梯");
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); await nextTick();
  expect(input.value).toBe("");
  expect(host.querySelector('[aria-label="移除标签 滑梯"]')).not.toBeNull();
});
it("opens pet review for the selected media without generating an interview", async () => {
  const { host, reviewPets } = await mount();
  vi.mocked(post).mockResolvedValue({ dogs: [{}] });
  button(host, "查找这份影像中的狗狗").click();
  await vi.waitFor(() => expect(reviewPets).toHaveBeenCalledWith(42));
  expect(post).toHaveBeenCalledWith("/pets/media/42/analyze");
  expect(host.querySelector<HTMLTextAreaElement>('textarea[maxlength="4000"]')?.value).toBe("整理好的补充");
});
