// @vitest-environment happy-dom
import { afterEach, expect, it } from "vitest";
import { createApp, computed, nextTick } from "vue";
import LanguageSwitch from "../../components/LanguageSwitch.vue";
import { locale, setLocale, t, ageLabel, elementLocale } from "../i18n";
let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  setLocale("zh-CN");
  localStorage.clear();
});
it("switches live, persists the choice and keeps family content unchanged", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    components: { LanguageSwitch },
    setup: () => ({
      t,
      heading: computed(() => t("成长时间线")),
      name: "小禾",
      draft: "第一次去海边",
    }),
    template:
      '<LanguageSwitch/><h1>{{ heading }}</h1><p>{{ name }}</p><input :value="draft"/><button>{{ t("上传所选 {p0} 项", { p0: 3 }) }}</button>',
  });
  app.mount(host);
  expect(host.querySelector("h1")!.textContent).toBe("成长时间线");
  const select = host.querySelector("select")!;
  select.value = "en";
  select.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  expect(host.querySelector("h1")!.textContent).toBe("Growth timeline");
  expect(host.querySelector("button")!.textContent).toBe("Upload 3 selected");
  expect(host.querySelector("input")!.value).toBe("第一次去海边");
  expect(host.querySelector("p")!.textContent).toBe("小禾");
  expect(localStorage.getItem("yearly-language")).toBe("en");
  expect(document.documentElement.lang).toBe("en");
  expect(elementLocale.value.name).toBe("en");
  select.value = "zh-CN";
  select.dispatchEvent(new Event("change", { bubbles: true }));
  await nextTick();
  expect(host.querySelector("h1")!.textContent).toBe("成长时间线");
  expect(locale.value).toBe("zh-CN");
});
it("localizes server-generated ages and preserves placeholder values literally", () => {
  setLocale("en");
  expect(ageLabel("2 岁 6 个月")).toBe("2y 6mo");
  expect(ageLabel("出生第 12 天")).toBe("Day 12");
  expect(ageLabel("出生前")).toBe("Before birth");
  expect(ageLabel("满月")).toBe("One month old");
  expect(t("用户名或密码不正确")).toBe("Incorrect username or password.");
  expect(t("打开文件夹 {p0}", { p0: "旅行 <b>相册</b>" })).toBe(
    "Open folder 旅行 <b>相册</b>",
  );
});
