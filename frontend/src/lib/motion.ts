// Shared timing for navigation, sheets and paging. Pointer updates bypass animation.
export const motionDuration = 400;
export const reducedMotion = () => window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
export const clamp = (value: number, low = 0, high = 1) => Math.min(high, Math.max(low, value));

export function animateMotion(from: number, to: number, update: (value: number) => void, complete?: () => void) {
  if (reducedMotion()) { update(to); complete?.(); return () => {}; }
  const start = performance.now();
  let frame = 0;
  const tick = (now: number) => {
    const t = clamp((now - start) / motionDuration);
    const spring = 1 - Math.exp(-7 * t) * Math.cos(10 * t);
    update(t === 1 ? to : from + (to - from) * spring);
    if (t < 1) frame = requestAnimationFrame(tick);
    else complete?.();
  };
  frame = requestAnimationFrame(tick);
  return () => cancelAnimationFrame(frame);
}

// The leading edge travels first; both edges meet exactly at each page boundary.
export function wormEdges(position: number) {
  const base = Math.floor(position), fraction = position - base;
  return [base + fraction * fraction, base + 1 + 1 - (1 - fraction) ** 2];
}

export function shouldDismissSheet(distance: number, height: number, velocity: number) {
  return distance > height / 3 || (distance > 12 && velocity > 0.8);
}
