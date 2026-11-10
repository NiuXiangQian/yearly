// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import Accounts from "../../views/Accounts.vue";
import { api, post, put } from "../api";
vi.mock("element-plus/es/components/base/style/css", () => ({}));
vi.mock("element-plus/es/components/dialog/style/css", () => ({}));
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), put: vi.fn() }));
vi.mock("../../stores/yearly", () => ({
  useYearly: () => ({ user: { id: 1 }, isAdmin: true }),
}));
vi.mock("vue-router", () => ({ useRouter: () => ({ push: vi.fn() }) }));
let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  vi.clearAllMocks();
});
async function mount() {
  vi.mocked(api).mockResolvedValue([
    { id: 1, username: "admin", role: "admin", active: true },
    { id: 2, username: "member", nickname: "明月", role: "member", active: true },
  ]);
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp(Accounts);
  app.component("RouterLink", { template: "<a><slot /></a>" });
  app.mount(host);
  await vi.waitFor(() =>
    expect(host.querySelectorAll(".account-row")).toHaveLength(2),
  );
  return host;
}
function input(selector: string, value: string) {
  const field = document.querySelector<HTMLInputElement>(selector)!;
  field.value = value;
  field.dispatchEvent(new Event("input", { bubbles: true }));
}
function submit() {
  document
    .querySelector(".el-dialog form")!
    .dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
}
it("keeps account creation input after failure and allows retry", async () => {
  const host = await mount();
  host.querySelector<HTMLButtonElement>(".page-heading button")!.click();
  await vi.waitFor(() =>
    expect(document.querySelector(".el-dialog form")).not.toBeNull(),
  );
  input('.el-dialog input[autocomplete="off"]', "new-member");
  input('.el-dialog input[autocomplete="nickname"]', "小禾爸爸");
  input('.el-dialog input[type="password"]', "synthetic-password-123");
  vi.mocked(post).mockRejectedValueOnce(new Error("用户名已存在"));
  submit();
  await vi.waitFor(() =>
    expect(document.querySelector('[role="alert"]')?.textContent).toContain(
      "用户名已存在",
    ),
  );
  expect(
    document.querySelector<HTMLInputElement>(
      '.el-dialog input[autocomplete="off"]',
    )!.value,
  ).toBe("new-member");
  expect(
    document.querySelector<HTMLInputElement>(
      '.el-dialog input[type="password"]',
    )!.value,
  ).toBe("synthetic-password-123");
  vi.mocked(post).mockResolvedValue({ id: 4 });
  submit();
  await vi.waitFor(() => expect(post).toHaveBeenCalledTimes(2));
  expect(post).toHaveBeenLastCalledWith("/users", {
    username: "new-member",
    nickname: "小禾爸爸",
    password: "synthetic-password-123",
    role: "member",
    active: true,
  });
});
it("edits an existing account while preserving an empty password", async () => {
  const host = await mount();
  expect(host.querySelectorAll(".account-identity b")[0].textContent).toBe("admin");
  expect(host.querySelectorAll(".account-identity b")[1].textContent).toBe("明月");
  host.querySelectorAll<HTMLButtonElement>(".account-row button")[1].click();
  await vi.waitFor(() =>
    expect(document.querySelector(".el-dialog form")).not.toBeNull(),
  );
  input('.el-dialog input[autocomplete="off"]', "renamed-member");
  expect(document.querySelector<HTMLInputElement>('.el-dialog input[autocomplete="nickname"]')!.value).toBe("明月");
  input('.el-dialog input[autocomplete="nickname"]', "");
  const enabled = document.querySelector<HTMLInputElement>(
    '.el-dialog input[type="checkbox"]',
  )!;
  enabled.checked = false;
  enabled.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  vi.mocked(put).mockResolvedValue({ ok: true, reauthenticate: false });
  submit();
  await vi.waitFor(() => expect(put).toHaveBeenCalledOnce());
  expect(put).toHaveBeenCalledWith("/users/2", {
    username: "renamed-member",
    nickname: "",
    password: null,
    role: "member",
    active: false,
  });
});
