<script setup lang="ts">
import { ArrowDown, ArrowUp } from "lucide-vue-next";
import { t } from "../lib/i18n";
defineProps<{ modelValue: string; disabled?: boolean }>();
defineEmits<{ "update:modelValue": [value: "asc" | "desc"] }>();
</script>
<template>
  <div
    class="timeline-order segmented-control"
    role="group"
    :aria-label="t('时间顺序')"
  >
    <button
      type="button"
      :aria-pressed="modelValue === 'desc'"
      :disabled="disabled"
      @click="$emit('update:modelValue', 'desc')"
    >
      <ArrowDown :size="14" aria-hidden="true" />{{ t("最新在前") }}
    </button>
    <button
      type="button"
      :aria-pressed="modelValue === 'asc'"
      :disabled="disabled"
      @click="$emit('update:modelValue', 'asc')"
    >
      <ArrowUp :size="14" aria-hidden="true" />{{ t("最早在前") }}
    </button>
  </div>
</template>
