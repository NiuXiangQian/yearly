// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import Upload from "../../views/Upload.vue";
import { api, post, notify } from "../api";
import { directUpload } from "../upload";
import { inspectFile } from "../metadata";

const routeInfo = vi.hoisted(() => ({
  query: { date: "2024-05-01" } as Record<string, string>,
}));
const metadataOverrides = vi.hoisted(() => ({}) as Record<string, any>);
const family = vi.hoisted(() => ({
  canEdit: true,
  children: [] as any[],
  selected: [] as number[],
  load: vi.fn(),
}));

vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
vi.mock("element-plus/es/components/progress/style/css", () => ({}));

vi.mock("vue-router", () => ({
  useRoute: () => routeInfo,
}));
vi.mock("../../stores/yearly", () => ({
  useYearly: () => family,
}));
vi.mock("../api", () => ({
  api: vi.fn().mockResolvedValue([]),
  post: vi.fn(),
  notify: vi.fn(),
  bytes: (n: number) => `${n} B`,
}));
vi.mock("../metadata", () => ({
  inspectFile: vi.fn(async (file: File) => ({
    file,
    hash: { sha256: file.name, crc64: "1" },
    raw: {},
    video: false,
    original_taken_at_local: "2024-03-31T10:00:00",
    time_source: "EXIF.DateTimeOriginal",
    ...metadataOverrides[file.name],
  })),
}));
vi.mock("../upload", () => ({
  directUpload: vi.fn().mockResolvedValue(undefined),
}));

let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  localStorage.clear();
  family.children = [];
  family.selected = [];
  routeInfo.query = { date: "2024-05-01" };
  vi.mocked(api).mockResolvedValue([]);
  for (const key of Object.keys(metadataOverrides))
    delete metadataOverrides[key];
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

it("defaults to the only child on first use and applies later child choices immediately; duplicate uploads skip OSS and reordering", async () => {
  family.children = [{ id: 7, name: "宝宝", nickname: "宝宝" }];
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:preview");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  vi.mocked(post).mockResolvedValue({
    media_id: 99,
    timeline_day: "2024-03-31",
    tasks: [],
    duplicate: true,
    notice: "已存在，已跳过重复上传",
  });
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Upload);
  app.component("RouterLink", { template: "<a><slot /></a>" });
  app.mount(host);
  await nextTick();
  await vi.waitFor(() =>
    expect(
      host.querySelector(".batch-children .child-pill.selected")?.textContent,
    ).toContain("宝宝"),
  );
  const input = host.querySelector('input[type="file"][multiple]')!;
  Object.defineProperty(input, "files", {
    value: [new File(["one"], "one.jpg"), new File(["two"], "two.jpg")],
  });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".upload-file-row")).toHaveLength(2),
  );
  const picker = host.querySelector(
    ".batch-children .child-pill",
  ) as HTMLButtonElement;
  picker.click();
  await nextTick();
  expect(host.querySelector(".file-summary")?.textContent).toContain(
    "未关联人物与宠物",
  );
  picker.click();
  await nextTick();
  expect(host.querySelector(".file-summary")?.textContent).toContain(
    "关联：宝宝",
  );
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("保留在 2024-05-01");
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".success-text")).toHaveLength(2),
  );
  expect(
    vi
      .mocked(post)
      .mock.calls.filter(([path]) => path === "/uploads")
      .every(([, body]) => body.child_ids[0] === 7),
  ).toBe(true);
  expect(directUpload).not.toHaveBeenCalled();
  expect(
    vi.mocked(post).mock.calls.some(([path]) => path === "/media/reorder"),
  ).toBe(false);
  expect(host.textContent).toContain("已存在");
});

it("honors an explicit family-only choice instead of silently associating a child", async () => {
  family.children = [{ id: 7, name: "宝宝" }];
  localStorage.setItem("yearly-upload-children", "[]");
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Upload);
  app.component("RouterLink", { template: "<a><slot /></a>" });
  app.mount(host);
  await nextTick();
  expect(host.querySelector(".batch-children .child-pill.selected")).toBeNull();
  expect(host.textContent).toContain("仅出现在全部人物与宠物中");
});

