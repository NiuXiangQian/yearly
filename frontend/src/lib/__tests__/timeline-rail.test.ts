// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, h, nextTick, ref } from "vue";
import TimelineRail from "../../components/TimelineRail.vue";
let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
});
it("scrubs continuously between nodes while a click selects a date", async () => {
  const select = vi.fn();
  const scrub = vi.fn();
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    render: () =>
      h(TimelineRail, {
        dates: ["2024-03-01", "2024-02-01", "2024-01-01"],
        current: "2024-03-01",
        onSelect: select,
        onScrub: scrub,
      }),
  });
  app.mount(host);
  expect(host.querySelector("output")?.textContent).toBe("03.01");
  const track = host.querySelector<HTMLElement>('[role="slider"]')!;
  track.getBoundingClientRect = () => ({ top: 100, height: 200 }) as DOMRect;
  track.setPointerCapture = vi.fn();
  track.releasePointerCapture = vi.fn();
  const pointer = (type: string, y: number) =>
    track.dispatchEvent(
      new PointerEvent(type, {
        clientY: y,
        pointerId: 1,
        isPrimary: true,
        button: 0,
        bubbles: true,
      }),
    );
  pointer("pointerdown", 100);
  pointer("pointermove", 205);
  await nextTick();
  expect(host.querySelector(".rail-bubble")?.textContent).toBe("2024.02.01");
  expect(host.querySelector(".rail-date")?.textContent).toBe("02.01");
  expect(select).not.toHaveBeenCalled();
  pointer("pointerup", 205);
  await nextTick();
  expect(select).not.toHaveBeenCalled();
  expect(scrub).toHaveBeenLastCalledWith("2024-02-01");
  pointer("pointerdown", 170);
  pointer("pointerup", 170);
  expect(select).toHaveBeenCalledExactlyOnceWith("2024-02-01");
  expect(host.querySelector("output")?.textContent).toBe("03.01");
  expect(host.querySelector(".rail-bubble")).toBeNull();
  pointer("pointerdown", 100);
  pointer("pointermove", 900);
  await nextTick();
  expect(track.getAttribute("aria-valuetext")).toBe("2024-01-01");
  pointer("pointercancel", 900);
  await nextTick();
  expect(select).toHaveBeenCalledTimes(1);
});
it("keeps the current date visible and follows reading position changes", async () => {
  const current = ref("2024-03-01");
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    render: () => h(TimelineRail, {
      dates: ["2024-03-01", "2024-02-20"], current: current.value,
    }),
  });
  app.mount(host);
  expect(host.querySelector("output")?.textContent).toBe("03.01");
  current.value = "2024-02-20";
  await nextTick();
  expect(host.querySelector("output")?.textContent).toBe("02.20");
  expect(host.querySelector<HTMLElement>("output")?.style.top).toBe("100%");
});
it("hides the rail if the timeline has one date", async () => {
  const select = vi.fn();
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    render: () =>
      h(TimelineRail, {
        dates: ["2024-01-01"],
        current: "2024-01-01",
        onSelect: select,
      }),
  });
  app.mount(host);
  expect(host.querySelector('[role="slider"]')).toBeNull();
  expect(select).not.toHaveBeenCalled();
});

it("spaces nodes apart while retaining every date for drag browsing and keeps the held output mounted", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const scrub = vi.fn();
  const dates = Array.from({ length: 67 }, (_, i) => new Date(Date.UTC(2024, 0, i + 1)).toISOString().slice(0, 10));
  app = createApp(TimelineRail, { dates, current: dates[0], onScrub: scrub });
  app.mount(host);
  const track = host.querySelector<HTMLElement>('[role="slider"]')!;
  track.getBoundingClientRect = () => ({ top: 0, height: 200 }) as DOMRect;
  track.setPointerCapture = vi.fn();
  track.dispatchEvent(new PointerEvent("pointerdown", { clientY: 0, pointerId: 1, isPrimary: true, button: 0 }));
  await nextTick();
  const output = host.querySelector("output");
  const dots = [...host.querySelectorAll<HTMLElement>(".rail-dot")];
  expect(dots.length).toBe(4);
  expect(parseFloat(dots[1].style.top) / 100 * 168).toBeGreaterThanOrEqual(44);
  track.dispatchEvent(new PointerEvent("pointermove", { clientY: 32, pointerId: 1 }));
  await nextTick();
  expect(scrub).toHaveBeenLastCalledWith(dates[6]);
  expect(host.querySelector("output")).toBe(output);
  expect(host.querySelector(".rail-bubble")?.textContent).toBe("2024.01.07");
  expect(output?.textContent).toBe("01.07");
});
