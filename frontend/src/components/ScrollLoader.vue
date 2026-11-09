<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { t } from "../lib/i18n";

const props = defineProps<{
  loading: boolean;
  hasMore: boolean;
  error?: string;
}>();
const emit = defineEmits<{ load: [] }>();
const sentinel = ref<HTMLElement>();
let observer: IntersectionObserver;
let visible = false;

function loadIfVisible() {
  if (!visible || props.loading || !props.hasMore || props.error || !sentinel.value)
    return;
  const bounds = sentinel.value.getBoundingClientRect();
  if (bounds.top <= window.innerHeight + 200 && bounds.bottom >= -200) emit("load");
}

onMounted(() => {
  observer = new IntersectionObserver(
    ([entry]) => {
      visible = entry.isIntersecting;
      loadIfVisible();
    },
    { rootMargin: "200px" },
  );
  if (sentinel.value) observer.observe(sentinel.value);
});
watch(
  () => [props.loading, props.hasMore, props.error],
  async () => {
    await nextTick();
    loadIfVisible();
  },
);
onBeforeUnmount(() => observer?.disconnect());
</script>

<template>
  <div ref="sentinel" class="scroll-loader" role="status" aria-live="polite">
    <template v-if="error">
      <span>{{ error }}</span>
      <button class="button" :disabled="loading" @click="emit('load')">
        {{ t("重试") }}
      </button>
    </template>
    <span v-else-if="loading">{{ t("正在加载…") }}</span>
  </div>
</template>

<style scoped>
.scroll-loader {
  min-height: 1px;
  text-align: center;
  color: var(--muted);
  font-size: 12px;
}
.scroll-loader:has(> *) {
  padding: 16px;
}
.scroll-loader .button {
  margin-left: 12px;
}
</style>
