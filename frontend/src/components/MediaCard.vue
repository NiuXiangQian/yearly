<script setup lang="ts">
import { t } from "../lib/i18n";
import { ref, onMounted, onBeforeUnmount } from "vue";
import { Check, Play, ImageOff, Layers, LockKeyhole } from "lucide-vue-next";
import { mediaResource, releaseMediaResource } from "../lib/media-resource";
const props = defineProps<{
  media: any;
  selected?: boolean;
  selection?: boolean;
  thumbnail?: boolean;
}>();
const emit = defineEmits(["open", "select", "longpress"]);
const root = ref<HTMLElement>(),
  url = ref(""),
  failed = ref(false),
  loaded = ref(false);
let disposed = false;
let observer: IntersectionObserver,
  timer: ReturnType<typeof setTimeout> | undefined,
  long = false,
  touchStart = { x: 0, y: 0 };
const preview =
  props.media.files.find((f: any) => f.file_role === "preview") ||
  props.media.files.find((f: any) => f.file_role === "original");
onMounted(() => {
  observer = new IntersectionObserver(
    async (entries) => {
      if (!entries[0].isIntersecting) return;
      observer.disconnect();
      if (!preview) return;
      try {
        const resource = await mediaResource(props.media.id, preview.id, "thumbnail");
        if (disposed) releaseMediaResource(resource.url);
        else url.value = resource.url || "";
      } catch {
        failed.value = true;
      }
    },
    { rootMargin: "250px" },
  );
  if (root.value) observer.observe(root.value);
});
onBeforeUnmount(() => {
  disposed = true;
  observer?.disconnect();
  releaseMediaResource(url.value);
  clearTimeout(timer);
});
function press(e: PointerEvent) {
  if (props.media.can_edit === false) return;
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
  props.selection && props.media.can_edit !== false
    ? emit("select", props.media, e.shiftKey)
    : emit("open", props.media);
}
</script>
<template>
  <article
    ref="root"
    class="media-card"
    :class="{
      chosen: selected,
      'media-thumbnail': thumbnail,
      'has-title': !thumbnail && media.title?.trim(),
    }"
    :data-media-id="media.id"
    @click="click"
    @pointerdown="press"
    @pointerup="cancel"
    @pointercancel="cancel"
    @pointermove="move"
    @contextmenu.prevent
  >
    <div class="media-visual">
      <span v-if="media.can_edit === false" class="content-lock" :title="t('已锁定，只能编辑自己添加的内容。')"><LockKeyhole :size="13" />{{ t("已锁定") }}</span>
      <div v-if="!loaded && !failed" class="skeleton"></div>
      <img
        :draggable="false"
        v-if="url && !failed"
        :src="url"
        class="preview-image"
        :class="{ 'is-loaded': loaded }"
        loading="lazy"
        :alt="media.title || t('家庭影像')"
        @load="loaded = true"
        @error="failed = true"
      />
      <div v-if="failed || !preview" class="preview-unavailable">
        <ImageOff :size="28" /><small> {{ t("原件已珍藏") }} </small
        ><span> {{ t("点击查看与下载") }} </span>
      </div>
      <span
        v-if="(selection || selected) && media.can_edit !== false"
        class="media-check"
        :class="{ checked: selected }"
        ><Check v-if="selected" :size="15" /></span
      ><span v-if="media.media_type === 'video'" class="media-kind"
        ><Play :size="12" fill="currentColor" />
        {{
          thumbnail
            ? ""
            : media.duration_ms
              ? Math.floor(media.duration_ms / 60000) +
                ":" +
                String(Math.floor(media.duration_ms / 1000) % 60).padStart(
                  2,
                  "0",
                )
              : t("视频")
        }}</span
      ><span v-if="media.media_type === 'live_photo'" class="media-kind"
        ><Layers :size="12" /> {{ thumbnail ? "" : "LIVE" }}</span
      >
    </div>
    <div v-if="!thumbnail && media.title?.trim()" class="media-title-overlay">
      <span :title="media.title">{{ media.title }}</span>
    </div>
  </article>
</template>

<style scoped>
.media-title-overlay {
  position: absolute;
  inset: auto 0 0;
  padding: 28px 11px 10px;
  background: linear-gradient(transparent, rgb(0 0 0 / 65%));
  color: #fff;
  pointer-events: none;
}
.media-title-overlay span {
  display: block;
  font-size: 12px;
  font-weight: 500;
  line-height: 1.5;
  letter-spacing: 0.02em;
  text-shadow: 0 1px 3px rgb(0 0 0 / 30%);
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  pointer-events: auto;
}
.has-title .media-kind {
  top: 8px;
  bottom: auto;
}
.media-thumbnail .media-visual {
  aspect-ratio: 1;
}
.media-thumbnail .preview-unavailable {
  padding: 4px;
}
.media-thumbnail .preview-unavailable small,
.media-thumbnail .preview-unavailable span {
  display: none;
}
.media-thumbnail .media-kind {
  bottom: 3px;
  left: 3px;
  padding: 2px;
  font-size: 8px;
}
</style>
