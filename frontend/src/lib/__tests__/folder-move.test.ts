// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, h, nextTick, ref } from "vue";
import FolderMoveDialog from "../../components/FolderMoveDialog.vue";
import { api, post } from "../api";
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), notify: vi.fn() }));
let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
});
it("moves a selected batch into a sibling folder and back to the day root", async () => {
  vi.mocked(api).mockResolvedValue([
    { id: 7, name: "第一天" },
    { id: 8, name: "家人合影" },
  ]);
  vi.mocked(post).mockResolvedValue({ ok: true });
  const open = ref(false),
    saved = vi.fn();
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    render: () =>
      h(FolderMoveDialog, {
        open: open.value,
        day: "2026-03-26",
        ids: [11, 12],
        currentFolder: 7,
        onSaved: saved,
        onClose: () => {
          open.value = false;
        },
      }),
  });
  app.mount(host);
  open.value = true;
  await vi.waitFor(() =>
    expect(document.querySelectorAll("select option")).toHaveLength(2),
  );
  expect(api).toHaveBeenCalledWith("/folders?day=2026-03-26");
  const select = document.querySelector("select")!;
  expect(select.textContent).not.toContain("第一天");
  select.value = "8";
  select.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  (
    document.querySelector(".dialog-actions button") as HTMLButtonElement
  ).click();
  await vi.waitFor(() => expect(saved).toHaveBeenCalledOnce());
  expect(post).toHaveBeenLastCalledWith("/folders/move-media", {
    media_ids: [11, 12],
    folder_id: 8,
  });
  open.value = true;
  await nextTick();
  await vi.waitFor(() =>
    expect(
      (document.querySelector(".dialog-actions button") as HTMLButtonElement)
        .disabled,
    ).toBe(false),
  );
  expect((document.querySelector("select") as HTMLSelectElement).value).toBe(
    "",
  );
  (
    document.querySelector(".dialog-actions button") as HTMLButtonElement
  ).click();
  await vi.waitFor(() => expect(saved).toHaveBeenCalledTimes(2));
  expect(post).toHaveBeenLastCalledWith("/folders/move-media", {
    media_ids: [11, 12],
    folder_id: null,
  });
});
