<script setup lang="ts">
import { t } from "../lib/i18n";
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { ImageOff, Layers, Image, FileImage, Maximize, Minimize } from "lucide-vue-next";
import { bytes, post } from "../lib/api";
import { mediaResource, releaseMediaResource, type MediaResource } from "../lib/media-resource";
import LivePhotoViewer from "./LivePhotoViewer.vue";
import ImageViewer from "./ImageViewer.vue";
import VideoPlayer from "./VideoPlayer.vue";
const props = defineProps<{ media: any }>();
const original = ref(false),
  live = ref(false),
  failed = ref(false),
  loading = ref(false);
const resource = ref<MediaResource>(),
  poster = ref(""),
  error = ref("");
const resourceRevision = ref(0);
const primary = computed(() =>
  props.media.files.find((f: any) => f.file_role === "original"),
);
const liveFile = computed(() =>
  props.media.files.find((f: any) => f.file_role === "live_video"),
);
const isVideo = computed(
  () => props.media.media_type === "video" || (live.value && original.value),
);
const originalFile = computed(() =>
  live.value ? liveFile.value : primary.value,
);
const file = computed(() => {
  if (original.value) return originalFile.value;
  return (
    props.media.files.find(
      (f: any) =>
        f.file_role === "preview" &&
        f.mime_type.startsWith(isVideo.value ? "video/" : "image/"),
    ) || primary.value
  );
});
watch(
  () => props.media.id,
  () => {
    original.value = false;
    live.value = !!liveFile.value;
  },
  { immediate: true },
);
watch(
  () => [props.media.id, file.value?.id, original.value, resourceRevision.value] as const,
  async (_, __, onCleanup) => {
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    onCleanup(() => {
      active = false;
      releaseMediaResource(resource.value?.url);
      releaseMediaResource(poster.value);
      clearTimeout(timer);
    });
    resource.value = undefined;
    poster.value = "";
    failed.value = false;
    error.value = "";
    loading.value = false;
    if (!file.value) return;
    const mid = props.media.id,
      fid = file.value.id,
      purpose = original.value ? "original" : "preview";
    loading.value = true;
    if (isVideo.value)
      mediaResource(mid, fid, "thumbnail")
        .then((value) => {
          if (active) poster.value = value.url || "";
          else releaseMediaResource(value.url);
        })
        .catch(() => {});
    async function refresh() {
      try {
        const value = await mediaResource(mid, fid, purpose);
        if (!active) return;
        resource.value = value;
        if (["pending", "processing"].includes(value.status))
          timer = setTimeout(refresh, 15_000);
        if (value.status === "restoring")
          timer = setTimeout(refresh, 60_000);
      } catch (e) {
        if (active) {
          failed.value = true;
          error.value = e instanceof Error ? e.message : t("预览加载失败");
        }
      } finally {
        if (active) loading.value = false;
      }
    }
    await refresh();
  },
  { immediate: true },
);
async function restoreOriginal() {
  loading.value = true;
  try {
    await post(`/media/${props.media.id}/files/${file.value.id}/restore`);
    resourceRevision.value++;
  } catch (e) {
    error.value = e instanceof Error ? e.message : t("解冻申请失败，请重试");
  } finally {
    loading.value = false;
  }
}
async function playbackSource() {
  const value = await mediaResource(
    props.media.id,
    file.value.id,
    original.value ? "original" : "preview",
  );
  if (!value.url) throw new Error(t("压缩预览仍在准备，请稍后再试"));
  return value.url;
}
const expanded = ref(false);
let previousOverflow = "";
watch(expanded, (value) => {
  if (value) {
    previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
  } else document.body.style.overflow = previousOverflow;
});
function escape(event: KeyboardEvent) {
  if (event.key === "Escape" && expanded.value) {
    event.stopImmediatePropagation();
    expanded.value = false;
  }
}
onMounted(() => window.addEventListener("keydown", escape, true));
onBeforeUnmount(() => {
  window.removeEventListener("keydown", escape, true);
  if (expanded.value) document.body.style.overflow = previousOverflow;
});
function motionSource(refresh = false) {
  return mediaResource(props.media.id, liveFile.value.id, "preview", refresh);
}
</script>

