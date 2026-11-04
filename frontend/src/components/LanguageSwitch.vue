<script setup lang="ts">
import { Languages } from "lucide-vue-next";
import { locale, setLocale, t, type Locale } from "../lib/i18n";
</script>
<template>
  <label class="language-switch">
    <Languages :size="16" aria-hidden="true" />
    <select
      :value="locale"
      :aria-label="t('界面语言')"
      @change="setLocale(($event.target as HTMLSelectElement).value as Locale)"
    >
      <option value="zh-CN">简体中文</option>
      <option value="en">English</option>
    </select>
  </label>
</template>
