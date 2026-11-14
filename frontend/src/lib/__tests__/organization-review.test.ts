// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import OrganizationReview from "../../components/OrganizationReview.vue";
import { api, put } from "../api";
vi.mock("../api", () => ({ api: vi.fn(), put: vi.fn(), post: vi.fn(), localDate: (v: string) => v }));
vi.mock("../../stores/yearly", () => ({ useYearly: () => ({ children: [{ id: 7, name: "家人甲", profile_type: "person" }] }) }));
vi.mock("../../components/MediaViewer.vue", () => ({ default: { props: ["media"], template: '<div class="source-test">{{ media.id }}</div>' } }));
vi.mock("../../components/MotionDialog.vue", () => ({ default: { props: ["modelValue", "title"], template: '<div v-if="modelValue" role="dialog"><slot /></div>' } }));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount(); document.body.innerHTML = ""; vi.resetAllMocks(); });
const entry = { id: 31, kind: "tags", status: "automatic", automatic: true, media: { id: 42, tags: ["原有", "公园"], timeline_day: "2026-11-13", files: [] }, before: { tags: ["原有"] }, proposed: { tags: ["公园"] }, current: { tags: ["公园"], decisions: { 公园: "公园" } }, names: {}, thumbnail: "", frame_seconds: null, evidence: { tags: [{ name: "公园", evidence: "在公园散步", rule: "default" }] }, events: [{ action: "automatic", at: "2026-11-13T10:00:00", actor_name: "自动整理", value: { tags: ["公园"] } }], created_at: "2026-11-13T10:00:00", updated_at: "2026-11-13T10:00:00" };
const button = (host: HTMLElement, label: string) => [...host.querySelectorAll<HTMLButtonElement>("button")].find(b => b.textContent?.trim() === label)!;
async function mount(items = [entry]) {
  vi.mocked(api).mockImplementation(async path => path.startsWith("/organization/settings") ? { tags_enabled: true, people_enabled: true, tag_rules: {}, person_rules: {} } : { items, pending: items.filter(item => item.kind !== "tags").length, next_cursor: null, errors: [] });
  const host = document.createElement("div"); document.body.append(host); app = createApp(OrganizationReview); app.mount(host);
  await vi.waitFor(() => expect(host.querySelectorAll(".organization-entry")).toHaveLength(items.length)); await nextTick(); return host;
}
it("shows automatic tag evidence and source and keeps an edited habit on failure", async () => {
  const host = await mount();
  expect(button(host, "保留结果")).toBeUndefined();
  expect(host.textContent).toContain("已自动确认");
  expect(host.textContent).toContain("在公园散步"); expect(host.textContent).toContain("原有标签");
  button(host, "查看来源照片或视频").click(); await nextTick(); expect(host.querySelector('[role="dialog"]')?.textContent).toContain("42");
  const input = host.querySelector<HTMLInputElement>('[aria-label="修改标签 公园"]')!;
  input.value = "户外"; input.dispatchEvent(new Event("input"));
  const remember = host.querySelector<HTMLInputElement>(".remember input")!; remember.checked = true; remember.dispatchEvent(new Event("change")); await nextTick();
  vi.mocked(put).mockRejectedValueOnce(new Error("模拟失败")); button(host,"保存修改").click();
  await vi.waitFor(() => expect(host.querySelector('[role="alert"]')?.textContent).toContain("模拟失败"));
  expect(input.value).toBe("户外"); expect(remember.checked).toBe(true);
  expect(put).toHaveBeenLastCalledWith("/organization/reviews/31", { action: "correct", remember: true, tag_decisions: { 公园: "户外" } });
  vi.mocked(put).mockResolvedValue({}); button(host,"保存修改").click();
  await vi.waitFor(() => expect(host.textContent).toContain("审核已保存"));
});
it("withdraws the specific automatic result and allows looking through all records", async () => {
  const host = await mount(); vi.mocked(put).mockResolvedValue({}); button(host,"撤回这次结果").click();
  await vi.waitFor(() => expect(put).toHaveBeenCalledWith("/organization/reviews/31", expect.objectContaining({ action: "reject", remember: false })));
  const all = host.querySelector<HTMLInputElement>(".review-toolbar input")!; all.checked = true; all.dispatchEvent(new Event("change"));
  await vi.waitFor(() => expect(api).toHaveBeenCalledWith(expect.stringContaining("scope=all")));
});
it("renders the empty audit state and persists automatic organization settings", async () => {
  const host = await mount([]);
  await vi.waitFor(() => expect(host.textContent).toContain("当前没有待审核记录"));
  const automatic = host.querySelector<HTMLInputElement>(".habits input")!; automatic.checked = false; automatic.dispatchEvent(new Event("change")); await nextTick();
  vi.mocked(put).mockResolvedValue({ tags_enabled: false, people_enabled: true, tag_rules: {}, person_rules: {} }); button(host,"保存整理习惯").click();
  await vi.waitFor(() => expect(put).toHaveBeenCalledWith("/organization/settings", expect.objectContaining({ tags_enabled: false })));
});

it("keeps superseded history readable and directs edits to the current source", async () => {
  const host = await mount([{ ...entry, status: "superseded" }]);
  expect(host.textContent).toContain("此记录已有后续修改");
  expect(host.querySelector(".review-actions")).toBeNull();
  expect(host.querySelector(".source-entry")).not.toBeNull();
});

it("shows additional face matches returned by a review confirmation", async () => {
  const host=await mount([{ ...entry, kind: "face" }]); vi.mocked(put).mockResolvedValue({auto_linked:2});
  button(host,"保留结果").click();
  await vi.waitFor(() => expect(host.querySelector('[role="dialog"]')?.textContent).toContain("另外 2 张"));
});
