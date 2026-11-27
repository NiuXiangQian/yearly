<script setup lang="ts">
import SharedThumbnail from "./SharedThumbnail.vue";
import { ageLabel } from "../lib/i18n";

defineProps<{
  base: string;
  media: {
    id: number;
    title: string;
    media_type: string;
    child_ages?: { name: string; age: string }[];
  };
}>();
</script>

<template>
  <div class="shared-media-image">
    <SharedThumbnail :base="base" :media="media" />
    <span
      v-if="media.title"
      class="shared-caption"
      :class="{ 'with-live-badge': media.media_type === 'live_photo' }"
    >{{ media.title }}</span>
  </div>
  <span v-if="media.child_ages?.length" class="shared-child-ages">
    <span v-for="({ name, age }, index) in media.child_ages" :key="index">
      {{ name }} · {{ ageLabel(age) }}
    </span>
  </span>
</template>

<style scoped>
.shared-media-image {
  display: block;
  position: relative;
}
.shared-caption {
  display: block;
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  border-radius: 0 0 10px 10px;
  background: linear-gradient(transparent, #15261acc);
  color: white;
  pointer-events: none;
  padding: 24px 10px 10px;
  font-size: 12px;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.shared-caption.with-live-badge {
  padding-left: 68px;
}
.shared-child-ages {
  display: block;
  padding: 4px 2px 0;
  color: var(--muted);
  font-size: 12px;
  line-height: 1.5;
  overflow-wrap: anywhere;
}
.shared-child-ages > span {
  display: block;
}
</style>
