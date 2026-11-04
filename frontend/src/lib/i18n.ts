import { computed, ref } from "vue";
import zhCN from "element-plus/es/locale/lang/zh-cn";
import en from "element-plus/es/locale/lang/en";
import messages from "../locales/en.json";
export type Locale = "zh-CN" | "en";
export const locale = ref<Locale>("zh-CN");
export const elementLocale = computed(() =>
  locale.value === "en" ? en : zhCN,
);
export function setLocale(value: Locale) {
  locale.value = value;
  localStorage.setItem("yearly-language", value);
  document.documentElement.lang = value;
  document.title =
    value === "en" ? "yearly · Family memories" : "yearly · 家庭成长影像档案";
}
export function t(
  source: string,
  params: Record<string, string | number> = {},
) {
  const text =
    locale.value === "en"
      ? (messages as Record<string, string>)[source] || source
      : source;
  return text.replace(/\{(\w+)\}/g, (match, name) =>
    String(params[name] ?? match),
  );
}
// Only use for server-generated age/milestone labels, never names or journal content.
export function ageLabel(value?: string) {
  if (!value) return t("年龄未知");
  if (locale.value !== "en") return value;
  if (value === "出生前") return "Before birth";
  if (value === "出生") return "Birth";
  if (value === "出生当天") return "Day of birth";
  if (value === "满月") return "One month old";
  if (value === "百天") return "100 days old";
  return value
    .replace(/出生前\s*(\d+)\s*天/g, "$1 days before birth")
    .replace(/出生第\s*(\d+)\s*天/g, "Day $1")
    .replace(/(\d+)\s*岁生日/g, "$1-year birthday")
    .replace(/(\d+)\s*周岁/g, "$1 years")
    .replace(/(\d+)\s*岁/g, "$1y ")
    .replace(/(\d+)\s*个?月/g, "$1mo ")
    .replace(/(\d+)\s*天/g, "$1d ")
    .replace(/\s+/g, " ")
    .trim();
}
