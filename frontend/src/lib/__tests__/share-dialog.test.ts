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
it("creates a link from dates and lifetime without selecting or loading files", async () => {
  vi.mocked(api).mockImplementation(async (path) =>
    path === "/shares/bounds"
      ? { earliest: "2020-01-01", latest: "2024-03-31" }
      : [],
  );
  vi.mocked(post).mockResolvedValue({
    id: 1,
    token: "demo",
    start_date: "2024-03-31",
    end_date: "2024-03-31",
    expires_at: "2028-01-01T00:00:00Z",
  });
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
  await vi.waitFor(() =>
    expect(document.querySelector('input[type="date"]')).not.toBeNull(),
  );
  const create = [...document.querySelectorAll("button")].find((b) =>
    b.textContent?.includes("创建分享链接"),
  )!;
  expect(create.disabled).toBe(false);
  expect(document.querySelectorAll('input[type="checkbox"]')).toHaveLength(0);
  expect(document.body.textContent).not.toContain("查看范围内的内容");
  create.click();
  await vi.waitFor(() =>
    expect(post).toHaveBeenCalledWith("/shares", {
      start_date: "2024-03-31",
      end_date: "2024-03-31",
      hours: 24,
    }),
  );
  expect(api).toHaveBeenCalledTimes(2);
  expect(api).toHaveBeenCalledWith("/shares/bounds");
  expect(api).toHaveBeenCalledWith("/shares");
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
