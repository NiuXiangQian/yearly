// @vitest-environment happy-dom
import { describe, expect, it, vi } from "vitest";
import { animateMotion, shouldDismissSheet, wormEdges } from "../motion";

describe("motion gesture boundaries", () => {
  it("keeps a slow short drag open and closes beyond one third", () => {
    expect(shouldDismissSheet(199, 600, 0.1)).toBe(false);
    expect(shouldDismissSheet(201, 600, 0.1)).toBe(true);
    expect(shouldDismissSheet(40, 600, 0.9)).toBe(true);
    expect(shouldDismissSheet(4, 600, 2)).toBe(false);
    expect(shouldDismissSheet(-40, 600, -2)).toBe(false);
  });
  it("stretches between pages and returns exactly to each label", () => {
    expect(wormEdges(0)).toEqual([0, 1]);
    expect(wormEdges(0.5)).toEqual([0.25, 1.75]);
    expect(wormEdges(2)).toEqual([2, 3]);
  });
  it("finishes synchronously when reduced motion is requested", () => {
    const match = vi.spyOn(window, "matchMedia").mockReturnValue({ matches: true } as MediaQueryList);
    const update = vi.fn(), complete = vi.fn();
    animateMotion(0.2, 1, update, complete);
    expect(update).toHaveBeenCalledExactlyOnceWith(1);
    expect(complete).toHaveBeenCalledOnce();
    match.mockRestore();
  });
});
