<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch, type Component } from "vue";
import { useRoute } from "vue-router";
import { animateMotion, reducedMotion } from "../lib/motion";
const props = defineProps<{ items: { path: string; label: string; icon: Component }[] }>();
const route = useRoute();
const selected = computed(() => props.items.findIndex(item => item.path === route.path));
const leading = ref(Math.max(0, selected.value)), trailing = ref(leading.value);
let stopFront = () => {}, stopBack = () => {}, delay = 0;
watch(selected, (next, previous) => {
  stopFront(); stopBack(); clearTimeout(delay);
  if (next < 0) return;
  const front = next > previous ? leading : trailing;
  const back = next > previous ? trailing : leading;
  stopFront = animateMotion(front.value, next, value => front.value = value);
  delay = window.setTimeout(() => { stopBack = animateMotion(back.value, next, value => back.value = value); }, reducedMotion() ? 0 : 55);
});
onBeforeUnmount(() => { stopFront(); stopBack(); clearTimeout(delay); });
</script>
<template>
  <nav class="mobile-nav motion-nav" :style="{ '--nav-count': items.length }">
    <span v-show="selected >= 0" class="motion-nav-capsule" :style="{
      left: `${Math.min(leading, trailing) / items.length * 100}%`,
      width: `${(1 + Math.abs(leading - trailing)) / items.length * 100}%`,
      transform: `scaleY(${1 - Math.min(.22, Math.abs(leading - trailing) * .15)})`,
    }" />
    <RouterLink v-for="item in items" :key="item.path" :to="item.path">
      <component :is="item.icon" :size="21" /><span>{{ item.label }}</span>
    </RouterLink>
  </nav>
</template>
