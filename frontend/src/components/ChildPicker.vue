<script setup lang="ts">
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
import ChildAvatar from "./ChildAvatar.vue";
const props = defineProps<{
  modelValue: number[];
  all?: boolean;
  disabled?: boolean;
}>();
const emit = defineEmits(["update:modelValue"]);
const yearly = useYearly();
function toggle(id: number) {
  emit(
    "update:modelValue",
    props.modelValue.includes(id)
      ? props.modelValue.filter((n) => n !== id)
      : [...props.modelValue, id],
  );
}
</script>
<template>
  <div class="child-picker">
    <button
      type="button"
      :disabled="disabled"
      v-if="all"
      class="child-pill"
      :class="{ selected: !modelValue.length }"
      @click="emit('update:modelValue', [])"
    >
      <span class="child-avatar all-avatar"> {{ t("全") }} </span>
      {{ t("全部孩子与宠物") }}</button
    ><button
      type="button"
      :disabled="disabled"
      v-for="c in yearly.children"
      :key="c.id"
      class="child-pill"
      :class="{ selected: modelValue.includes(c.id) }"
      @click="toggle(c.id)"
    >
      <ChildAvatar :child="c" />{{ c.nickname || c.name
      }}<small v-if="c.profile_type === 'pet'">{{ t("宠物") }}</small
      ><small v-if="c.status === 'archived'"> {{ t("已归档") }} </small
      ><span v-if="modelValue.includes(c.id)" class="selection-dot"
        >✓</span
      ></button
    ><slot />
  </div>
</template>
