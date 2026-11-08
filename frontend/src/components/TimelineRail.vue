<script setup lang="ts">
import { computed, ref } from "vue";
import { t } from "../lib/i18n";

const props = defineProps<{
  dates: string[];
  current: string;
  disabled?: boolean;
}>();
const emit = defineEmits<{ select: [date: string] }>();
const track = ref<HTMLElement>();
const dragging = ref<number | null>(null);
const focused = ref(false);
const index = computed(
  () => dragging.value ?? Math.max(0, props.dates.indexOf(props.current)),
);
const position = computed(() =>
  props.dates.length > 1 ? (index.value / (props.dates.length - 1)) * 100 : 0,
);
function move(event: PointerEvent) {
  if (dragging.value === null) return;
  const rect = track.value!.getBoundingClientRect();
  dragging.value = Math.round(
    Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height)) *
      (props.dates.length - 1),
  );
}
function start(event: PointerEvent) {
  if (props.disabled || !event.isPrimary || event.button !== 0) return;
  track.value!.setPointerCapture(event.pointerId);
  dragging.value = index.value;
  move(event);
}
function finish(event: PointerEvent) {
  if (dragging.value === null) return;
  move(event);
  const date = props.dates[dragging.value];
  dragging.value = null;
  if (track.value?.hasPointerCapture(event.pointerId))
    track.value.releasePointerCapture(event.pointerId);
  if (date) emit("select", date);
}
function keydown(event: KeyboardEvent) {
  if (props.disabled) return;
  let target = index.value;
  if (event.key === "ArrowDown" || event.key === "ArrowRight") target++;
  else if (event.key === "ArrowUp" || event.key === "ArrowLeft") target--;
  else if (event.key === "Home") target = 0;
  else if (event.key === "End") target = props.dates.length - 1;
  else return;
  event.preventDefault();
  emit(
    "select",
    props.dates[Math.max(0, Math.min(props.dates.length - 1, target))],
  );
}
</script>

<template>
  <aside v-if="dates.length" class="timeline-rail">
    <span class="rail-edge" aria-hidden="true">{{
      dates[0].slice(0, 7).replace("-", ".")
    }}</span>
    <div
      ref="track"
      class="rail-track"
      :class="{ dragging: dragging !== null }"
      role="slider"
      :tabindex="disabled ? -1 : 0"
      :aria-label="t('拖动时间轴定位日期')"
      aria-orientation="vertical"
      :aria-valuemin="0"
      :aria-valuemax="dates.length - 1"
      :aria-valuenow="index"
      :aria-valuetext="dates[index]"
      :aria-disabled="disabled || undefined"
      @pointerdown.prevent="start"
      @pointermove="move"
      @pointerup="finish"
      @pointercancel="dragging = null"
      @lostpointercapture="dragging = null"
      @keydown="keydown"
      @focus="focused = true"
      @blur="focused = false"
    >
      <span class="rail-line" aria-hidden="true"></span>
      <span
        v-for="(date, i) in dates"
        :key="date"
        class="rail-dot"
        :style="{
          top: `${dates.length > 1 ? (i / (dates.length - 1)) * 100 : 0}%`,
        }"
        aria-hidden="true"
      ></span>
      <span
        class="rail-thumb"
        :style="{ top: `${position}%` }"
        aria-hidden="true"
      ></span>
      <output
        v-if="dragging !== null || focused"
        class="rail-date"
        :style="{ top: `${position}%` }"
        aria-hidden="true"
        >{{ dates[index] }}</output
      >
    </div>
    <span class="rail-edge" aria-hidden="true">{{
      dates[dates.length - 1].slice(0, 7).replace("-", ".")
    }}</span>
  </aside>
</template>

<style scoped>
.timeline-rail {
  position: sticky;
  top: 28px;
  align-self: start;
  display: flex;
  align-items: center;
  flex-direction: column;
  gap: 18px;
  padding-top: 8px;
  z-index: 5;
}
.rail-edge {
  color: var(--muted);
  font-size: 10px;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}
.rail-track {
  position: relative;
  width: 44px;
  height: clamp(180px, 56dvh, 520px);
  touch-action: none;
  user-select: none;
  cursor: grab;
  outline-offset: 6px;
  border-radius: 12px;
}
.rail-track.dragging {
  cursor: grabbing;
}
.rail-track[aria-disabled="true"] {
  cursor: wait;
}
.rail-line {
  position: absolute;
  top: 0;
  bottom: 0;
  left: calc(50% - 1px);
  width: 2px;
  background: var(--line);
}
.rail-dot,
.rail-thumb {
  position: absolute;
  left: 50%;
  transform: translate(-50%, -50%);
  border-radius: 50%;
  background: var(--sage);
  pointer-events: none;
}
.rail-dot {
  width: 6px;
  height: 6px;
  opacity: 0.65;
}
.rail-thumb {
  width: 14px;
  height: 14px;
  box-shadow: 0 0 0 5px var(--sage-light);
}
.rail-date {
  position: absolute;
  left: calc(50% + 19px);
  transform: translateY(-50%);
  padding: 9px 12px;
  border-radius: 8px;
  background: var(--text);
  color: var(--surface);
  box-shadow: 0 4px 18px #0002;
  font-size: 13px;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  pointer-events: none;
}
@media (max-width: 700px) {
  .rail-edge {
    font-size: 8px;
  }
  .rail-track {
    width: 32px;
  }
}
</style>
