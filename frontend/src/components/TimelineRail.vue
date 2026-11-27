<script setup lang="ts">
import { computed, ref, watch, onBeforeUnmount } from "vue";
import { t } from "../lib/i18n";

const props = defineProps<{ dates: string[]; current: string; disabled?: boolean }>();
const emit = defineEmits<{
  select: [date: string];
  scrub: [date: string];
  hold: [active: boolean];
  cancel: [];
}>();
const inset = 16;
const track = ref<HTMLElement>();
const height = ref(400);
const dragRatio = ref<number>();
let pointer: { id: number; y: number } | undefined;
let observer: ResizeObserver | undefined;
watch(track, element => {
  observer?.disconnect();
  if (!element) return;
  observer = new ResizeObserver(([entry]) => {
    if (entry.contentRect.height) height.value = entry.contentRect.height;
  });
  observer.observe(element);
}, { flush: "post" });
onBeforeUnmount(() => observer?.disconnect());

const span = computed(() => Math.max(1, props.dates.length - 1));
const currentIndex = computed(() => Math.max(0, props.dates.indexOf(props.current)));
const ratio = computed(() => dragRatio.value ?? currentIndex.value / span.value);
const index = computed(() => Math.max(0, Math.ceil(ratio.value * span.value - .5)));
const date = computed(() => props.dates[index.value] || "");
const markers = computed(() => {
  const last = props.dates.length - 1;
  const step = Math.max(1, Math.ceil(44 * last / Math.max(1, height.value - inset * 2)));
  const count = Math.min(props.dates.length, Math.max(2, Math.floor(last / step) + 1));
  return count > 1 ? Array.from({ length: count }, (_, i) => Math.round(i * last / (count - 1))) : [0];
});
function top(i: number) { return `${(i / span.value) * 100}%`; }
function dayText(day: string) { return day.slice(5).replace("-", "."); }
function pointerRatio(event: PointerEvent) {
  const rect = track.value!.getBoundingClientRect();
  return Math.max(0, Math.min(1, (event.clientY - rect.top - inset) / Math.max(1, rect.height - inset * 2)));
}
function start(event: PointerEvent) {
  if (props.disabled || !event.isPrimary || event.button !== 0 || pointer) return;
  height.value = track.value!.getBoundingClientRect().height;
  pointer = { id: event.pointerId, y: event.clientY };
  track.value!.setPointerCapture(event.pointerId);
}
function move(event: PointerEvent) {
  if (pointer?.id !== event.pointerId) return;
  if (dragRatio.value === undefined) {
    if (Math.abs(event.clientY - pointer.y) <= 6) return;
    emit("hold", true);
  }
  dragRatio.value = pointerRatio(event);
  if (date.value) emit("scrub", date.value);
}
function finish(event: PointerEvent) {
  if (pointer?.id !== event.pointerId) return;
  move(event);
  if (dragRatio.value === undefined) {
    const target = pointerRatio(event) * span.value;
    const nearest = markers.value.reduce((best, marker) =>
      Math.abs(marker - target) < Math.abs(best - target) ? marker : best);
    emit("select", props.dates[nearest]);
  } else {
    dragRatio.value = undefined;
    emit("hold", false);
  }
  pointer = undefined;
  if (track.value?.hasPointerCapture(event.pointerId)) track.value.releasePointerCapture(event.pointerId);
}
function cancel(event: PointerEvent) {
  if (pointer?.id !== event.pointerId) return;
  pointer = undefined;
  if (dragRatio.value === undefined) return;
  dragRatio.value = undefined;
  emit("cancel");
  emit("hold", false);
}
function keydown(event: KeyboardEvent) {
  if (props.disabled) return;
  let target = currentIndex.value;
  if (event.key === "ArrowDown" || event.key === "ArrowRight") target++;
  else if (event.key === "ArrowUp" || event.key === "ArrowLeft") target--;
  else if (event.key === "Home") target = 0;
  else if (event.key === "End") target = props.dates.length - 1;
  else return;
  event.preventDefault();
  emit("select", props.dates[Math.max(0, Math.min(props.dates.length - 1, target))]);
}
</script>

