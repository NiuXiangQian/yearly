// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, ref, nextTick } from "vue";
import ShareDialog from "../../components/ShareDialog.vue";
import { api, post } from "../api";
vi.mock("../api", () => ({
  api: vi.fn(),
  post: vi.fn(),
  del: vi.fn(),
  notify: vi.fn(),
  sitePath: (path: string) => "/yearly" + path,
}));
vi.mock("../../components/DateField.vue", () => ({
  default: {
    props: ["modelValue"],
    emits: ["update:modelValue"],
    template:
      '<input type="date" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
  },
}));
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
let app: ReturnType<typeof createApp>;
afterEach(() => {
  vi.useRealTimers();
  app?.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
});
it("defaults to children and lets the user adjust the profile scope without loading files", async () => {
  vi.mocked(api).mockImplementation(async (path) =>
    path === "/shares/bounds"
      ? { earliest: "2020-01-01", latest: "2024-03-31" }
      : path === "/children" ? [
        { id: 42, name: "小禾", nickname: "", profile_type: "child" },
        { id: 43, name: "小满", nickname: "", profile_type: "person", relationship: "孩子" },
        { id: 44, name: "妈妈", nickname: "", profile_type: "person", relationship: "妈妈" },
      ] : [],
  );
  vi.mocked(post).mockImplementation(async (_path, body) => ({
    id: 1,
    token: "demo",
    start_date: "2024-03-31",
    end_date: "2024-03-31",
    expires_at: "2028-01-01T00:00:00Z",
    profile_ids: (body as { profile_ids: number[] }).profile_ids,
  }));
  const open = ref(false),
    host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    components: { ShareDialog },
    setup: () => ({ open }),
    template: '<ShareDialog :open="open" initial-date="2024-03-31" />',
  });
  app.mount(host);
  open.value = true;
  await nextTick();
  const getChoices = () => [...document.querySelectorAll<HTMLInputElement>('.share-profiles input[type="checkbox"]')];
  await vi.waitFor(() => expect(getChoices().map(choice => choice.checked)).toEqual([true, true, false]));
  const create = [...document.querySelectorAll("button")].find((b) =>
    b.textContent?.includes("创建分享链接"),
  )!;
  const choices = getChoices();
  expect(create.disabled).toBe(false);
  expect(document.body.textContent).not.toContain("查看范围内的内容");
  create.click();
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/shares", {
      profile_ids: [42, 43],
      start_date: "2024-03-31",
      end_date: "2024-03-31",
      hours: 24,
    }),
  );
  expect(api).toHaveBeenCalledTimes(3);
  expect(api).toHaveBeenCalledWith("/children");
  expect(api).toHaveBeenCalledWith("/shares/bounds");
  expect(api).toHaveBeenCalledWith("/shares");
  choices[0]!.click();
  await nextTick();
  choices[1]!.click();
  await nextTick();
  expect(create.disabled).toBe(true);
  choices[2]!.click();
  await nextTick();
  create.click();
  await vi.waitFor(() => expect(post).toHaveBeenLastCalledWith("/shares", {
    profile_ids: [44], start_date: "2024-03-31", end_date: "2024-03-31", hours: 24,
  }));
  document.querySelector<HTMLInputElement>('.share-profiles input[type="radio"]')!.click();
  await nextTick();
  expect(choices.every(choice => !choice.checked)).toBe(true);
  create.click();
  await vi.waitFor(() => expect(post).toHaveBeenLastCalledWith("/shares", {
    profile_ids: [], start_date: "2024-03-31", end_date: "2024-03-31", hours: 24,
  }));
});

it("uses the earliest shareable day and calendar presets, with custom dates retained", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date(2024, 1, 29, 12));
  vi.mocked(api).mockImplementation(async (path) =>
    path === "/shares/bounds"
      ? { earliest: "2020-05-12", latest: "2024-02-29" }
      : [],
  );
  const open = ref(false),
    host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    components: { ShareDialog },
    setup: () => ({ open }),
    template: '<ShareDialog :open="open" />',
  });
  app.mount(host);
  open.value = true;
  const start = () =>
    document.querySelectorAll<HTMLInputElement>('input[type="date"]')[0];
  await vi.waitFor(() => expect(start()?.value).toBe("2020-05-12"));
  const preset = document.querySelector<HTMLSelectElement>(
    'select[aria-label="开始时间快捷选择"]',
  )!;
  preset.value = "year";
  preset.dispatchEvent(new Event("change"));
  await nextTick();
  expect(start().value).toBe("2023-02-28");
  preset.value = "halfYear";
  preset.dispatchEvent(new Event("change"));
  await nextTick();
  expect(start().value).toBe("2023-08-29");
  preset.value = "custom";
  preset.dispatchEvent(new Event("change"));
  await nextTick();
  start().value = "2022-06-15";
  start().dispatchEvent(new Event("input"));
  await nextTick();
  expect(start().value).toBe("2022-06-15");
  vi.useRealTimers();
});

it("reveals an active record and creates a new link with the scope of an old record", async () => {
  const record = {
    id: 3,
    title: "家庭时光",
    start_date: "2024-01-01",
    end_date: "2024-01-02",
    expires_at: "2099-01-01T00:00:00Z",
    can_copy: true,
    visit_count: 12,
    visitor_count: 3,
  };
  vi.mocked(api).mockImplementation(async (path) => {
    if (path === "/shares/bounds") return { earliest: "2024-01-01" };
    if (path === "/children") return [];
    if (path === "/shares/3/link") return { token: "current" };
    return [{ ...record, link_available: true }, { ...record, id: 2, link_available: false }];
  });
  vi.mocked(post).mockResolvedValue({ ...record, id: 4, token: "replacement", link_available: true });
  const open = ref(false);
  app = createApp({
    components: { ShareDialog },
    setup: () => ({ open }),
    template: '<ShareDialog :open="open" />',
  });
  const host = document.createElement("div");
  document.body.append(host);
  app.mount(host);
  open.value = true;
  const actions = (label: string) => [...document.querySelectorAll<HTMLButtonElement>(".history-row button")]
    .find((button) => button.textContent?.trim() === label);
  await vi.waitFor(() => expect(actions("查看链接")).toBeDefined());
  expect(document.querySelector(".share-counts")?.textContent).toBe("访问 12 次 · 访客 3 人");
  actions("查看链接")!.click();
  await vi.waitFor(() => expect(document.querySelector(".history-row a")?.getAttribute("href"))
    .toContain("/yearly/share/current"));
  expect(api).toHaveBeenCalledWith("/shares/3/link");
  actions("按原范围创建新链接")!.click();
  await vi.waitFor(() => expect(document.querySelector(".history-row a")?.getAttribute("href"))
    .toContain("/yearly/share/replacement"));
  expect(post).toHaveBeenCalledWith("/shares/2/copy", { hours: 24 });
});
