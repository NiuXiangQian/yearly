<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch, useId } from "vue";
import { animateMotion, clamp, wormEdges } from "../lib/motion";
const props = defineProps<{ modelValue: string; tabs: { value: string; label: string; disabled?: boolean }[] }>();
const emit = defineEmits<{ 'update:modelValue': [value: string] }>();
const id = useId();
const index = computed(() => Math.max(0, props.tabs.findIndex(tab => tab.value === props.modelValue)));
const position = ref(index.value), viewport = ref<HTMLElement>();
const edges = computed(() => wormEdges(position.value));
let cancel = () => {}, startX = 0, startY = 0, startPosition = 0, dragging = false, pointer = -1, suppressClick = false;
function select(next: number) {
  if (!props.tabs[next] || props.tabs[next].disabled) return;
  cancel();
  cancel = animateMotion(position.value, next, value => position.value = value);
  emit('update:modelValue', props.tabs[next].value);
}
watch(index, next => { cancel(); cancel = animateMotion(position.value, next, value => position.value = value); });
function down(event: PointerEvent) {
  if ((event.target as HTMLElement).closest('input,select,textarea,[draggable="true"]')) return;
  suppressClick = false;
  cancel(); startX = event.clientX; startY = event.clientY; startPosition = position.value; pointer = event.pointerId; dragging = false;
}
function move(event: PointerEvent) {
  if (event.pointerId !== pointer) return;
  const dx = event.clientX - startX, dy = event.clientY - startY;
  if (!dragging && Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 8) { pointer = -1; return; }
  if (!dragging && Math.abs(dx) < 8) return;
  dragging = true; suppressClick = true; viewport.value?.setPointerCapture(event.pointerId);
  position.value = clamp(startPosition - dx / viewport.value!.clientWidth, 0, props.tabs.length - 1);
}
function end(cancelled = false) {
  if (pointer < 0) return;
  pointer = -1;
  const next = cancelled ? index.value : Math.round(position.value);
  select(props.tabs[next]?.disabled ? index.value : next);
  dragging = false;
}
onBeforeUnmount(() => cancel());
function click(event: MouseEvent) { if (suppressClick) { event.preventDefault(); event.stopPropagation(); suppressClick = false; } }
</script>
<template>
  <div class="motion-pager">
    <div role="tablist" class="motion-tabs">
      <button v-for="(tab, i) in tabs" :id="`${id}-tab-${i}`" :key="tab.value" role="tab" type="button"
        :aria-selected="index === i" :aria-controls="`${id}-panel-${i}`" :disabled="tab.disabled"
        :tabindex="index === i ? 0 : -1" @click="select(i)"
        @keydown.right.prevent="select(Math.min(tabs.length - 1, i + 1))" @keydown.left.prevent="select(Math.max(0, i - 1))"
        :style="{ color: `color-mix(in srgb, var(--sage) ${Math.max(0, 1 - Math.abs(position - i)) * 100}%, var(--muted))`, fontWeight: 400 + Math.max(0, 1 - Math.abs(position - i)) * 250 }">
        {{ tab.label }}
      </button>
      <span class="motion-tab-ink" :style="{ left: `${edges[0]! / tabs.length * 100}%`, width: `${(edges[1]! - edges[0]!) / tabs.length * 100}%` }" />
    </div>
    <div ref="viewport" class="motion-page-viewport" @pointerdown="down" @pointermove="move" @pointerup="end()" @pointercancel="end(true)" @click.capture="click">
      <div class="motion-page-track" :style="{ transform: `translateX(${-position * 100}%)` }">
        <section v-for="(tab, i) in tabs" :id="`${id}-panel-${i}`" :key="tab.value" role="tabpanel"
          :aria-labelledby="`${id}-tab-${i}`" :aria-hidden="index !== i" :inert="index !== i || undefined" class="motion-page">
          <slot :name="tab.value" />
        </section>
      </div>
    </div>
  </div>
</template>
