<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from "vue";
import { Play, ImageOff } from "lucide-vue-next";
import { api } from "../lib/api";
import { t } from "../lib/i18n";
import LivePhotoIcon from "./LivePhotoIcon.vue";
const props = defineProps<{ base: string; media: any }>();
const root = ref<HTMLElement>(),
  url = ref(""),
  failed = ref(false),
  loaded = ref(false);
let observer: IntersectionObserver;
onMounted(() => {
  observer = new IntersectionObserver(
    async (entries) => {
      if (!entries[0].isIntersecting) return;
      observer.disconnect();
      try {
        url.value = (
          await api(
            `${props.base}/media/${props.media.id}/url?purpose=thumbnail`,
          )
        ).url;
      } catch {
        failed.value = true;
      }
    },
    { rootMargin: "100px" },
  );
  if (root.value) observer.observe(root.value);
});
onBeforeUnmount(() => observer?.disconnect());
</script>
<template>
  <div ref="root" class="shared-thumb">
    <img
      v-if="url && !failed"
      :src="url"
      class="preview-image"
      :class="{ 'is-loaded': loaded }"
      @load="loaded = true"
      :alt="media.title || t('影像预览')"
      loading="lazy"
      referrerpolicy="no-referrer"
      @error="failed = true"
    />
    <div
      v-if="!loaded || failed"
      class="thumb-placeholder"
      :class="{ skeleton: !failed }"
    >
      <ImageOff v-if="failed" :size="24" />
    </div>
    <Play v-if="media.media_type === 'video'" class="type-icon" :size="22" />
    <span
      v-else-if="media.media_type === 'live_photo'"
      class="type-icon shared-live-badge"
      role="img"
      :aria-label="t('实况照片')"
    ><LivePhotoIcon width="14" height="14" /> LIVE</span>
  </div>
</template>
<style scoped>
.shared-thumb {
  aspect-ratio: 4/3;
  position: relative;
  overflow: hidden;
  border-radius: 10px;
  background: var(--sage-light);
}
.shared-thumb img {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  object-fit: contain;
  display: block;
}
.thumb-placeholder {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  color: var(--muted);
}
.type-icon {
  position: absolute;
  bottom: 10px;
  right: 10px;
  color: white;
  filter: drop-shadow(0 1px 3px #0008);
}
.shared-live-badge {
  right: auto;
  left: 7px;
  bottom: 7px;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  padding: 4px 7px;
  border-radius: 999px;
  color: #25332b;
  background: #fffdeef0;
  backdrop-filter: blur(8px);
  filter: none;
  font-size: 10px;
  line-height: 1;
  font-weight: 600;
  pointer-events: none;
}
</style>
