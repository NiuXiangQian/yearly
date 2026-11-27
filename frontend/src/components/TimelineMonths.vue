<script setup lang="ts" generic="T extends { date?: string; day?: string }">
import { computed, ref, useId } from "vue";
import { ChevronDown } from "lucide-vue-next";
import { t, locale } from "../lib/i18n";

const props = defineProps<{ days: T[]; disabled?: boolean; ungrouped?: boolean; compact?: boolean }>();
defineSlots<{ default(props: { day: T }): any }>();
const id = useId();
const defaultCollapsed = ref(false);
const collapsed = ref<Record<string, boolean>>({});
const months = computed(() => {
  const groups = new Map<string, T[]>();
  for (const day of props.days) {
    const key = (day.date || day.day || "unknown").slice(0, 7);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(day);
  }
  return [...groups].map(([key, days]) => ({
    key,
    days,
    title:
      key === "unknown"
        ? t("拍摄时间未知")
        : new Date(
            +key.slice(0, 4),
            +key.slice(5, 7) - 1,
            1,
          ).toLocaleDateString(locale.value, {
            year: "numeric",
            month: "long",
          }),
    closed: !props.disabled && (collapsed.value[key] ?? defaultCollapsed.value),
  }));
});
function setAll(value: boolean) {
  defaultCollapsed.value = value;
  collapsed.value = {};
}
defineExpose({
  setAll,
  reveal(date: string) {
    collapsed.value[date.slice(0, 7)] = false;
  },
});
</script>

<template>
  <div v-if="ungrouped">
    <template v-for="day in days" :key="day.date || day.day"><slot :day="day" /></template>
  </div>
  <div v-else-if="months.length" class="timeline-months" :class="{ 'compact-months': compact }">
    <div v-if="!compact" class="month-controls">
      <span>{{ t("按月浏览") }}</span>
      <div>
        <button
          type="button"
          class="text-button"
          :disabled="disabled"
          @click="setAll(true)"
        >
          {{ t("全部收起") }}
        </button>
        <button
          type="button"
          class="text-button"
          :disabled="disabled"
          @click="setAll(false)"
        >
          {{ t("全部展开") }}
        </button>
      </div>
    </div>
    <section v-for="month in months" :key="month.key" class="timeline-month">
      <h2 class="month-heading">
        <button
          type="button"
          class="month-toggle"
          :disabled="disabled"
          :aria-expanded="!month.closed"
          :aria-controls="`${id}-${month.key}`"
          @click="collapsed[month.key] = !month.closed"
        >
          <ChevronDown :size="18" :class="{ closed: month.closed }" />
          <span class="month-title">{{ month.title }}</span>
          <small v-if="month.key !== 'unknown'">{{
            t(compact ? "{p0} 天" : "已加载 {p0} 天", { p0: month.days.length })
          }}</small>
        </button>
      </h2>
      <div v-if="!month.closed" :id="`${id}-${month.key}`" class="month-days">
        <template v-for="day in month.days" :key="day.date || day.day">
          <slot :day="day" />
        </template>
      </div>
    </section>
  </div>
</template>

<style scoped>
.month-controls,
.month-controls > div,
.month-toggle {
  display: flex;
  align-items: center;
  gap: 16px;
}
.month-controls {
  justify-content: space-between;
  margin-bottom: 16px;
  color: var(--muted);
  font-size: 12px;
}
.timeline-month {
  margin-bottom: 24px;
}
.month-heading {
  margin: 0 0 18px;
}
.month-toggle {
  width: 100%;
  padding: 14px 16px;
  border: 1px solid transparent;
  border-radius: 12px;
  background: var(--surface-soft);
  color: var(--text);
  text-align: left;
  cursor: pointer;
  font: inherit;
  font-size: 18px;
}
.month-toggle:hover:not(:disabled) {
  background: var(--surface-hover);
}
.month-toggle svg {
  flex-shrink: 0;
  transition: transform var(--motion-fast) var(--ease-out);
}
.month-toggle svg.closed {
  transform: rotate(-90deg);
}
.month-toggle small {
  margin-left: auto;
  color: var(--muted);
  font-size: 12px;
  font-weight: 400;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}
.month-days {
  animation: content-reveal var(--motion-reveal) var(--ease-out);
}
.month-title {
  min-width: 0;
}
.compact-months .timeline-month { margin-bottom: 14px; }
.compact-months .month-heading { margin-bottom: 14px; }
.compact-months .month-toggle {
  min-height: 44px;
  padding: 8px 2px;
  gap: 10px;
  background: transparent;
  border: 0;
  border-bottom: 1px solid var(--line);
  border-radius: 0;
  font-size: 16px;
}
.compact-months .month-toggle svg { width: 14px; color: var(--sage); }
.compact-months .month-days { animation: none; }
@media (max-width: 700px) {
  .month-toggle {
    gap: 10px;
    padding: 12px;
    font-size: 16px;
  }
}
</style>
