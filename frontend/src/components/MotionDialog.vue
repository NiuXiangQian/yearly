<script lang="ts">
const activeSheets = new Map<symbol, number>();
function updateBackdrop(key: symbol, progress: number) {
  if (progress <= 0) activeSheets.delete(key); else activeSheets.set(key, progress);
  const amount = Math.max(0, ...activeSheets.values());
  document.documentElement.toggleAttribute('data-motion-sheet', amount > 0);
  document.documentElement.style.setProperty('--sheet-progress', String(amount));
  document.documentElement.style.setProperty('--sheet-scroll', `${window.scrollY}px`);
}
</script>
<script setup lang="ts">
import { ElDialog } from "element-plus";
import "element-plus/es/components/dialog/style/css";
import { onBeforeUnmount, ref, useAttrs } from "vue";
import { animateMotion, clamp, shouldDismissSheet } from "../lib/motion";
defineOptions({ inheritAttrs: false });
const attrs = useAttrs();
const dialog = ref<InstanceType<typeof ElDialog>>();
const key = Symbol();
let sheet: HTMLElement | null = null, progress = 0, stop = () => {};
let pointer = -1, start = 0, previousY = 0, previousTime = 0, velocity = 0;
const mobile = () => window.matchMedia?.('(max-width: 700px)').matches && !attrs.fullscreen;
function draw(value: number) {
  progress = value;
  if (sheet) sheet.style.transform = `translateY(${(1 - value) * (sheet.offsetHeight + 30)}px)`;
  updateBackdrop(key, clamp(value));
}
function enter(element: Element, done: () => void) {
  stop();
  if (!mobile()) { done(); return; }
  sheet = element.querySelector('.el-dialog');
  draw(0); stop = animateMotion(0, 1, draw, done);
}
function leave(_element: Element, done: () => void) {
  stop();
  if (!mobile()) { updateBackdrop(key, 0); done(); return; }
  stop = animateMotion(progress, 0, draw, done);
}
function down(event: PointerEvent) {
  if (!mobile() || attrs.showClose === false || attrs['show-close'] === false || event.button !== 0) return;
  const target = event.target as HTMLElement;
  sheet = target.closest('.el-dialog');
  if (!sheet || target.closest('button,input,a')) return;
  if (!target.closest('.el-dialog__header') && event.clientY - sheet.getBoundingClientRect().top > 44) return;
  stop(); pointer = event.pointerId; start = previousY = event.clientY; previousTime = event.timeStamp; velocity = 0;
  sheet?.setPointerCapture(pointer);
}
function move(event: PointerEvent) {
  if (event.pointerId !== pointer || !sheet) return;
  velocity = (event.clientY - previousY) / Math.max(1, event.timeStamp - previousTime);
  previousY = event.clientY; previousTime = event.timeStamp;
  const offset = event.clientY - start;
  draw(1 - (offset > 0 ? offset : offset * .15) / (sheet.offsetHeight + 30));
}
function end(event: PointerEvent) {
  if (event.pointerId !== pointer || !sheet) return;
  pointer = -1;
  if (event.type !== 'pointercancel' && shouldDismissSheet(event.clientY - start, sheet.offsetHeight,
      event.timeStamp - previousTime < 100 ? velocity : 0)) {
    // Use Element Plus's close path so before-close and form protections still apply.
    dialog.value?.handleClose();
  }
  stop = animateMotion(progress, 1, draw);
}
onBeforeUnmount(() => { stop(); updateBackdrop(key, 0); });
</script>
<template>
  <ElDialog ref="dialog" v-bind="attrs" append-to-body class="motion-dialog"
    :transition="{ name: 'motion-sheet', css: false, onEnter: enter, onLeave: leave }"
    @pointerdown="down" @pointermove="move" @pointerup="end" @pointercancel="end">
    <template v-for="(_, name) in $slots" #[name]="scope"><slot :name="name" v-bind="scope || {}" /></template>
  </ElDialog>
</template>