it("keeps details collapsed and uploads only selected files in the chosen order with the batch name and date", async () => {
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:local-preview");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  let id = 0;
  vi.mocked(post).mockImplementation(async (path) =>
    path === "/uploads"
      ? {
          media_id: ++id,
          timeline_day: "2024-05-01",
          tasks: [{ file_role: "original" }],
        }
      : { ok: true },
  );
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Upload);
  app.component("RouterLink", { template: "<a><slot /></a>" });
  app.mount(host);
  await nextTick();
  const input = host.querySelector('input[type="file"][multiple]')!;
  Object.defineProperty(input, "files", {
    value: ["one.jpg", "two.jpg", "three.jpg"].map(
      (name) => new File([name], name),
    ),
  });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".upload-file-row")).toHaveLength(3),
  );
  expect(host.textContent).not.toContain("修正拍摄当地时间");
  const name = host.querySelector(
    'input[placeholder="例如：出生第一天、第一次去海边"]',
  ) as HTMLInputElement;
  name.value = "春日出游";
  name.dispatchEvent(new Event("input", { bubbles: true }));
  const checkboxes = host.querySelectorAll<HTMLInputElement>(".row-checkbox");
  checkboxes[1].checked = false;
  checkboxes[1].dispatchEvent(new Event("change", { bubbles: true }));
  (host.querySelector('[aria-label="下移文件"]') as HTMLButtonElement).click();
  await nextTick();
  (
    host.querySelectorAll('[aria-label="下移文件"]')[1] as HTMLButtonElement
  ).click();
  await nextTick();
  expect(
    [...host.querySelectorAll(".file-summary h3")].map((h) => h.textContent),
  ).toEqual(["two.jpg", "three.jpg", "one.jpg"]);
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("保留在 2024-05-01");
  await vi.waitFor(() =>
    expect(host.querySelector(".queue-heading button")?.textContent).toContain(
      "上传所选 0 项",
    ),
  );
  const creates = vi
    .mocked(post)
    .mock.calls.filter(([path]) => path === "/uploads");
  expect(creates.map(([, body]) => body.files[0].original_filename)).toEqual([
    "three.jpg",
    "one.jpg",
  ]);
  expect(
    creates.every(
      ([, body]) =>
        body.batch_name === "春日出游" && body.timeline_date === "2024-05-01",
    ),
  ).toBe(true);
  expect(post).toHaveBeenCalledWith("/media/reorder", {
    media_ids: [1],
    target_id: 2,
    placement: "before",
  });
});

async function chooseDate(text: string) {
  await vi.waitFor(() =>
    expect(
      document.querySelector(".date-review-dialog")?.textContent,
    ).toContain(text),
  );
  const button = [
    ...document.querySelectorAll<HTMLButtonElement>(
      ".date-review-dialog button",
    ),
  ].find((b) => b.textContent?.trim() === text)!;
  button.click();
  await nextTick();
}
async function queueFiles(names: string[]) {
  vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:preview");
  vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  let id = 0;
  vi.mocked(post).mockImplementation(async (path, body) =>
    path === "/uploads"
      ? {
          media_id: ++id,
          timeline_day: body.timeline_date,
          tasks: [{ file_role: "original" }],
        }
      : { ok: true },
  );
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Upload);
  app.component("RouterLink", { template: "<a><slot /></a>" });
  app.mount(host);
  await nextTick();
  const input = host.querySelector('input[type="file"][multiple]')!;
  Object.defineProperty(input, "files", {
    value: names.map((name) => new File([name], name)),
  });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".upload-file-row")).toHaveLength(
      names.length,
    ),
  );
  return host;
}

it("pairs matching Live Photo originals across imports and uploads both resources as one media", async () => {
  metadataOverrides["still.jpg"] = { pairId: "live-asset" };
  metadataOverrides["renamed.MOV"] = { pairId: "live-asset", video: true };
  const host = await queueFiles(["still.jpg"]);
  expect(host.querySelector(".file-summary")?.textContent).toContain("LIVE · 缺少动态文件");
  const input = host.querySelector('input[aria-label="从文件导入"]')!;
  Object.defineProperty(input, "files", { value: [new File(["motion"], "renamed.MOV")] });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() => {
    expect(host.querySelectorAll(".upload-file-row")).toHaveLength(1);
    expect(host.querySelector(".file-summary .chip")?.textContent).toBe("LIVE");
  });
  expect(host.querySelector(".file-summary")?.textContent).not.toContain("缺少动态文件");
  vi.mocked(post).mockResolvedValue({ media_id: 1, timeline_day: "2024-05-01", tasks: [{ file_role: "original" }, { file_role: "live_video" }] });
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("保留在 2024-05-01");
  await vi.waitFor(() => expect(directUpload).toHaveBeenCalledTimes(2));
  const creates = vi.mocked(post).mock.calls.filter(([path]) => path === "/uploads");
  expect(creates).toHaveLength(1);
  expect(creates[0][1]).toMatchObject({ media_type: "live_photo", files: [
    { file_role: "original", original_filename: "still.jpg" },
    { file_role: "live_video", original_filename: "renamed.MOV" },
  ] });
});

