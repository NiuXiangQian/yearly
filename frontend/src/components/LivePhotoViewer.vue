<script setup lang="ts">
// Layered playback and press-to-play adapted from WebLivePhoto (MIT).
// See frontend/THIRD_PARTY_NOTICES.md for attribution and pinned source blobs.
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { CircleDot, LoaderCircle, RotateCcw, Volume2, VolumeX } from "lucide-vue-next";
import { t } from "../lib/i18n";
import type { MediaResource } from "../lib/media-resource";
const props = defineProps<{
  src: string;
  alt?: string;
  loadMotion: (refresh?: boolean) => Promise<MediaResource>;
}>();
const emit = defineEmits(["error"]);
const video = ref<HTMLVideoElement>();
const motion = ref("");
const playing = ref(false), loading = ref(false), muted = ref(false);
const pending = ref(false), error = ref("");
const gestureRequired = ref(false);
const label = computed(() => error.value ? t("重试实况") : pending.value
  ? t("动态预览正在准备") : loading.value ? t("正在加载实况…")
  : playing.value ? t("重新播放实况") : t("播放实况"));
let suppressClick = false;
let disposed = false, wanted = false, revealed = false, epoch = 0;
let ready: Promise<void> | undefined;
let pressTimer: ReturnType<typeof setTimeout> | undefined;
let pollTimer: ReturnType<typeof setTimeout> | undefined;
let timeout: ReturnType<typeof setTimeout> | undefined;
let pointer: { id: number; x: number; y: number } | undefined;

async function prepare(refresh = false) {
  if (ready) return ready;
  ready = (async () => {
    try {
      const value = await props.loadMotion(refresh);
      if (disposed) return;
      pending.value = value.status === "pending" || value.status === "processing";
      if (pending.value) {
        clearTimeout(pollTimer);
        pollTimer = setTimeout(() => void prepare(true), 15_000);
        return;
      }
      if (!value.url || value.status === "failed") throw new Error("preview unavailable");
      clearTimeout(pollTimer);
      motion.value = value.url;
      // Keep the URL off the video until interaction: Safari may ignore preload=none.
    } catch {
      if (!disposed) fail();
    }
  })();
  await ready;
  ready = undefined;
}
function stop() {
  wanted = false;
  revealed = false;
  epoch++;
  clearTimeout(pressTimer);
  clearTimeout(timeout);
  playing.value = false;
  loading.value = false;
  video.value?.pause();
}
function fail(reason?: unknown) {
  if (disposed) return;
  stop();
  gestureRequired.value = (reason as { name?: string })?.name === "NotAllowedError";
  error.value = gestureRequired.value
    ? t("轻点 LIVE 播放有声实况")
    : t("动态暂时无法播放，照片仍可查看");
}
function showPlaying() {
  if (!wanted) { video.value?.pause(); return; }
  loading.value = false;
  clearTimeout(timeout);
  if (revealed) {
    if (video.value) video.value.muted = muted.value;
    playing.value = true;
  }
}
function buffer() {
  if (!wanted) return;
  loading.value = true;
  clearTimeout(timeout);
  timeout = setTimeout(fail, 20_000);
}
function playReady(ticket: number) {
  if (disposed || !wanted || ticket !== epoch) return;
  if (!motion.value || !video.value) { stop(); return; }
  buffer();
  try {
    if (video.value.getAttribute("src") !== motion.value || video.value.error)
      video.value.src = motion.value;
    video.value.muted = muted.value;
    video.value.currentTime = 0;
    const result = video.value.play();
    result?.catch((reason) => {
      if (!disposed && wanted && ticket === epoch) fail(reason);
    });
  } catch (reason) { fail(reason); }
}
function start(reveal = true, refresh = false) {
  stop();
  error.value = "";
  gestureRequired.value = false;
  wanted = true;
  revealed = reveal;
  const ticket = epoch;
  // When the signed URL is ready, play synchronously during pointerdown/click.
  if (motion.value && !refresh) playReady(ticket);
  else {
    buffer();
    void prepare(refresh).then(() => playReady(ticket));
  }
}
function replay() { start(true, !!error.value && !gestureRequired.value); }
function clickPhoto() {
  if (suppressClick) { suppressClick = false; return; }
  replay();
}
function down(event: PointerEvent) {
  if (event.pointerType === "mouse" || event.button !== 0) return;
  if (pointer || !event.isPrimary) { suppressClick = true; pointer = undefined; stop(); return; }
  suppressClick = false;
  pointer = { id: event.pointerId, x: event.clientX, y: event.clientY };
  start(false); // Authorize sound in the iOS gesture; reveal motion once the hold is confirmed.
  pressTimer = setTimeout(() => {
    if (!wanted) return;
    suppressClick = true;
    revealed = true;
    if (video.value && !video.value.paused && video.value.readyState >= 2) showPlaying();
  }, 180);
}
function move(event: PointerEvent) {
  if (pointer?.id !== event.pointerId) return;
  if (Math.hypot(pointer.x - event.clientX, pointer.y - event.clientY) > 10) { suppressClick = true; release(); }
}
function release() { pointer = undefined; stop(); }
function leave(event: PointerEvent) {
  if (event.pointerType === "mouse" || pointer) release();
}
function visibility() { if (document.hidden) release(); }
onMounted(() => {
  void prepare(); // Resolve only the preview URL. Video bytes wait for interaction.
  document.addEventListener("visibilitychange", visibility);
  window.addEventListener("blur", release);
  window.addEventListener("pointerup", releasePointer);
  window.addEventListener("pointercancel", releasePointer);
});
function releasePointer() { if (pointer) release(); }
onBeforeUnmount(() => {
  disposed = true;
  stop();
  clearTimeout(pollTimer);
  document.removeEventListener("visibilitychange", visibility);
  window.removeEventListener("blur", release);
  window.removeEventListener("pointerup", releasePointer);
  window.removeEventListener("pointercancel", releasePointer);
  video.value?.removeAttribute("src");
  video.value?.load();
});
</script>

