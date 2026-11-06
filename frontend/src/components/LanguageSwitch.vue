<script setup lang="ts">
import { locale, setLocale, t } from "../lib/i18n";
</script>
<template>
  <div
    class="language-switch segmented-control"
    role="group"
    :aria-label="t('界面语言')"
  >
    <button
      type="button"
      lang="zh-CN"
      aria-label="简体中文"
      :aria-pressed="locale === 'zh-CN'"
      @click="setLocale('zh-CN')"
    >
      中文
    </button>
    <button
      type="button"
      lang="en"
      aria-label="English"
      :aria-pressed="locale === 'en'"
      @click="setLocale('en')"
    >
      EN
    </button>
  </div>
</template>
