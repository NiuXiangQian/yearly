// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, h, nextTick } from "vue";
import TimelineRail from "../../components/TimelineRail.vue";
let app: ReturnType<typeof createApp>;
afterEach(() => {
  app?.unmount();
  document.body.innerHTML = "";
});
it("previews the nearest date during drag and navigates only on release", async () => {
  const select = vi.fn();
  const host = document.createElement("div");
  document.body.append(host);
  app = createApp({
    render: () =>
      h(TimelineRail, {
        dates: ["2024-03-01", "2024-02-01", "2024-01-01"],
        current: "2024-03-01",
        onSelect: select,
      }),
  });
  app.mount(host);
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
  expect(host.querySelector("output")?.textContent).toBe("2024-02-01");
  expect(select).not.toHaveBeenCalled();
  pointer("pointerup", 205);
  await nextTick();
  expect(select).toHaveBeenCalledExactlyOnceWith("2024-02-01");
  expect(host.querySelector("output")).toBeNull();
  pointer("pointerdown", 100);
  pointer("pointermove", 900);
  await nextTick();
  expect(track.getAttribute("aria-valuetext")).toBe("2024-01-01");
  pointer("pointercancel", 900);
  await nextTick();
  expect(select).toHaveBeenCalledTimes(1);
});
it("supports a single date and keyboard endpoints without invalid values", async () => {
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
  const track = host.querySelector('[role="slider"]')!;
  track.dispatchEvent(
    new KeyboardEvent("keydown", { key: "End", bubbles: true }),
  );
  expect(select).toHaveBeenCalledWith("2024-01-01");
  expect(host.querySelector<HTMLElement>(".rail-thumb")?.style.top).toBe("0%");
});
