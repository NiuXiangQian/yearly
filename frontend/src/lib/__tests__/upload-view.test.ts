// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import Upload from "../../views/Upload.vue";
import { api, post } from "../api";
import { directUpload } from "../upload";

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
  inspectFile: async (file: File) => ({
    file,
    hash: { sha256: file.name, crc64: "1" },
    raw: {},
    video: false,
    original_taken_at_local: "2024-03-31T10:00:00",
    time_source: "EXIF.DateTimeOriginal",
    ...metadataOverrides[file.name],
  }),
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
    "未关联孩子",
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
  expect(host.textContent).toContain("仅出现在全部孩子中");
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