<template>
  <div class="live-photo-viewer">
    <div class="live-photo" :class="{ 'is-playing': playing }"
      @pointerenter="$event.pointerType === 'mouse' && !error && start()"
      @pointerleave="leave" @pointerdown="down" @pointermove="move"
      @pointerup="releasePointer" @pointercancel="suppressClick = true; release()" @click="clickPhoto" @contextmenu.prevent>
      <video ref="video" class="live-photo-video" :muted="muted" playsinline
        webkit-playsinline preload="none" aria-hidden="true"
        @playing="showPlaying" @waiting="buffer" @ended="stop" @error="fail" />
      <img class="live-photo-img" :src="src" :alt="alt || t('实况照片')" draggable="false" @error="emit('error')" />
    </div>
    <div class="live-photo-actions">
      <button class="live-photo-badge" :aria-label="label" :aria-pressed="playing"
        :aria-busy="loading" @click="replay">
        <LoaderCircle v-if="loading || pending" class="live-spinner" :size="18" />
        <RotateCcw v-else-if="error" :size="18" />
        <CircleDot v-else :size="18" />
        <span>LIVE</span><small>{{ label }}</small>
      </button>
      <button class="live-photo-sound" :aria-label="muted ? t('取消静音') : t('静音')"
        :aria-pressed="!muted" @click="muted = !muted; video && (video.muted = muted)">
        <VolumeX v-if="muted" :size="18" /><Volume2 v-else :size="18" />
      </button>
    </div>
    <p class="live-photo-hint" role="status">
      {{ error || (pending ? t('动态预览正在准备，完成后可播放') : t('点击照片或 LIVE 播放 · 每次点击从头播放')) }}
    </p>
  </div>
</template>

<style scoped>
.live-photo-viewer { width: 100%; height: 100%; position: relative; }
.live-photo { position: absolute; inset: 0 0 42px; overflow: hidden; cursor: pointer; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; touch-action: pan-y pinch-zoom; }
.live-photo-img, .live-photo-video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain; pointer-events: none; }
.live-photo-img { opacity: 1; transition: opacity .3s ease; }
.live-photo.is-playing .live-photo-img { opacity: 0; }
.live-photo-actions { position: absolute; inset: 16px 16px auto; display: flex; align-items: start; justify-content: space-between; gap: 10px; pointer-events: none; }
.live-photo-actions button { pointer-events: auto; min-height: 44px; border: 1px solid #ffffff30; border-radius: 24px; color: #fff; background: #15221cc9; backdrop-filter: blur(12px); display: inline-flex; align-items: center; justify-content: center; gap: 8px; padding: 10px 14px; cursor: pointer; }
.live-photo-actions button:focus-visible { outline: 2px solid #d6edb9; outline-offset: 3px; }
.live-photo-badge span { font-size: 12px; letter-spacing: 1px; font-weight: 600; }
.live-photo-badge small { font-size: 11px; color: #d5e2d9; }
.live-photo-badge[aria-pressed="true"] { color: #e3f3a9; border-color: #d5e9ac88; }
.live-photo-sound { width: 44px; padding: 0 !important; }
.live-photo-hint { position: absolute; inset: auto 16px 12px; margin: 0; text-align: center; font-size: 11px; color: #baccc0; pointer-events: none; }
.live-spinner { animation: live-spin 1.5s linear infinite; }
@keyframes live-spin { to { transform: rotate(360deg); } }

@media (prefers-reduced-motion: reduce) { .live-photo-img { transition: none; } .live-spinner { animation: none; } }
</style>