<template>
  <aside v-if="dates.length > 1" class="timeline-rail">
    <span class="rail-year" aria-hidden="true">{{ date.slice(0, 4) }}</span>
    <div ref="track" class="rail-track" :class="{ dragging: dragRatio !== undefined }"
      role="slider" :tabindex="disabled ? -1 : 0" :aria-label="t('拖动时间轴定位日期')"
      aria-orientation="vertical" aria-valuemin="0" :aria-valuemax="dates.length - 1"
      :aria-valuenow="index" :aria-valuetext="date" :aria-disabled="disabled || undefined"
      @pointerdown.prevent="start" @pointermove="move" @pointerup="finish"
      @pointercancel="cancel" @lostpointercapture="cancel" @keydown="keydown">
      <div class="rail-scale" aria-hidden="true">
        <span class="rail-line"></span>
        <template v-for="(marker, i) in markers" :key="dates[marker]">
          <span class="rail-dot" :style="{ top: top(marker) }"></span>
          <span v-if="Math.abs(marker / span - ratio) * (height - inset * 2) > 26"
            class="rail-node" :style="{ top: top(marker) }">
            <b v-if="i === 0 || dates[marker].slice(0, 4) !== dates[markers[i - 1]].slice(0, 4)">{{ dates[marker].slice(0, 4) }}</b>
            {{ dayText(dates[marker]) }}
          </span>
        </template>
        <span class="rail-thumb" :style="{ top: `${ratio * 100}%` }"></span>
        <output class="rail-date" :style="{ top: `${ratio * 100}%` }">{{ dayText(date) }}</output>
        <span v-if="dragRatio !== undefined" class="rail-bubble" :style="{ top: `${ratio * 100}%` }">{{ date.replaceAll("-", ".") }}</span>
      </div>
    </div>
  </aside>
</template>

<style scoped>
.timeline-rail {
  position: sticky;
  top: calc(var(--shared-bar-height, 54px) + 10px);
  align-self: start;
  width: 44px;
  display: grid;
  gap: 12px;
  z-index: 5;
  font-variant-numeric: tabular-nums;
}
.rail-year {
  display: grid;
  place-content: center;
  height: 24px;
  border-radius: 6px;
  color: var(--sage);
  background: color-mix(in srgb, var(--sage) 10%, var(--bg));
  font-size: 11px;
  font-weight: 650;
}
.rail-track {
  position: relative;
  height: clamp(150px, calc(100dvh - var(--shared-bar-height, 54px) - 65px), 760px);
  touch-action: none;
  user-select: none;
  cursor: grab;
  border-radius: 6px;
}
.rail-track.dragging { cursor: grabbing; }
.rail-track[aria-disabled="true"] { cursor: wait; }
.rail-scale { position: absolute; inset: 16px 0; pointer-events: none; }
.rail-line {
  position: absolute;
  inset: 0 4px 0 auto;
  width: 1.5px;
  background: var(--line);
}
.rail-dot, .rail-thumb {
  position: absolute;
  left: 39px;
  transform: translate(-50%, -50%);
  border-radius: 50%;
  background: var(--sage);
}
.rail-dot { width: 5px; height: 5px; opacity: .55; }
.rail-thumb { width: 9px; height: 9px; box-shadow: 0 0 0 4.5px color-mix(in srgb, var(--sage) 15%, transparent); }
.rail-node, .rail-date {
  position: absolute;
  inset-inline-start: 0;
  width: 34px;
  transform: translateY(-50%);
  color: var(--muted);
  font-size: 10px;
  line-height: 1.1;
  text-align: center;
}
.rail-node b { display: block; margin-bottom: 2px; color: var(--text); }
.rail-date {
  display: grid;
  place-content: center;
  min-height: 22px;
  border-radius: 5px;
  background: color-mix(in srgb, var(--sage) 12%, var(--bg));
  color: var(--sage);
  font-weight: 650;
}
.rail-bubble {
  position: absolute;
  left: 60px;
  transform: translateY(-100%);
  padding: 7px 12px;
  color: var(--text);
  background: var(--surface);
  box-shadow: 0 1px 5px #0003;
  border-radius: 999px;
  font-weight: 650;
  white-space: nowrap;
}
</style>
