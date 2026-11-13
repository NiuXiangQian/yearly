<script setup lang="ts">
import { t } from "../lib/i18n";
import { ref, nextTick, onMounted, onBeforeUnmount } from "vue";
import {
  Play,
  Pause,
  Volume2,
  VolumeX,
  Maximize,
  RotateCcw,
} from "lucide-vue-next";
const props = defineProps<{
  loadSource: () => Promise<string>;
  poster?: string;
  autoplay?: boolean;
  initialSeconds?: number;
}>();
const root = ref<HTMLElement>(),
  video = ref<HTMLVideoElement>();
const source = ref(""),
  playing = ref(false),
  loading = ref(false),
  error = ref("");
const current = ref(0),
  duration = ref(0),
  volume = ref(1),
  muted = ref(false),
  speed = ref(1);
const expanded = ref(false);
function fullscreenChanged() {
  expanded.value = !!document.fullscreenElement;
}
onMounted(() => {
  document.addEventListener("fullscreenchange", fullscreenChanged);
  if (props.autoplay) void toggle();
});
onBeforeUnmount(() =>
  document.removeEventListener("fullscreenchange", fullscreenChanged),
);
const stamp = (seconds: number) =>
  `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, "0")}`;
async function toggle() {
  if (playing.value) {
    video.value?.pause();
    return;
  }
  loading.value = true;
  error.value = "";
  try {
    if (!source.value) {
      source.value = await props.loadSource();
      await nextTick();
    }
    await video.value?.play();
  } catch (e) {
    error.value = e instanceof Error ? e.message : t("暂时无法播放，请重试");
  } finally {
    loading.value = false;
  }
}
function seek(value: number) {
  if (video.value && duration.value)
    video.value.currentTime = Math.max(0, Math.min(duration.value, value));
}
function setVolume(value: number) {
  volume.value = value;
  if (video.value) {
    video.value.volume = value;
    video.value.muted = false;
  }
}
async function fullscreen() {
  if (expanded.value) {
    expanded.value = false;
    if (document.fullscreenElement) await document.exitFullscreen();
    return;
  }
  expanded.value = true;
  try {
    if (root.value?.requestFullscreen) await root.value.requestFullscreen();
    else (video.value as any)?.webkitEnterFullscreen?.();
  } catch {
    // Embedded browsers may refuse native fullscreen; keep the viewport-sized player.
  }
}
function keydown(e: KeyboardEvent) {
  if (e.key === "Escape" && expanded.value) {
    e.stopPropagation();
    void fullscreen();
    return;
  }
  if ((e.target as HTMLElement).closest("button,input,select")) return;
  if ([" ", "ArrowLeft", "ArrowRight", "f", "m"].includes(e.key))
    e.preventDefault();
  if (e.key === " ") void toggle();
  if (e.key === "ArrowLeft") seek(current.value - 5);
  if (e.key === "ArrowRight") seek(current.value + 5);
  if (e.key === "f") void fullscreen();
  if (e.key === "m" && video.value) video.value.muted = !video.value.muted;
}
</script>