<template>
  <Teleport to="body" :disabled="!expanded">
  <div class="media-viewer-shell" :class="{ expanded }">
    <header class="viewer-toolbar">
      <span class="viewer-quality"
        >{{
          original
            ? t("原文件")
            : isVideo
              ? t("流畅预览 · 720p")
              : live && liveFile
                ? t("实况照片 · 高清预览")
                : t("高清压缩预览")
        }}<small v-if="resource?.file_size">{{
          bytes(resource.file_size)
        }}</small></span
      >
      <div class="viewer-actions">
      <button
        v-if="originalFile"
        :disabled="loading"
        @click="original = !original"
      >
        <FileImage :size="14" />{{
          original
            ? t("返回压缩预览")
            : t(live && liveFile ? "查看动态原件 · {p0}" : "查看原文件 · {p0}", { p0: bytes(originalFile.file_size) })
        }}
      </button>
      <button :aria-label="expanded ? t('退出全屏') : t('全屏预览')" :title="expanded ? t('退出全屏') : t('全屏预览')" @click="expanded = !expanded">
        <Minimize v-if="expanded" :size="17" /><Maximize v-else :size="17" />
      </button>
      </div>
    </header>
    <div class="viewer-stage">
      <LivePhotoViewer
        v-if="live && liveFile && !original && resource?.url && !failed"
        :key="media.id" :src="resource.url" :alt="media.title"
        :load-motion="motionSource" :autoplay="expanded" @error="failed = true"
      />
      <VideoPlayer
        v-else-if="isVideo && resource?.url && !failed"
        :key="`${file.id}-${original}`"
        :poster="poster"
        :autoplay="live"
        :load-source="playbackSource"
      />
      <ImageViewer
        v-else-if="!isVideo && resource?.url && !failed"
        :src="resource.url"
        :original-file="original ? file : undefined"
        :alt="media.title"
        @error="failed = true"
      />
      <div v-else class="viewer-status">
        <img v-if="poster" :src="poster" :alt="t('视频封面')" />
        <div>
          <ImageOff v-if="failed || resource?.status === 'failed'" :size="36" />
          <h3>
            {{
              loading
                ? t("正在加载预览…")
                : resource?.status === "archived"
                  ? t("原件已深度归档")
                : resource?.status === "restoring"
                  ? t("原件正在解冻")
                : resource?.status === "pending" ||
                    resource?.status === "processing"
                  ? t("视频预览正在准备")
                  : t("暂时无法预览")
            }}
          </h3>
          <p>
            {{
              error ||
              resource?.message ||
              (resource?.status === "pending" ||
              resource?.status === "processing"
                ? t("完成后自动更新。原文件已安全保存。")
                : t("可以点击上方查看原文件，或下载后打开。"))
            }}
          </p>
          <button v-if="resource?.status === 'archived'" type="button" :disabled="loading" @click="restoreOriginal">
            {{ t("申请解冻原件 · 通常48小时") }}
          </button>
          <button v-if="resource?.status === 'restoring'" type="button" :disabled="loading" @click="resourceRevision++">
            {{ t("刷新解冻状态") }}
          </button>
        </div>
      </div>
    </div>
    <footer v-if="liveFile" class="viewer-live-tabs">
      <button
        :class="{ active: !live }"
        :aria-pressed="!live"
        @click="
          live = false;
          original = false;
        "
      >
        <Image :size="15" /> {{ t("静态照片") }}</button
      ><button
        :class="{ active: live }"
        :aria-pressed="live"
        @click="
          live = true;
          original = false;
        "
      >
        <Layers :size="15" /> {{ t("实况照片") }}
      </button>
    </footer>
  </div>
  </Teleport>
</template>

<style scoped>
.media-viewer-shell {
  width: 100%;
  height: 100%;
  display: flex;
  flex-direction: column;
  color: #f0f4f0;
  background: radial-gradient(ellipse at 50% 35%, #2d3b32, #111c17);
}
.media-viewer-shell.expanded {
  position: fixed;
  inset: 0;
  width: 100vw;
  height: 100dvh;
  z-index: 5000;
  padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
}
.viewer-actions { display: flex; gap: 8px; align-items: center; }
.viewer-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 16px;
  background: #15221ce6;
  border-bottom: 1px solid #ffffff12;
  z-index: 1;
}
.viewer-quality {
  display: flex;
  flex-direction: column;
  gap: 4px;
  font-size: 11px;
  color: #d7e5db;
}
.viewer-quality small {
  font-size: 10px;
  color: #93a99b;
}
.viewer-toolbar button {
  display: flex;
  align-items: center;
  gap: 6px;
  border: 1px solid #ffffff30;
  border-radius: 20px;
  padding: 8px 10px;
  min-height: 40px;
  background: #ffffff08;
  color: #e7eee8;
  font-size: 11px;
  cursor: pointer;
}
.viewer-toolbar button:hover {
  background: #ffffff20;
}
.viewer-stage {
  flex: 1;
  min-height: 0;
  overflow: hidden;
  position: relative;
}
.viewer-status {
  height: 100%;
  display: grid;
  place-items: center;
  position: relative;
  text-align: center;
  padding: 20px;
}
.viewer-status > img {
  position: absolute;
  width: 100%;
  height: 100%;
  object-fit: contain;
  opacity: 0.3;
}
.viewer-status > div {
  z-index: 1;
  background: #17251ce0;
  padding: 24px;
  border-radius: 16px;
}
.viewer-status h3 {
  font-size: 16px;
}
.viewer-status p {
  font-size: 12px;
  color: #c5d5c9;
  line-height: 1.8;
}
.viewer-status button {
  min-height: 44px;
  max-width: 100%;
  border: 1px solid #ffffff50;
  border-radius: 8px;
  padding: 10px 14px;
  background: #ffffff12;
  color: #e7eee8;
  font-size: 14px;
  white-space: normal;
}
.viewer-live-tabs {
  display: flex;
  justify-content: center;
  gap: 8px;
  padding: 10px;
  border-top: 1px solid #ffffff12;
}
.viewer-live-tabs button {
  display: flex;
  align-items: center;
  gap: 7px;
  background: none;
  color: #a5b7ab;
  border: 0;
  border-radius: 20px;
  padding: 8px 16px;
  font-size: 12px;
  cursor: pointer;
}
.viewer-live-tabs button.active {
  background: #ffffff18;
  color: white;
}
@media (max-width: 600px) {
  .viewer-toolbar { padding: 10px 12px; gap: 8px; }
  .viewer-quality { min-width: 0; }
  .viewer-actions { gap: 6px; }
  .viewer-toolbar button { font-size: 10px; }
  .viewer-live-tabs { padding: 6px; }
  .viewer-live-tabs button { min-height: 44px; }
}
</style>
