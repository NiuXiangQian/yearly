// @vitest-environment happy-dom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { api } from "../api";
import {
  setCacheAccount,
  invalidateCachedLists,
  readCachedJSON,
  writeCachedJSON,
  rememberShare,
  clearCachedScope,
} from "../local-cache";
vi.mock("element-plus", () => ({ ElMessage: { error: vi.fn() } }));
const network = vi.fn();
beforeEach(() => {
  localStorage.clear();
  setCacheAccount(1);
  vi.stubGlobal("fetch", network);
  network.mockReset();
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  invalidateCachedLists();
});
function reply(value: unknown) {
  return new Response(JSON.stringify(value), {
    headers: { "Content-Type": "application/json" },
  });
}
it("persists empty and populated pages, separating filters and cursor pages", async () => {
  network.mockImplementation(async () => reply({ items: [], total: 0 }));
  await api("/timeline?q=empty");
  expect(await api("/timeline?q=empty")).toEqual({ items: [], total: 0 });
  expect(network).toHaveBeenCalledTimes(1);
  await api("/timeline?q=other");
  await api("/timeline?q=other&cursor=next");
  expect(network).toHaveBeenCalledTimes(3);
  expect(await readCachedJSON("account:1", "/timeline?q=empty")).toEqual({
    items: [],
    total: 0,
  });
});
it("separates accounts and invalidates successful writes", async () => {
  network.mockImplementation(async () => reply({ items: [1] }));
  await api("/timeline");
  setCacheAccount(2);
  await api("/timeline");
  expect(network).toHaveBeenCalledTimes(2);
  await api("/media/1", { method: "PUT", body: "{}" });
  await api("/timeline");
  expect(network).toHaveBeenCalledTimes(4);
});
it("expires cached pages and keeps share validation on the network", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  network.mockImplementation(async () => reply({ dates: [] }));
  await api("/timeline");
  vi.setSystemTime(Date.now() + 301_000);
  await api("/timeline");
  await api("/public/shares/virtual/dates");
  await api("/public/shares/virtual/dates");
  expect(network).toHaveBeenCalledTimes(4);
});
it("limits cached share pages to the link expiration and removes revoked pages", async () => {
  vi.useFakeTimers({ toFake: ["Date"] });
  rememberShare(
    "/public/shares/virtual",
    new Date(Date.now() + 1000).toISOString(),
  );
  await writeCachedJSON("/public/shares/virtual", "/public/shares/virtual", {
    items: [1],
  });
  expect(
    await readCachedJSON("/public/shares/virtual", "/public/shares/virtual"),
  ).toEqual({ items: [1] });
  vi.setSystemTime(Date.now() + 1001);
  expect(
    await readCachedJSON("/public/shares/virtual", "/public/shares/virtual"),
  ).toBeUndefined();
  network.mockResolvedValue(
    new Response('{"detail":"分享已失效或不存在"}', { status: 404 }),
  );
  await expect(api("/public/shares/virtual/dates")).rejects.toThrow(
    "分享已失效",
  );
  expect(
    await readCachedJSON("/public/shares/virtual", "/public/shares/virtual"),
  ).toBeUndefined();
});

it("clears one account's persisted pages without clearing another account", async () => {
  await writeCachedJSON("account:1", "/timeline", { items: [1] });
  await writeCachedJSON("account:2", "/timeline", { items: [2] });
  await clearCachedScope("account:1");
  expect(await readCachedJSON("account:1", "/timeline")).toBeUndefined();
  expect(await readCachedJSON("account:2", "/timeline")).toEqual({
    items: [2],
  });
});

it("caches uploader choices including empty results and invalidates them after writes", async () => {
  network.mockImplementation(async () => reply([{ id: 2, username: "明月" }]));
  expect(await api("/uploaders")).toEqual([{ id: 2, username: "明月" }]);
  await api("/uploaders");
  expect(network).toHaveBeenCalledTimes(1);
  await api("/users/2", { method: "PUT", body: "{}" });
  network.mockImplementation(async () => reply([{ id: 2, username: "明月", nickname: "新昵称" }]));
  expect(await api("/uploaders")).toEqual([{ id: 2, username: "明月", nickname: "新昵称" }]);
  await api("/uploaders");
  expect(network).toHaveBeenCalledTimes(3);
  await api("/users/2", { method: "PUT", body: "{}" });
  network.mockImplementation(async () => reply([]));
  expect(await api("/uploaders")).toEqual([]);
  expect(await api("/uploaders")).toEqual([]);
  expect(network).toHaveBeenCalledTimes(5);
});