<template>
  <div
    ref="root"
    class="yearly-player"
    :class="{ expanded }"
    tabindex="0"
    :aria-label="t('视频播放器，空格播放，左右键跳转五秒')"
    @keydown="keydown"
  >
    <video
      ref="video"
      :src="source || undefined"
      :poster="poster"
      preload="none"
      playsinline
      :muted="muted"
      @click="toggle"
      @play="playing = true"
      @pause="playing = false"
      @ended="playing = false"
      @timeupdate="current = video?.currentTime || 0"
      @loadedmetadata="
        duration = Number.isFinite(video?.duration) ? video!.duration : 0;
        if (initialSeconds != null) seek(initialSeconds)
      "
      @volumechange="muted = !!video?.muted || video?.volume === 0"
      @waiting="loading = true"
      @playing="loading = false"
      @error="
        error = t('播放失败，可重试或下载原文件');
        loading = false;
        playing = false;
      "
    />
    <button
      v-if="!playing && !error"
      class="player-big-play"
      :disabled="loading"
      :aria-label="loading ? t('正在加载视频') : t('播放视频')"
      @click="toggle"
    >
      <Play :size="32" fill="currentColor" /><span>{{
        loading ? t("加载中…") : t("播放")
      }}</span>
    </button>
    <div v-if="error" class="player-error">
      <p>{{ error }}</p>
      <button
        @click="
          source = '';
          toggle();
        "
      >
        <RotateCcw :size="16" /> {{ t("重新加载") }}
      </button>
    </div>
    <div v-if="loading && playing" class="player-buffering">
      {{ t("正在缓冲…") }}
    </div>
    <div class="player-controls">
      <input
        class="player-seek"
        type="range"
        :aria-label="t('播放进度')"
        min="0"
        :max="duration || 1"
        step="0.1"
        :value="current"
        :disabled="!duration"
        @input="seek(Number(($event.target as HTMLInputElement).value))"
      />
      <div class="player-control-row">
        <button
          :aria-label="playing ? t('暂停') : t('播放')"
          :disabled="loading && !playing"
          @click="toggle"
        >
          <Pause v-if="playing" :size="20" /><Play v-else :size="20" />
        </button>
        <span class="player-time"
          >{{ stamp(current) }} <span>/ {{ stamp(duration) }}</span></span
        >
        <span class="player-spacer"></span>
        <button
          :aria-label="muted ? t('取消静音') : t('静音')"
          @click="video && (video.muted = !video.muted)"
        >
          <VolumeX v-if="muted" :size="18" /><Volume2 v-else :size="18" />
        </button>
        <input
          class="player-volume"
          type="range"
          :aria-label="t('音量')"
          min="0"
          max="1"
          step="0.05"
          :value="muted ? 0 : volume"
          @input="setVolume(Number(($event.target as HTMLInputElement).value))"
        />
        <select
          v-model.number="speed"
          :aria-label="t('播放速度')"
          @change="video && (video.playbackRate = speed)"
        >
          <option v-for="rate in [0.5, 0.75, 1, 1.25, 1.5, 2]" :value="rate">
            {{ rate }}×
          </option>
        </select>
        <button
          :aria-label="expanded ? t('退出全屏') : t('全屏')"
          @click="fullscreen"
        >
          <Maximize :size="19" />
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.yearly-player {
  width: 100%;
  height: 100%;
  min-height: 280px;
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #101714;
  color: #fff;
  outline-offset: -3px;
}
.yearly-player video {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.yearly-player:fullscreen {
  height: 100vh;
}
.yearly-player.expanded {
  position: fixed;
  inset: 0;
  width: 100vw;
  height: 100dvh;
  z-index: 4000;
}
.player-big-play {
  position: absolute;
  left: 50%;
  top: 45%;
  transform: translate(-50%, -50%);
  display: grid;
  gap: 7px;
  place-items: center;
  width: 92px;
  height: 92px;
  border: 1px solid #ffffff50;
  border-radius: 50%;
  color: white;
  background: #243e3299;
  backdrop-filter: blur(12px);
  cursor: pointer;
}
.player-big-play span {
  font-size: 11px;
}
.player-controls {
  position: absolute;
  bottom: 0;
  left: 0;
  right: 0;
  background: linear-gradient(transparent, #080e0aeb);
  padding: 30px 18px 14px;
}
.player-control-row {
  display: flex;
  align-items: center;
  gap: 10px;
}
.player-controls button,
.player-error button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  background: none;
  color: white;
  border: 0;
  border-radius: 8px;
  min-width: 32px;
  min-height: 34px;
  cursor: pointer;
}
.player-controls button:hover {
  background: #ffffff25;
}
.player-controls input {
  accent-color: #b6d7be;
  padding: 0;
  border: 0;
  height: 20px;
  background: transparent;
  cursor: pointer;
}
.player-seek {
  width: 100%;
  margin: 0 0 5px;
}
.player-volume {
  width: 58px;
}
.player-time {
  font-size: 11px;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.player-time span {
  color: #b2bcb6;
}
.player-spacer {
  flex: 1;
}
.player-controls select {
  width: auto;
  padding: 5px 30px 5px 8px;
  border: 0;
  background-color: #24352d;
  border-radius: 7px;
  color: white;
  font-size: 12px;
}
.player-error {
  position: absolute;
  text-align: center;
  padding: 20px;
  background: #101714d9;
  font-size: 13px;
}
.player-error button {
  gap: 7px;
  border: 1px solid #ffffff50;
  padding: 5px 12px;
}
.player-buffering {
  position: absolute;
  font-size: 13px;
}
@media (max-width: 480px) {
  .player-volume {
    display: none;
  }
  .player-control-row {
    gap: 5px;
  }
}
</style>
