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
  return [...host.querySelectorAll("button")].find((b) =>
    b.textContent?.includes(text),
  )!;
}
beforeEach(() => {
  vi.mocked(api).mockResolvedValue(response());
});
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
});
it("shows eight entries per day and keeps the next day readable; expands and collapses", async () => {
  await mount();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(9),
  );
  expect(vi.mocked(api)).toHaveBeenCalledWith("/public/shares/virtual");
  vi.mocked(api).mockResolvedValueOnce({ items: items.slice(8), total: 12 });
  button("展开更多").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(13),
  );
  expect(vi.mocked(api)).toHaveBeenLastCalledWith(
    "/public/shares/virtual/days/2024-01-02?offset=8",
  );
  button("收起").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(9),
  );
  button("展开更多").click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".shared-card")).toHaveLength(13),
  );
  expect(vi.mocked(api)).toHaveBeenCalledTimes(2);
});
it("displays an unavailable share without private navigation or sign-in", async () => {
  vi.mocked(api).mockRejectedValue(new Error("分享已失效或不存在"));
  await mount();
  await vi.waitFor(() =>
    expect(host.textContent).toContain("请联系分享者获取新的链接"),
  );
  expect(host.querySelectorAll(".shared-card")).toHaveLength(0);
  expect(vi.mocked(api)).toHaveBeenCalledTimes(1);
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
