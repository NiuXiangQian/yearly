<script setup lang="ts">
import { computed, ref } from "vue";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
import { matchesProfile, profileCategories } from "../lib/profiles";
import ChildAvatar from "./ChildAvatar.vue";
const props = defineProps<{
  modelValue: number[];
  all?: boolean;
  disabled?: boolean;
}>();
const emit = defineEmits(["update:modelValue"]);
const yearly = useYearly();
const category = ref(""),
  search = ref("");
const categories = computed(() => profileCategories(yearly.children));
const visible = computed(() =>
  yearly.children.filter((p) =>
    matchesProfile(p, category.value, search.value),
  ),
);
function toggle(id: number) {
  emit(
    "update:modelValue",
    props.modelValue.includes(id)
      ? props.modelValue.filter((n) => n !== id)
      : [...props.modelValue, id],
  );
}
function selectCategory() {
  const ids = visible.value.map((p) => p.id);
  emit(
    "update:modelValue",
    props.all ? ids : [...new Set([...props.modelValue, ...ids])],
  );
}
</script>
<template>
  <div class="profile-picker">
    <div v-if="yearly.children.length" class="profile-picker-tools">
      <input
        v-model="search"
        type="search"
        :aria-label="t('搜索人物或宠物')"
        :placeholder="t('搜索名字、关系、分类')"
        :disabled="disabled"
      />
      <select
        v-model="category"
        :aria-label="t('查找档案分类')"
        :disabled="disabled"
      >
        <option
          v-for="item in categories"
          :key="item.value"
          :value="item.value"
        >
          {{ item.label }}
        </option>
      </select>
      <button
        v-if="category || search"
        type="button"
        class="text-button"
        :disabled="disabled || !visible.length"
        @click="selectCategory"
      >
        {{ all ? t("筛选这些档案") : t("选中这些档案") }}
      </button>
      <span v-if="modelValue.length" class="muted">{{
        t("已选 {p0} 个档案", { p0: modelValue.length })
      }}</span>
      <button
        v-if="modelValue.length && !all"
        type="button"
        class="text-button"
        :disabled="disabled"
        @click="
          category = '';
          search = '';
          emit('update:modelValue', []);
        "
      >
        {{ t("清空选择") }}
      </button>
    </div>
    <div class="child-picker">
      <button
        v-if="all"
        type="button"
        :disabled="disabled"
        class="child-pill"
        :class="{ selected: !modelValue.length }"
        @click="
          category = '';
          search = '';
          emit('update:modelValue', []);
        "
      >
        <span class="child-avatar all-avatar">{{ t("全") }}</span
        >{{ t("全部人物与宠物") }}
      </button>
      <button
        v-for="c in visible"
        :key="c.id"
        type="button"
        :disabled="disabled"
        class="child-pill"
        :class="{ selected: modelValue.includes(c.id) }"
        @click="toggle(c.id)"
      >
        <ChildAvatar :child="c" />{{ c.nickname || c.name }}
        <small
          v-if="
            c.profile_type === 'pet' ||
            (c.relationship && c.relationship !== (c.nickname || c.name)) ||
            (!c.relationship && c.profile_type !== 'person')
          "
          >{{
            c.profile_type === "pet"
              ? t("宠物") + (c.species ? " · " + t(c.species) : "")
              : t(
                  c.relationship ||
                    (c.profile_type === "child" || !c.profile_type
                      ? "孩子"
                      : "人物"),
                )
          }}</small
        >
        <small v-if="c.status === 'archived'">{{ t("已归档") }}</small>
        <span v-if="modelValue.includes(c.id)" class="selection-dot">✓</span>
      </button>
      <span v-if="!visible.length && yearly.children.length" class="muted">{{
        t("没有匹配的档案")
      }}</span>
      <slot />
    </div>
  </div>
</template>
<style scoped>
.profile-picker {
  min-width: 0;
  width: 100%;
}
.profile-picker-tools {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 10px;
  font-size: 12px;
}
.profile-picker-tools input {
  width: 190px;
  flex: 1 1 150px;
  max-width: 260px;
}
.profile-picker-tools select {
  max-width: 200px;
  padding-right: 36px;
}
.profile-picker-tools input,
.profile-picker-tools select {
  padding-top: 7px;
  padding-bottom: 7px;
  padding-left: 10px;
  font-size: 14px;
  min-height: 40px;
}
</style>
