import { t } from "./i18n";
import { ElMessage } from "element-plus";
let csrf = "";
export function setCSRF(value: string) {
  csrf = value;
}
export async function api<T = any>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const response = await fetch("/api" + path, {
    credentials: "same-origin",
    ...options,
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": csrf,
      ...options.headers,
    },
  });
  if (!response.ok) {
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
      location.assign("/login");
    throw new Error(t(message));
  }
  return response.json();
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
