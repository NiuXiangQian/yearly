<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from "vue";
import { Check, Play, ImageOff, MapPin, Layers } from "lucide-vue-next";
import { api, localDate } from "../lib/api";
const props = defineProps<{
  media: any;
  selected?: boolean;
  selection?: boolean;
}>();
const emit = defineEmits(["open", "select", "longpress"]);
const root = ref<HTMLElement>(),
  url = ref(""),
  failed = ref(false),
  loaded = ref(false);
let observer: IntersectionObserver,
  timer: ReturnType<typeof setTimeout> | undefined,
  long = false,
  touchStart = { x: 0, y: 0 };
const preview =
  props.media.files.find((f: any) => f.file_role === "preview") ||
  props.media.files.find((f: any) => f.file_role === "original");
const video =
  preview?.mime_type?.startsWith("video/") ||
  /\.(mp4|mov)$/i.test(preview?.original_filename || "");
onMounted(() => {
  observer = new IntersectionObserver(
    async (entries) => {
      if (!entries[0].isIntersecting) return;
      observer.disconnect();
      if (!preview) return;
      try {
        url.value = (
          await api(`/media/${props.media.id}/files/${preview.id}/url`)
        ).url;
      } catch {
        failed.value = true;
      }
    },
    { rootMargin: "250px" },
  );
  if (root.value) observer.observe(root.value);
});
onBeforeUnmount(() => {
  observer?.disconnect();
  clearTimeout(timer);
});
function press(e: PointerEvent) {
  if (e.pointerType === "touch") {
    long = false;
    touchStart = { x: e.clientX, y: e.clientY };
    timer = setTimeout(() => {
      long = true;
      emit("longpress", props.media);
    }, 550);
  }
}
function cancel() {
  clearTimeout(timer);
}
function move(e: PointerEvent) {
  if (Math.hypot(e.clientX - touchStart.x, e.clientY - touchStart.y) > 10)
    cancel();
}
function click(e: MouseEvent) {
  if (long) {
    long = false;
    return;
  }
  props.selection
    ? emit("select", props.media, e.shiftKey)
    : emit("open", props.media);
}
</script>
<template>
  <article
    ref="root"
    class="media-card"
    :class="{ chosen: selected }"
    :data-media-id="media.id"
    @click="click"
    @pointerdown="press"
    @pointerup="cancel"
    @pointercancel="cancel"
    @pointermove="move"
    @contextmenu.prevent
  >
    <div
      class="media-visual"
      :style="{
        aspectRatio:
          media.width && media.height
            ? `${media.width}/${Math.min(media.height, media.width * 1.5)}`
            : '4/3',
      }"
    >
      <div v-if="!loaded && !failed" class="skeleton"></div>
      <video
        v-if="url && video && !failed"
        :src="url + '#t=0.1'"
        preload="metadata"
        muted
        playsinline
        @loadeddata="loaded = true"
        @error="failed = true"
      /><img
        v-else-if="url && !failed"
        :src="url"
        loading="lazy"
        :alt="media.title || '家庭影像'"
        @load="loaded = true"
        @error="failed = true"
      />
      <div v-if="failed || !preview" class="preview-unavailable">
        <ImageOff :size="28" /><small>原件已珍藏</small
        ><span>点击查看与下载</span>
      </div>
      <span
        v-if="selection || selected"
        class="media-check"
        :class="{ checked: selected }"
        ><Check v-if="selected" :size="15" /></span
      ><span v-if="media.media_type === 'video'" class="media-kind"
        ><Play :size="12" fill="currentColor" />
        {{
          media.duration_ms
            ? Math.floor(media.duration_ms / 60000) +
              ":" +
              String(Math.floor(media.duration_ms / 1000) % 60).padStart(2, "0")
            : "视频"
        }}</span
      ><span v-if="media.media_type === 'live_photo'" class="media-kind"
        ><Layers :size="12" /> LIVE</span
      >
    </div>
    <div class="media-caption">
      <div class="media-caption-title">
        {{ media.title || localDate(media.taken_at_local) }}
      </div>
      <div v-if="media.location_name" class="media-location">
        <MapPin :size="11" />{{ media.location_name }}
      </div>
      <div class="age-labels">
        <span
          v-for="c in media.children"
          :key="c.id"
          :style="{ '--child-color': c.theme_color }"
          >{{ c.nickname || c.name
          }}<template v-if="c.age"> · {{ c.age }}</template></span
        ><span v-if="!media.children.length" class="yearly-tag">家庭时光</span>
      </div>
    </div>
  </article>
</template>
