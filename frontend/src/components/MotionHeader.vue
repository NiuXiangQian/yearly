<script setup lang="ts">
import { onMounted, onBeforeUnmount, onUpdated, ref } from "vue";
import { animateMotion, clamp, reducedMotion } from "../lib/motion";
const root = ref<HTMLElement>();
const title = ref(''), progress = ref(0), titleStyle = ref<Record<string, string>>({});
let heading: HTMLElement | null = null, headingTop = 0, headingLeft = 0, headingSize = 26;
let touchStart = 0, pull = 0, holding = false, stopPull = () => {};
function drawPull(value: number) {
  pull = value;
  root.value?.style.setProperty('--header-stretch', String(reducedMotion() ? 1 : 1 + value / 400));
  root.value?.style.setProperty('--header-parallax', `${reducedMotion() ? 0 : value * .5}px`);
}
function touchDown(event: TouchEvent) { stopPull(); holding = true; touchStart = event.touches[0].clientY; }
function touchMove(event: TouchEvent) {
  const distance = event.touches[0].clientY - touchStart;
  if (window.scrollY <= 0 && distance > 0) { event.preventDefault(); drawPull(Math.min(140, distance * .6)); }
}
function release() {
  holding = false;
  stopPull = animateMotion(pull, 0, drawPull);
  settle();
}
let frame = 0, timer = 0, origin = 0, previousY = 0, previousTime = 0, velocity = 0, cancel = () => {}, snapping = false;
function update() {
  frame = 0;
  if (!root.value) return;
  const now = performance.now(), y = window.scrollY;
  if (!snapping) velocity = (y - previousY) / Math.max(1, now - previousTime);
  previousY = y; previousTime = now;
  const offset = y - origin;
  progress.value = clamp(offset / 140);
  root.value.style.setProperty('--header-progress', String(progress.value));
  root.value.style.setProperty('--header-parallax', `${reducedMotion() ? 0 : Math.max(-140, offset) * .5}px`);
  root.value.style.setProperty('--header-stretch', String(reducedMotion() ? 1 : 1 + Math.max(0, -offset) / 400));
  const p = progress.value;
  titleStyle.value = { left: `${headingLeft * (1 - p) + 20 * p}px`, top: `${(headingTop - y) * (1 - p) + 14 * p}px`, fontSize: `${headingSize * (1 - p) + 18 * p}px` };
  if (heading) heading.style.visibility = p > 0 ? 'hidden' : '';
}
function settle() {
  if (snapping || holding) return;
  const offset = window.scrollY - origin;
  if (offset <= 0 || offset >= 140) return;
  const target = Math.abs(velocity) > .15 ? (velocity > 0 ? 140 : 0) : (offset > 70 ? 140 : 0);
  snapping = true;
  cancel = animateMotion(window.scrollY, origin + target, y => window.scrollTo(0, y), () => snapping = false);
}
function scroll() {
  if (!frame) frame = requestAnimationFrame(update);
  clearTimeout(timer);
  if (!snapping) timer = window.setTimeout(settle, 130);
}
function interrupt() { cancel(); snapping = false; clearTimeout(timer); }
function measure() {
  if (!heading) return;
  const rect = heading.getBoundingClientRect();
  headingTop = rect.top + window.scrollY; headingLeft = rect.left;
  headingSize = parseFloat(getComputedStyle(heading).fontSize);
  update();
}
onMounted(() => {
  heading = root.value!.querySelector('h1');
  if (heading) {
    const rect = heading.getBoundingClientRect();
    headingTop = rect.top + window.scrollY; headingLeft = rect.left;
    headingSize = parseFloat(getComputedStyle(heading).fontSize); title.value = heading.textContent || '';
  }
  origin = 0;
  update();
  window.addEventListener('resize', measure);
  window.addEventListener('scroll', scroll, { passive: true });
  window.addEventListener('pointerdown', interrupt, { passive: true });
  window.addEventListener('wheel', interrupt, { passive: true });
});
onUpdated(() => { if (heading && title.value !== heading.textContent) title.value = heading.textContent || ''; });
onBeforeUnmount(() => {
  cancel(); stopPull(); cancelAnimationFrame(frame); clearTimeout(timer);
  window.removeEventListener('resize', measure);
  window.removeEventListener('scroll', scroll); window.removeEventListener('pointerdown', interrupt); window.removeEventListener('wheel', interrupt);
});
</script>
<template>
  <div ref="root" class="motion-header" @touchstart.passive="touchDown" @touchmove="touchMove" @touchend="release" @touchcancel="release"><div class="motion-header-art" aria-hidden="true"><slot name="image" /></div><slot /></div>
  <Teleport to="body">
    <div v-show="progress > 0" class="motion-sticky-glass" :style="{ opacity: progress }" aria-hidden="true" />
    <div v-show="progress > 0" class="motion-flying-title" :style="titleStyle" aria-hidden="true">{{ title }}</div>
  </Teleport>
</template>
