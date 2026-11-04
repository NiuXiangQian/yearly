<script setup lang="ts">
import { computed, ref } from "vue";
import { ElDatePicker } from "element-plus";
import { t, locale } from "../lib/i18n";
defineOptions({ inheritAttrs: false });
const picker = ref<{ focus(): void }>();
const props = withDefaults(
  defineProps<{
    modelValue?: string | null;
    type?: "date" | "datetime" | "month" | "year";
    required?: boolean;
    disabled?: boolean;
    placeholder?: string;
  }>(),
  { type: "date" },
);
const emit = defineEmits<{ "update:modelValue": [value: string] }>();
const format = computed(
  () =>
    ({
      date: "YYYY-MM-DD",
      datetime: "YYYY-MM-DD HH:mm",
      month: "YYYY-MM",
      year: "YYYY",
    })[props.type],
);
const shortcuts = computed(() => [
  { text: t("今天"), value: () => new Date() },
  {
    text: t("昨天"),
    value: () => {
      const date = new Date();
      date.setDate(date.getDate() - 1);
      return date;
    },
  },
]);
</script>
<template>
  <ElDatePicker
    :key="locale + type"
    v-bind="$attrs"
    ref="picker"
    class="date-field"
    :model-value="modelValue || ''"
    :type="type"
    :format="format"
    :value-format="type === 'datetime' ? 'YYYY-MM-DDTHH:mm' : format"
    :placeholder="
      placeholder ||
      t(
        type === 'year'
          ? '选择年份'
          : type === 'month'
            ? '选择月份'
            : '选择日期',
      )
    "
    :disabled="disabled"
    :clearable="!required"
    :editable="true"
    :shortcuts="type === 'date' || type === 'datetime' ? shortcuts : []"
    :default-time="new Date(2000, 0, 1, 12, 0)"
    @update:model-value="emit('update:modelValue', $event || '')"
  />
  <input
    v-if="required"
    class="date-required"
    tabindex="-1"
    aria-hidden="true"
    :value="modelValue || ''"
    :disabled="disabled"
    required
    @invalid.prevent="picker?.focus()"
  />
</template>
