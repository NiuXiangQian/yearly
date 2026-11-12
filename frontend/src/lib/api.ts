import { t } from "./i18n";
import {
  cacheScope, cacheRevision, readCachedJSON, writeCachedJSON,
  setCacheAccount, invalidateCachedLists, clearCachedScope, rememberShare,
} from "./local-cache";
import { ElMessage } from "element-plus";
let csrf = "";
export function sitePath(path: string) {
  return import.meta.env.BASE_URL + path.replace(/^\//, "");
}
export function setCSRF(value: string) {
  csrf = value;
}
export async function api<T = any>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const method = options.method || "GET";
  const scope = cacheScope(path);
  const cacheable = method === "GET" && scope && options.cache !== "reload" && options.cache !== "no-store" && (
    /^\/(timeline|media|events|children|folders|stats|uploaders)(?:[/?]|$)/.test(path) && !path.includes("/url?") ||
    /^\/public\/shares\/[^/?]+(?:[?]|$|\/(days|folders)\/)/.test(path)
  );
  const revision = cacheRevision();
  if (cacheable) {
    const cached = await readCachedJSON(scope, path);
    if (cached !== undefined) {
      if (cached.share?.expires_at) rememberShare(path, cached.share.expires_at);
      return cached;
    }
  }
  const response = await fetch(sitePath("/api" + path), {
    credentials: "same-origin",
    ...options,
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": csrf,
      ...options.headers,
    },
  });
  if (!response.ok) {
    if (response.status === 401 || response.status === 403 || response.status === 404) {
      if (scope) await clearCachedScope(scope);
      if (response.status === 401 && !path.startsWith("/public/")) setCacheAccount(null);
    }
    const body = await response.json().catch(() => ({}));
    const message =
      typeof body.detail === "string"
        ? body.detail
        : body.detail
            ?.map((d: any) => t(d.msg.replace(/^Value error, /, "")))
            .join("; ") || t("请求失败");
    if (
      response.status === 401 &&
      !path.startsWith("/auth/") &&
      !path.startsWith("/public/")
    )
      location.assign(sitePath("/login"));
    throw new Error(t(message));
  }
  const value = await response.json();
  if ((path === "/auth/me" || path === "/auth/login") && value.id) setCacheAccount(value.id, value.role);
  if (method !== "GET") invalidateCachedLists();
  if (path === "/auth/logout") {
    if (scope) await clearCachedScope(scope);
    setCacheAccount(null);
  }
  if (value.share?.expires_at) rememberShare(path, value.share.expires_at);
  if (cacheable && revision === cacheRevision()) await writeCachedJSON(scope, path, value);
  return value;
}
export const post = <T = any>(path: string, body: any = {}) =>
  api<T>(path, { method: "POST", body: JSON.stringify(body) });
export const put = <T = any>(path: string, body: any) =>
  api<T>(path, { method: "PUT", body: JSON.stringify(body) });
export const del = (path: string) => api(path, { method: "DELETE" });
export function notify(error: unknown) {
  ElMessage.error(error instanceof Error ? error.message : t("操作失败"));
}
export function bytes(n: number) {
  return n < 1024 ** 2
    ? (n / 1024).toFixed(1) + " KB"
    : n < 1024 ** 3
      ? (n / 1024 ** 2).toFixed(1) + " MB"
      : (n / 1024 ** 3).toFixed(2) + " GB";
}
export function localDate(value?: string) {
  return value ? value.slice(0, 10).replaceAll("-", ".") : t("拍摄时间未知");
}
