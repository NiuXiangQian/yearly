// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import Children from "../../views/Children.vue";
import { post, put } from "../api";
import { directUpload } from "../upload";

const family = vi.hoisted(() => ({
  canEdit: true,
  isAdmin: true,
  selected: [],
  children: [
    { id: 7, name: "宝宝", birthday: "2024-03-31", avatar_media_id: null },
  ],
  load: vi.fn(),
}));
vi.mock("vue-router", () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock("../../stores/yearly", () => ({ useYearly: () => family }));
vi.mock("../../components/ChildAvatar.vue", () => ({
  default: { template: "<span>头像</span>" },
}));
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
vi.mock("element-plus/es/components/select/style/css", () => ({}));
vi.mock("element-plus/es/components/option/style/css", () => ({}));
vi.mock("../api", () => ({
  api: vi.fn(),
  post: vi.fn(),
  put: vi.fn(),
  del: vi.fn(),
  notify: vi.fn(),
  localDate: (v: string) => v,
}));
vi.mock("../metadata", () => ({
  inspectFile: async (file: File) => ({
    file,
    hash: { sha256: "hash", crc64: "1" },
  }),
}));
vi.mock("../upload", () => ({ directUpload: vi.fn() }));
let app: ReturnType<typeof createApp>;
const draw = vi.fn();
function button(text: string) {
  return [...document.querySelectorAll("button")].find(
    (b) => b.textContent?.trim() === text,
  )!;
}
async function choose() {
  const input = document.querySelector('input[type="file"]')!;
  Object.defineProperty(input, "files", {
    value: [new File(["photo"], "portrait.jpg", { type: "image/jpeg" })],
    configurable: true,
  });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() =>
    expect(document.querySelector('img[alt="新头像预览"]')).not.toBeNull(),
  );
}
beforeEach(async () => {
  vi.stubGlobal(
    "createImageBitmap",
    vi.fn().mockResolvedValue({ width: 1200, height: 800, close: vi.fn() }),
  );
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
    drawImage: draw,
  } as any);
  vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation(
    (callback) => callback(new Blob(["small-avatar"], { type: "image/jpeg" })),
  );
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:avatar");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  vi.mocked(post).mockResolvedValue({
    media_id: 90,
    tasks: [{ id: "avatar-task" }],
  });
  vi.mocked(put).mockResolvedValue({});
  vi.mocked(directUpload).mockResolvedValue(undefined);
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Children);
  app.mount(host);
  (
    document.querySelector('[aria-label="编辑孩子档案"]') as HTMLButtonElement
  ).click();
  await nextTick();
});
afterEach(() => {
  app.unmount();
  document.body.innerHTML = "";
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});
it("previews a square compressed avatar locally and cancels without uploading", async () => {
  await choose();
  expect(draw.mock.calls[0].slice(1)).toEqual([
    200, 0, 800, 800, 0, 0, 512, 512,
  ]);
  expect(post).not.toHaveBeenCalled();
  button("取消").click();
  await nextTick();
  expect(post).not.toHaveBeenCalled();
  expect(URL.revokeObjectURL).toHaveBeenCalledWith("blob:avatar");
});
it("uploads only the compressed avatar before saving its reference", async () => {
  await choose();
  document
    .querySelector("form")!
    .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  await vi.waitFor(() => expect(put).toHaveBeenCalled());
  expect(post).toHaveBeenCalledWith(
    "/uploads",
    expect.objectContaining({ purpose: "avatar", media_type: "photo" }),
  );
  expect(vi.mocked(post).mock.calls[0][1].files[0].file_size).toBe(12);
  expect(directUpload).toHaveBeenCalledOnce();
  expect(put).toHaveBeenCalledWith(
    "/children/7",
    expect.objectContaining({ avatar_media_id: 90 }),
  );
  expect(family.load).toHaveBeenCalled();
});
it("does not change the saved avatar when upload fails, and lets the user retry", async () => {
  vi.mocked(directUpload).mockRejectedValueOnce(new Error("上传失败"));
  await choose();
  document
    .querySelector("form")!
    .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  await vi.waitFor(() => expect(directUpload).toHaveBeenCalled());
  await nextTick();
  expect(put).not.toHaveBeenCalled();
  expect(document.querySelector('img[alt="新头像预览"]')).not.toBeNull();
  document
    .querySelector("form")!
    .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  await vi.waitFor(() => expect(put).toHaveBeenCalled());
});