it("does not pair matching filenames without metadata or mark a still-only upload as playable", async () => {
  metadataOverrides["IMG.MOV"] = { video: true };
  metadataOverrides["alone.jpg"] = { pairId: "missing-motion" };
  const host = await queueFiles(["IMG.jpg", "IMG.MOV", "alone.jpg"]);
  expect(host.querySelectorAll(".file-summary .chip")).toHaveLength(1);
  expect(host.textContent).toContain("仅收到实况照片的静态部分");
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("保留在 2024-05-01");
  await vi.waitFor(() => expect(host.querySelectorAll(".file-state .success-text")).toHaveLength(3));
  expect(vi.mocked(post).mock.calls.filter(([path]) => path === "/uploads").map(([,body]) => body.media_type)).toEqual(["photo", "video", "photo"]);
});

it("queues and uploads photos and videos when randomUUID is unavailable on HTTP", async () => {
  vi.stubGlobal("crypto", { getRandomValues: crypto.getRandomValues.bind(crypto) });
  metadataOverrides["clip.MOV"] = { video: true };
  const host = await queueFiles(["photo.HEIC", "clip.MOV"]);
  const input = host.querySelector<HTMLInputElement>(
    'input[type="file"][multiple]',
  )!;
  expect(input.hidden).toBe(false);
  expect(input.accept).toContain("image/*");
  expect(input.accept).toContain("video/*");
  expect(input.disabled).toBe(false);
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("保留在 2024-05-01");
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".file-state .success-text")).toHaveLength(2),
  );
  expect(
    vi.mocked(post).mock.calls
      .filter(([path]) => path === "/uploads")
      .map(([, body]) => body.media_type),
  ).toEqual(["photo", "video"]);
  expect(directUpload).toHaveBeenCalledTimes(2);
  expect(notify).not.toHaveBeenCalled();
});

it("offers single-photo and Files fallbacks and keeps readable files after one import fails", async () => {
  const host = await queueFiles(["ready.jpg"]);
  const single = host.querySelector<HTMLInputElement>('input[aria-label="单张选择"]')!;
  const files = host.querySelector<HTMLInputElement>('input[aria-label="从文件导入"]')!;
  expect(single.multiple).toBe(false);
  expect(single.accept).toContain("image/*");
  expect(files.multiple).toBe(true);
  expect(files.hasAttribute("accept")).toBe(false);
  vi.mocked(inspectFile).mockRejectedValueOnce(new DOMException("Not downloaded", "NotReadableError"));
  Object.defineProperty(files, "files", {
    value: [new File(["cloud"], "cloud.jpg"), new File(["local"], "local.jpg")],
  });
  files.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() => expect(host.querySelectorAll(".upload-file-row")).toHaveLength(2));
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("cloud.jpg");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("其余文件已继续处理");
  expect(host.querySelector(".upload-queue")?.textContent).toContain("local.jpg");
  expect(files.disabled).toBe(false);
  expect(files.value).toBe("");
});

it("explains an empty picker result without claiming to know iCloud download progress", async () => {
  const host = await queueFiles(["ready.jpg"]);
  host.querySelector('input[aria-label="单张选择"]')!.dispatchEvent(new Event("cancel"));
  await nextTick();
  expect(host.querySelector('[role="status"]')?.textContent).toContain("没有收到文件");
  expect(host.querySelectorAll(".upload-file-row")).toHaveLength(1);
  expect(host.querySelector(".parse-progress")).toBeNull();
});

