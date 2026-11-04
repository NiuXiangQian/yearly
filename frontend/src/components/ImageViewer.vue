<script setup lang="ts">
import { ref, watch } from "vue";
import { ZoomIn, ZoomOut, Scan } from "lucide-vue-next";
import CompatibleImage from "./CompatibleImage.vue";
const props = defineProps<{ src: string; originalFile?: any; alt?: string }>();
const emit = defineEmits(["error"]);
const scale = ref(1),
  x = ref(0),
  y = ref(0);
const pointers = new Map<number, { x: number; y: number }>();
let distance = 0;
function reset() {
  scale.value = 1;
  x.value = 0;
  y.value = 0;
}
watch(() => props.src, reset);
function zoom(value: number) {
  scale.value = Math.max(0.5, Math.min(6, value));
  if (scale.value <= 1) {
    x.value = 0;
    y.value = 0;
  }
}
function down(e: PointerEvent) {
  (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    distance = Math.hypot(a.x - b.x, a.y - b.y);
  }
}
function move(e: PointerEvent) {
  const previous = pointers.get(e.pointerId);
  if (!previous) return;
  pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
  if (pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    const next = Math.hypot(a.x - b.x, a.y - b.y);
    if (distance > 0) zoom((scale.value * next) / distance);
    distance = next;
  } else if (scale.value > 1) {
    x.value += e.clientX - previous.x;
    y.value += e.clientY - previous.y;
  }
}
</script>
<template>
  <div class="image-viewer">
    <div
      class="image-pan"
      :class="{ zoomed: scale > 1 }"
      @wheel.prevent="zoom(scale * ($event.deltaY < 0 ? 1.12 : 1 / 1.12))"
      @dblclick="scale === 1 ? zoom(2) : reset()"
      @pointerdown="down"
      @pointermove="move"
      @pointerup="pointers.delete($event.pointerId)"
      @pointercancel="pointers.delete($event.pointerId)"
    >
      <CompatibleImage
        :src="src"
        :file="originalFile"
        :alt="alt || '影像预览'"
        draggable="false"
        :style="{ transform: `translate(${x}px, ${y}px) scale(${scale})` }"
        @error="emit('error')"
      />
    </div>
    <div class="image-tools">
      <button
        aria-label="缩小"
        :disabled="scale <= 0.5"
        @click="zoom(scale / 1.25)"
      >
        <ZoomOut :size="18" />
      </button>
      <span aria-live="polite">{{ Math.round(scale * 100) }}%</span>
      <button
        aria-label="放大"
        :disabled="scale >= 6"
        @click="zoom(scale * 1.25)"
      >
        <ZoomIn :size="18" />
      </button>
      <i></i
      ><button aria-label="适应窗口" title="适应窗口" @click="reset">
        <Scan :size="18" />
      </button>
    </div>
    <small class="image-gesture-hint">滚轮 / 双指缩放 · 放大后拖动画面</small>
  </div>
</template>
<style scoped>
.image-viewer {
  width: 100%;
  height: 100%;
  position: relative;
  overflow: hidden;
}
.image-pan {
  width: 100%;
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
  touch-action: none;
  user-select: none;
  padding: 20px 0 85px;
}
.image-pan.zoomed {
  cursor: grab;
}
.image-pan.zoomed:active {
  cursor: grabbing;
}
.image-pan img {
  width: 100%;
  height: 100%;
  object-fit: contain;
  pointer-events: none;
}
.image-tools {
  position: absolute;
  bottom: 38px;
  left: 50%;
  transform: translateX(-50%);
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 5px 8px;
  border-radius: 30px;
  border: 1px solid #ffffff26;
  background: #18291fe0;
  backdrop-filter: blur(12px);
  color: white;
}
.image-tools button {
  width: 34px;
  height: 34px;
  display: grid;
  place-items: center;
  color: inherit;
  background: none;
  border: 0;
  border-radius: 50%;
  cursor: pointer;
}
.image-tools button:hover {
  background: #ffffff25;
}
.image-tools button:disabled {
  opacity: 0.35;
}
.image-tools span {
  min-width: 43px;
  text-align: center;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}
.image-tools i {
  height: 20px;
  width: 1px;
  background: #ffffff30;
}
.image-gesture-hint {
  position: absolute;
  bottom: 14px;
  width: 100%;
  text-align: center;
  color: #c0cfc5;
  font-size: 10px;
  pointer-events: none;
}
</style>
