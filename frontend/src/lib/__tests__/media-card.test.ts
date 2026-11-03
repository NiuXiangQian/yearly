// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import MediaCard from "../../components/MediaCard.vue";
vi.mock("../api", () => ({
  api: vi.fn(),
  localDate: (value: string) => value || "拍摄时间未知",
}));
const applications: ReturnType<typeof createApp>[] = [];
afterEach(() => {
  applications.forEach((app) => app.unmount());
  applications.length = 0;
  document.body.innerHTML = "";
  vi.useRealTimers();
  vi.unstubAllGlobals();
});
function render(props: any) {
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      observe() {}
      disconnect() {}
    },
  );
  const host = document.createElement("div");
  document.body.append(host);
  const app = createApp(MediaCard, {
    media: {
      id: 1,
      title: "成长照片",
      files: [],
      children: [],
      media_type: "photo",
    },
    ...props,
  });
  applications.push(app);
  app.mount(host);
  return host.querySelector("article")!;
}
it("enters multiselect after a touch hold and tolerates small finger movement", async () => {
  vi.useFakeTimers();
  const longpress = vi.fn(),
    open = vi.fn();
  const card = render({ onLongpress: longpress, onOpen: open });
  card.dispatchEvent(
    new PointerEvent("pointerdown", {
      pointerType: "touch",
      clientX: 100,
      clientY: 100,
      bubbles: true,
    }),
  );
  card.dispatchEvent(
    new PointerEvent("pointermove", {
      pointerType: "touch",
      clientX: 103,
      clientY: 102,
      bubbles: true,
    }),
  );
  await vi.advanceTimersByTimeAsync(550);
  expect(longpress).toHaveBeenCalledOnce();
  card.dispatchEvent(
    new PointerEvent("pointerup", { pointerType: "touch", bubbles: true }),
  );
  card.click();
  expect(open).not.toHaveBeenCalled();
});
it("cancels a long press when the user scrolls", async () => {
  vi.useFakeTimers();
  const longpress = vi.fn();
  const card = render({ onLongpress: longpress });
  card.dispatchEvent(
    new PointerEvent("pointerdown", {
      pointerType: "touch",
      clientX: 0,
      clientY: 0,
      bubbles: true,
    }),
  );
  card.dispatchEvent(
    new PointerEvent("pointermove", {
      pointerType: "touch",
      clientX: 0,
      clientY: 50,
      bubbles: true,
    }),
  );
  await vi.advanceTimersByTimeAsync(700);
  expect(longpress).not.toHaveBeenCalled();
});
it("forwards a desktop shift selection without opening media", () => {
  const selected = vi.fn(),
    open = vi.fn();
  const card = render({ selection: true, onSelect: selected, onOpen: open });
  card.dispatchEvent(
    new MouseEvent("click", { bubbles: true, shiftKey: true }),
  );
  expect(selected).toHaveBeenCalledWith(
    expect.objectContaining({ id: 1 }),
    true,
  );
  expect(open).not.toHaveBeenCalled();
});