function stubNativePicker(movie: string | Error) {
  const bridge = vi.fn(async ({ action, role }: { action: string; role?: string }) => {
    if (action === "pick")
      return {
        id: "pair",
        original: { name: "IMG_8014.HEIC", type: "image/heic", size: 5 },
        video: { name: "IMG_8014.MOV", type: "video/quicktime", size: 5 },
      };
    if (action === "read") {
      if (role === "original") return btoa("still");
      if (movie instanceof Error) throw movie;
      return btoa(movie);
    }
    return null;
  });
  vi.stubGlobal("webkit", { messageHandlers: { yearlyLivePhoto: { postMessage: bridge } } });
  return bridge;
}

function clickNativePicker(host: HTMLElement) {
  const button = [...host.querySelectorAll(".picker-actions button")].find(
    (element) => element.textContent?.includes("选择实况照片并上传"),
  ) as HTMLButtonElement;
  button.click();
}

it("uploads only the native Live Photo pair even without a shared metadata identifier", async () => {
  routeInfo.query = {};
  family.children = [{ id: 7, name: "宝宝" }];
  const bridge = stubNativePicker("movie");
  metadataOverrides["IMG_8014.MOV"] = { video: true };
  metadataOverrides["IMG_8014.HEIC"] = {
    time_source: "unknown",
    original_taken_at_local: null,
  };
  const host = await queueFiles(["manual.jpg"]);
  vi.mocked(post).mockResolvedValue({
    media_id: 42,
    tasks: [{ file_role: "original" }, { file_role: "live_video" }],
  });
  clickNativePicker(host);
  await vi.waitFor(() => expect(host.querySelectorAll(".file-state .success-text")).toHaveLength(1));
  expect(post).toHaveBeenCalledTimes(1);
  expect(post).toHaveBeenCalledWith("/uploads", expect.objectContaining({
    media_type: "live_photo",
    child_ids: [7],
    original_taken_at_local: null,
    time_unknown: true,
    files: [
      expect.objectContaining({ original_filename: "IMG_8014.HEIC", file_role: "original" }),
      expect.objectContaining({ original_filename: "IMG_8014.MOV", file_role: "live_video" }),
    ],
  }));
  const uploaded = vi.mocked(directUpload).mock.calls;
  expect(uploaded).toHaveLength(2);
  expect(await uploaded[0][1].file.text()).toBe("still");
  expect(await uploaded[1][1].file.text()).toBe("movie");
  expect(inspectFile).toHaveBeenCalledWith(uploaded[0][1].file, expect.any(Function), { hasFileModified: false });
  expect(bridge).toHaveBeenLastCalledWith({ action: "release", id: "pair" });
});

it("releases the native selection and queues nothing if the paired video cannot be read", async () => {
  const bridge = stubNativePicker(new Error("readFailed"));
  const host = await queueFiles(["manual.jpg"]);
  clickNativePicker(host);
  await vi.waitFor(() => expect(host.querySelector('[role="status"]')?.textContent).toContain("无法读取完整的实况照片"));
  expect(host.querySelectorAll(".upload-file-row")).toHaveLength(1);
  expect(post).not.toHaveBeenCalled();
  expect(bridge).toHaveBeenLastCalledWith({ action: "release", id: "pair" });
});

it("queues pasted photos without opening a picker or uploading automatically, and does not use copy time as capture time", async () => {
  routeInfo.query = {};
  family.children = [{ id: 7, name: "宝宝" }];
  metadataOverrides["copy.png"] = {
    original_taken_at_local: "2026-11-07T12:00:00",
    time_source: "file_modified",
    time_confidence: "low",
  };
  const host = await queueFiles(["ready.jpg"]);
  const copied = new File(["copied pixels"], "copy.png", { type: "image/png" });
  const dated = new File(["photo with exif"], "dated.jpg", { type: "image/jpeg" });
  const data = new DataTransfer();
  data.items.add(copied);
  data.items.add(dated);
  const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
  host.querySelector(".paste-target")!.dispatchEvent(event);
  await vi.waitFor(() => expect(host.querySelectorAll(".upload-file-row")).toHaveLength(3));
  expect(event.defaultPrevented).toBe(true);
  expect(post).not.toHaveBeenCalled();
  const rows = host.querySelectorAll(".file-summary");
  expect(rows[1].textContent).toContain("粘贴副本");
  expect(rows[1].textContent).toContain("拍摄日期未知");
  expect(rows[1].textContent).not.toContain("2026-11-07");
  expect(rows[2].textContent).toContain("2024-03-31");
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await vi.waitFor(() => expect(host.querySelectorAll(".file-state .success-text")).toHaveLength(3));
  const creates = vi.mocked(post).mock.calls.filter(([path]) => path === "/uploads");
  expect(creates[1][1]).toMatchObject({ time_unknown: true, timeline_date: null, child_ids: [7] });
  expect(creates[2][1]).toMatchObject({ time_unknown: false, original_taken_at_local: "2024-03-31T10:00:00" });
  expect(await vi.mocked(directUpload).mock.calls[1][1].file.text()).toBe(await copied.text());
  expect(await vi.mocked(directUpload).mock.calls[2][1].file.text()).toBe(await dated.text());
});

