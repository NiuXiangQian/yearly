// @vitest-environment happy-dom
import { createApp, nextTick } from "vue";
import { afterEach, expect, it, vi } from "vitest";
import CurationConsole from "../../views/CurationConsole.vue";
import { api, post } from "../api";
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn() }));
vi.mock("../../stores/yearly", () => ({ useYearly: () => ({ children: [{ id: 7, name: "合成档案" }] }) }));
vi.mock("../../components/MediaCard.vue", () => ({ default: { template: '<div class="media-card-test" />' } }));
vi.mock("../../components/MediaViewer.vue", () => ({ default: { template: '<div />' } }));
vi.mock("../../components/OrganizationReview.vue", () => ({ default: { template: '<div />' } }));
vi.mock("../../components/MotionDialog.vue", () => ({ default: { template: '<div />' } }));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount();document.body.innerHTML = "";vi.resetAllMocks(); });
const item = (id: number) => ({ media: { id, title: `影像${id}`, child_ids: [], files: [], media_type: "photo" }, disposition: "pending", quality: null });
async function mount() {
  vi.mocked(api).mockResolvedValue({ items: [{ key: "2", kind: "duplicate", items: [item(1), item(2)] }], next_cursor: null, unfiled_media: 2, group_count: 1, total_media: 2, quality_enabled: true });
  const host=document.createElement("div");document.body.append(host);app=createApp(CurationConsole);app.mount(host);
  await vi.waitFor(() => expect(host.querySelectorAll(".group")).toHaveLength(1));return host;
}
function button(host: HTMLElement, label: string) { return [...host.querySelectorAll<HTMLButtonElement>('button')].find(b => b.textContent?.trim() === label)!; }
it("collapses a duplicate group and applies one explicit batch to its selected media", async () => {
  const host=await mount();
  expect(host.querySelectorAll('.media-card-test')).toHaveLength(1);
  button(host,"展开检查").click();await nextTick();
  expect(host.querySelectorAll('.media-card-test')).toHaveLength(2);
  host.querySelector<HTMLInputElement>('.group > header input')!.click();
  host.querySelector<HTMLInputElement>('fieldset input')!.click();await nextTick();
  vi.mocked(post).mockResolvedValue({ count: 2, undo_token: "batch-token" });
  button(host,"添加关联并完成").click();
  await vi.waitFor(() => expect(post).toHaveBeenCalledWith('/curation/batch',{ media_ids: [1,2], child_ids: [7], action: 'add' }));
  await vi.waitFor(() => expect(host.textContent).toContain('已处理 2 份影像'));
  button(host,"撤销上次整理").click();
  await vi.waitFor(() => expect(post).toHaveBeenCalledWith('/curation/undo/batch-token'));
});
it("preserves selection after a failed batch and never calls identity endpoints", async () => {
  const host=await mount();host.querySelector<HTMLInputElement>('.item-choice input')!.click();await nextTick();
  vi.mocked(post).mockRejectedValue(new Error('保存失败'));
  button(host,'略过所选').click();await vi.waitFor(() => expect(host.textContent).toContain('保存失败'));
  expect(host.querySelector<HTMLInputElement>('.item-choice input')!.checked).toBe(true);
  expect(vi.mocked(post).mock.calls.every(([url]) => url.startsWith('/curation/'))).toBe(true);
});
it("replaces a source thumbnail with a full-frame quality representative without changing selection", async () => {
  const host=await mount();host.querySelector<HTMLInputElement>('.item-choice input')!.click();await nextTick();
  vi.mocked(post).mockResolvedValue({ frames: [{ frame:0, clarity:4, reason:'画面清楚', blurred:false, face_visibility:'none' }], representative:0, seconds:[null], thumbnail:'data:image/jpeg;base64,test' });
  button(host,'大模型画质复核').click();
  await vi.waitFor(() => expect(host.querySelector('.representative img')).not.toBeNull());
  expect(post).toHaveBeenCalledWith('/curation/media/1/quality');
  expect(host.querySelector<HTMLInputElement>('.item-choice input')!.checked).toBe(true);
});
