// @vitest-environment happy-dom
import { afterEach, expect, it } from "vitest";
import { createApp, h, nextTick, ref, type Component } from "vue";
import TimelineMonths from "../../components/TimelineMonths.vue";
import { locale } from "../i18n";
let app: ReturnType<typeof createApp>;
let host: HTMLElement;
function mount(days: ReturnType<typeof ref<any[]>>, disabled = ref(false)) {
  host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    render: () =>
      h(
        TimelineMonths as unknown as Component,
        { days: days.value, disabled: disabled.value },
        {
          default: ({ day }: any) => h("article", day.date || day.day),
        },
      ),
  });
  app.mount(host);
}
function click(text: string) {
  [...host.querySelectorAll("button")]
    .find((b) => b.textContent?.includes(text))!
    .click();
}
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
  locale.value = "zh-CN";
});
it("keeps month/year boundaries and incoming order, with unknown dates separate", async () => {
  const days = ref([
    { date: "2025-01-02" },
    { date: "2025-01-01" },
    { date: "2024-01-03" },
    { date: "unknown" },
  ]);
  mount(days);
  expect(host.querySelectorAll(".timeline-month")).toHaveLength(3);
  click("2025年1月");
  await nextTick();
  expect(
    [...host.querySelectorAll("article")].map((e) => e.textContent),
  ).toEqual(["2024-01-03", "unknown"]);
  days.value = [...days.value.slice(0, 3)]
    .reverse()
    .concat({ date: "unknown" });
  await nextTick();
  expect(host.querySelector(".month-title")?.textContent).toBe("2024年1月");
  expect(host.querySelectorAll('[aria-expanded="false"]')).toHaveLength(1);
  click("全部展开");
  await nextTick();
  expect(host.querySelectorAll("article")).toHaveLength(4);
});
it("keeps appended pages collapsed and merges days into their existing month", async () => {
  const days = ref([{ day: "2024-03-09" }]);
  mount(days);
  click("全部收起");
  await nextTick();
  days.value.push({ day: "2024-03-08" }, { day: "2024-02-29" });
  await nextTick();
  expect(host.querySelectorAll("article")).toHaveLength(0);
  expect(host.querySelectorAll(".timeline-month")).toHaveLength(2);
  expect(host.querySelector(".month-toggle")?.textContent).toContain(
    "已加载 2 天",
  );
  click("2024年3月");
  await nextTick();
  expect(host.querySelectorAll("article")).toHaveLength(2);
  expect(host.querySelectorAll('[aria-expanded="false"]')).toHaveLength(1);
});
it("reveals content during selection or sorting and translates month controls", async () => {
  const disabled = ref(false);
  mount(ref([{ date: "2024-03-01" }]), disabled);
  click("全部收起");
  await nextTick();
  disabled.value = true;
  locale.value = "en";
  await nextTick();
  expect(host.querySelectorAll("article")).toHaveLength(1);
  expect(host.textContent).toContain("March 2024");
  expect(host.textContent).toContain("Collapse all");
  expect([...host.querySelectorAll("button")].every((b) => b.disabled)).toBe(
    true,
  );
  disabled.value = false;
  await nextTick();
  expect(host.querySelectorAll("article")).toHaveLength(0);
});