it("rejects text and HTML paste with a visible explanation and keeps the photo queue", async () => {
  const host = await queueFiles(["ready.jpg"]);
  vi.mocked(inspectFile).mockClear();
  const data = new DataTransfer();
  data.setData("text/html", '<img src="https://example.invalid/image.jpg" onerror="alert(1)">');
  data.setData("text/plain", "not a photo");
  const target = host.querySelector(".paste-target")!;
  const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
  target.dispatchEvent(event);
  await nextTick();
  expect(event.defaultPrevented).toBe(true);
  expect(target.innerHTML).toBe("");
  expect(host.querySelector('[role="status"]')?.textContent).toContain("没有收到可粘贴的照片");
  expect(host.querySelectorAll(".upload-file-row")).toHaveLength(1);
  expect(inspectFile).not.toHaveBeenCalled();
  expect(post).not.toHaveBeenCalled();
});

it("disables paste while reading and preserves the existing queue", async () => {
  const host = await queueFiles(["ready.jpg"]);
  let finish!: (value: any) => void;
  vi.mocked(inspectFile).mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const target = host.querySelector(".paste-target")!;
  const file = new File(["pending"], "pending.png", { type: "image/png" });
  const data = new DataTransfer();
  data.items.add(file);
  target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  await nextTick();
  expect(target.getAttribute("contenteditable")).toBe("false");
  expect(host.querySelector(".parse-progress")?.textContent).toContain("1 / 1");
  target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  expect(inspectFile).toHaveBeenCalledTimes(2);
  finish({ file, hash: { sha256: "pending", crc64: "1" }, raw: {}, video: false, time_source: "unknown" });
  await vi.waitFor(() => expect(host.querySelectorAll(".upload-file-row")).toHaveLength(2));
  expect(target.getAttribute("contenteditable")).toBe("true");
});

it("shows the actual file count while reading a received batch", async () => {
  const host = await queueFiles(["ready.jpg"]);
  let finish!: (value: any) => void;
  vi.mocked(inspectFile).mockImplementationOnce(() => new Promise(resolve => { finish = resolve; }));
  const files = host.querySelector<HTMLInputElement>('input[aria-label="从文件导入"]')!;
  const pending = new File(["pending"], "pending.jpg");
  Object.defineProperty(files, "files", { value: [pending] });
  files.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  expect(host.querySelector(".parse-progress")?.textContent).toContain("1 / 1");
  expect(files.disabled).toBe(true);
  finish({file: pending, hash: {sha256:"pending",crc64:"1"}, raw:{}, video:false});
  await vi.waitFor(() => expect(host.querySelectorAll(".upload-file-row")).toHaveLength(2));
  expect(files.disabled).toBe(false);
});

it("resumes the chosen task through its native file input", async () => {
  const task = { id: 42, filename: "clip.MOV", file_size: 4, file_role: "original" };
  vi.mocked(api).mockResolvedValue([task]);
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Upload);
  app.component("RouterLink", { template: "<a><slot /></a>" });
  app.mount(host);
  await vi.waitFor(() => expect(host.querySelector(".resume-row")).not.toBeNull());
  const input = host.querySelector<HTMLInputElement>(
    '.resume-row input[type="file"]',
  )!;
  expect(input.hidden).toBe(false);
  const file = new File(["clip"], "clip.MOV", { type: "video/quicktime" });
  Object.defineProperty(input, "files", { value: [file] });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await vi.waitFor(() =>
    expect(directUpload).toHaveBeenCalledWith(
      task,
      expect.objectContaining({ file }),
      expect.any(Function),
    ),
  );
  await vi.waitFor(() => expect(host.textContent).toContain("本次文件已恢复上传"));
  expect(input.value).toBe("");
});

it("waits for confirmation then distributes mixed dates while preserving unknown dates and default capture-time order", async () => {
  metadataOverrides["same.jpg"] = {
    original_taken_at_local: "2024-05-01T23:30:00",
  };
  metadataOverrides["later.jpg"] = {
    original_taken_at_local: "2024-05-02T00:30:00",
    time_source: "file_modified",
  };
  metadataOverrides["unknown.jpg"] = { original_taken_at_local: null };
  const host = await queueFiles([
    "one.jpg",
    "two.jpg",
    "same.jpg",
    "later.jpg",
    "unknown.jpg",
  ]);
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await vi.waitFor(() =>
    expect(
      document.querySelector(".date-review-dialog")?.textContent,
    ).toContain("文件修改日期 · 待确认"),
  );
  expect(post).not.toHaveBeenCalled();
  expect(directUpload).not.toHaveBeenCalled();
  expect(document.querySelectorAll(".date-review-file")).toHaveLength(3);
  await chooseDate("移到文件对应日期");
  await vi.waitFor(() =>
    expect(host.querySelector(".queue-heading button")?.textContent).toContain(
      "上传所选 0 项",
    ),
  );
  const creates = vi
    .mocked(post)
    .mock.calls.filter(([path]) => path === "/uploads");
  expect(creates.map(([, body]) => body.timeline_date)).toEqual([
    "2024-03-31",
    "2024-03-31",
    "2024-05-01",
    "2024-05-02",
    "2024-05-01",
  ]);
  expect(creates[0][1].original_taken_at_local).toBe("2024-03-31T10:00:00");
  expect(
    vi.mocked(post).mock.calls.some(([path]) => path === "/media/reorder"),
  ).toBe(false);
  expect(host.textContent).toContain("已归档到 2024-05-02");
});

it("cancels a date mismatch without creating any upload and permits choosing again", async () => {
  const host = await queueFiles(["one.jpg"]);
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("取消，继续检查");
  expect(post).not.toHaveBeenCalled();
  expect(directUpload).not.toHaveBeenCalled();
  expect(host.querySelector(".file-state")?.textContent).toContain("待上传");
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("保留在 2024-05-01");
  await vi.waitFor(() =>
    expect(
      vi.mocked(post).mock.calls.filter(([path]) => path === "/uploads"),
    ).toHaveLength(1),
  );
  expect(
    vi.mocked(post).mock.calls.find(([path]) => path === "/uploads")![1]
      .timeline_date,
  ).toBe("2024-05-01");
});

it("does not prompt for matching or unknown dates and ignores unselected mismatches", async () => {
  metadataOverrides["same.jpg"] = {
    original_taken_at_local: "2024-05-01T23:30:00",
  };
  metadataOverrides["unknown.jpg"] = { original_taken_at_local: null };
  const host = await queueFiles(["same.jpg", "unknown.jpg", "other.jpg"]);
  const checkbox = host.querySelectorAll<HTMLInputElement>(".row-checkbox")[2];
  checkbox.checked = false;
  checkbox.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".file-state .success-text")).toHaveLength(2),
  );
  expect(document.querySelector(".date-review-dialog")).toBeNull();
  expect(
    vi.mocked(post).mock.calls.filter(([path]) => path === "/uploads"),
  ).toHaveLength(2);
});

it("appends to a folder but places confirmed different-date files outside it", async () => {
  routeInfo.query.folder = "8";
  vi.mocked(api).mockImplementation(async (path) =>
    path === "/folders/8"
      ? { id: 8, name: "合影", timeline_day: "2024-05-01" }
      : [],
  );
  metadataOverrides["same.jpg"] = {
    original_taken_at_local: "2024-05-01T12:00:00",
  };
  const host = await queueFiles(["same.jpg", "earlier.jpg"]);
  await vi.waitFor(() =>
    expect(host.textContent).toContain("追加到文件夹：合影"),
  );
  (host.querySelector(".queue-heading button") as HTMLButtonElement).click();
  await chooseDate("移到文件对应日期");
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".file-state .success-text")).toHaveLength(2),
  );
  const creates = vi
    .mocked(post)
    .mock.calls.filter(([path]) => path === "/uploads");
  expect(
    creates.map(([, body]) => [body.folder_id, body.timeline_date]),
  ).toEqual([
    [8, "2024-05-01"],
    [null, "2024-03-31"],
  ]);
});
