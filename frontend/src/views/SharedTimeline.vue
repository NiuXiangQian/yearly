<script setup lang="ts">
import {
  computed,
  ref,
  watch,
  nextTick,
  onMounted,
  onBeforeUnmount,
} from "vue";
import { useRoute } from "vue-router";
import { Leaf, Folder, ChevronDown, ShieldCheck } from "lucide-vue-next";
import { api, notify } from "../lib/api";
import { t, locale } from "../lib/i18n";
import LanguageSwitch from "../components/LanguageSwitch.vue";
import TimelineMonths from "../components/TimelineMonths.vue";
import TimelineOrder from "../components/TimelineOrder.vue";
import TimelineRail from "../components/TimelineRail.vue";
import SharedThumbnail from "../components/SharedThumbnail.vue";
import ImageViewer from "../components/ImageViewer.vue";
import VideoPlayer from "../components/VideoPlayer.vue";
const route = useRoute();
const base = `/public/shares/${encodeURIComponent(String(route.params.token))}`;
const timelineOrder = ref(
  localStorage.getItem("yearly-shared-order") === "asc" ? "asc" : "desc",
);
const share = ref<any>(null),
  days = ref<any[]>([]),
  nextDate = ref<string | null>(null);
const dateIndex = ref<string[]>([]);
const railDates = computed(() =>
  timelineOrder.value === "asc"
    ? dateIndex.value
    : [...dateIndex.value].reverse(),
);
const currentDate = ref("");
const monthList = ref<{ reveal(date: string): void }>();
const reading = ref<HTMLElement>();
const loading = ref(false),
  error = ref(""),
  folder = ref<any>(null),
  selected = ref<any>(null);
const expanded = ref<Record<string, boolean>>({}),
  busyDay = ref(""),
  folderBusy = ref(false);
const preview = ref(""),
  previewError = ref(""),
  live = ref(false),
  previewLoading = ref(false);
const video = computed(
  () => selected.value?.media_type === "video" || live.value,
);
let expiryTimer: ReturnType<typeof setTimeout>;
let previewGeneration = 0;
let loadGeneration = 0;
function expire() {
  error.value = t("分享已失效或不存在");
  share.value = null;
  days.value = [];
  dateIndex.value = [];
  loadGeneration++;
  folder.value = null;
  selected.value = null;
  preview.value = "";
  previewGeneration++;
}
async function load(more = false, anchor?: string) {
  if (more && loading.value) return;
  const generation = ++loadGeneration;
  const order = timelineOrder.value;
  loading.value = true;
  error.value = "";
  if (!more) {
    days.value = [];
    nextDate.value = null;
    expanded.value = {};
    folder.value = null;
  }
  try {
    const params = new URLSearchParams({ order });
    if (more && nextDate.value)
      params.set(order === "asc" ? "after" : "before", nextDate.value);
    if (anchor) params.set("anchor", anchor);
    const [data, index] = await Promise.all([
      api(`${base}?${params}`),
      more ? Promise.resolve(null) : api(`${base}/dates`),
    ]);
    if (generation !== loadGeneration) return;
    share.value = data.share;
    if (index) dateIndex.value = index.dates;
    if (!more) currentDate.value = data.days[0]?.day || "";
    days.value = more ? [...days.value, ...data.days] : data.days;
    nextDate.value = order === "asc" ? data.next_after : data.next_before;
    clearTimeout(expiryTimer);
    expiryTimer = setTimeout(
      expire,
      Math.max(0, new Date(data.share.expires_at).getTime() - Date.now()),
    );
  } catch (e) {
    if (generation === loadGeneration)
      error.value = e instanceof Error ? e.message : t("请求失败");
  } finally {
    if (generation === loadGeneration) loading.value = false;
  }
}
async function expand(day: any) {
  if (busyDay.value) return;
  expanded.value[day.day] = true;
  if (day.items.length >= day.total) return;
  busyDay.value = day.day;
  try {
    const data = await api(
      `${base}/days/${day.day}?offset=${day.items.length}&order=${timelineOrder.value}`,
    );
    day.items.push(...data.items);
    day.total = data.total;
  } catch (e) {
    notify(e);
  } finally {
    busyDay.value = "";
  }
}
async function openFolder(item: any, more = false) {
  if (folderBusy.value) return;
  folderBusy.value = true;
  try {
    const data = await api(
      `${base}/folders/${item.id}?offset=${more ? folder.value.items.length : 0}&order=${timelineOrder.value}`,
    );
    folder.value = more
      ? { ...data, items: [...folder.value.items, ...data.items] }
      : data;
  } catch (e) {
    notify(e);
  } finally {
    folderBusy.value = false;
  }
}
async function openMedia(item: any, playLive = false) {
  selected.value = item;
  live.value = playLive;
  preview.value = "";
  previewError.value = "";
  const generation = ++previewGeneration;
  if (item.kind === "event") return;
  previewLoading.value = true;
  try {
    const data = await api(
      `${base}/media/${item.id}/url?purpose=preview&live=${playLive}`,
    );
    if (generation !== previewGeneration) return;
    if (data.url) preview.value = data.url;
    else previewError.value = t("压缩预览仍在准备，请稍后再试");
  } catch (e) {
    if (generation === previewGeneration)
      previewError.value = e instanceof Error ? e.message : t("请求失败");
  } finally {
    if (generation === previewGeneration) previewLoading.value = false;
  }
}
async function videoSource() {
  const data = await api(
    `${base}/media/${selected.value.id}/url?purpose=preview&live=${live.value}`,
  );
  if (!data.url) throw new Error(t("压缩预览仍在准备，请稍后再试"));
  return data.url;
}
async function seekDate(date: string) {
  if (loading.value) return;
  if (!days.value.some((day) => day.day === date)) await load(false, date);
  if (error.value) return;
  const target =
    days.value.find((day) => day.day === date)?.day || days.value[0]?.day;
  if (!target) return;
  currentDate.value = target;
  monthList.value?.reveal(target);
  await nextTick();
  document
    .getElementById(`shared-day-${target}`)
    ?.scrollIntoView({ block: "start" });
}
let scrollFrame = 0;
function trackDate() {
  if (scrollFrame) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = 0;
    const sections =
      reading.value?.querySelectorAll<HTMLElement>(".shared-day");
    if (!sections?.length) return;
    let closest = sections[0];
    for (const section of sections) {
      if (section.getBoundingClientRect().top > 140) break;
      closest = section;
    }
    if (
      window.scrollY + window.innerHeight >=
      document.documentElement.scrollHeight - 2
    )
      closest = sections[sections.length - 1];
    currentDate.value = closest.dataset.day!;
  });
}
watch(timelineOrder, (value) => {
  localStorage.setItem("yearly-shared-order", value);
  load();
});
onMounted(() => {
  load();
  window.addEventListener("scroll", trackDate, { passive: true });
});
onBeforeUnmount(() => {
  clearTimeout(expiryTimer);
  cancelAnimationFrame(scrollFrame);
  window.removeEventListener("scroll", trackDate);
});
</script>
<template>
  <main class="shared-page">
    <header class="shared-nav">
      <span class="shared-brand"><Leaf :size="22" /> yearly</span
      ><LanguageSwitch />
    </header>
    <div v-if="error" class="shared-empty" role="alert">
      <ShieldCheck :size="40" />
      <h1>{{ error }}</h1>
      <p>{{ t("请联系分享者获取新的链接") }}</p>
    </div>
    <template v-else-if="share">
      <section class="shared-intro">
        <span class="eyebrow">{{ t("与你分享的时光") }}</span>
        <h1>{{ share.title || t("一起长大的日子") }}</h1>
        <p>{{ share.start_date }} — {{ share.end_date }}</p>
        <small
          ><ShieldCheck :size="13" />{{ t("只读分享") }} ·
          {{
            t("有效至 {p0}", {
              p0: new Date(share.expires_at).toLocaleString(locale),
            })
          }}</small
        >
      </section>
      <div class="shared-sort">
        <TimelineOrder
          v-model="timelineOrder"
          :disabled="!!busyDay || folderBusy"
        />
      </div>
      <div class="shared-reader" :class="{ 'has-rail': dateIndex.length }">
        <TimelineRail
          :dates="railDates"
          :current="currentDate"
          :disabled="loading || !!busyDay || folderBusy"
          @select="seekDate"
        />
        <div ref="reading" class="shared-reading">
          <p v-if="dateIndex.length" class="rail-hint">
            {{ t("拖动左侧时间轴，松开跳转到对应日期") }}
          </p>
          <TimelineMonths ref="monthList" :days="days" v-slot="{ day }">
            <section
              class="shared-day"
              :id="`shared-day-${day.day}`"
              :data-day="day.day"
            >
              <header>
                <h2>{{ day.day.replaceAll("-", ".") }}</h2>
                <span>{{ t("{p0} 项回忆", { p0: day.total }) }}</span>
              </header>
              <div class="shared-grid">
                <button
                  v-for="item in expanded[day.day]
                    ? day.items
                    : day.items.slice(0, 8)"
                  :key="item.kind + item.id"
                  class="shared-card"
                  @click="
                    item.kind === 'folder' ? openFolder(item) : openMedia(item)
                  "
                >
                  <template v-if="item.kind === 'folder'"
                    ><div class="shared-folder">
                      <b><Folder :size="20" />{{ item.name }}</b>
                      <div class="shared-folder-previews">
                        <SharedThumbnail
                          v-for="media in item.previews"
                          :key="media.id"
                          :base="base"
                          :media="media"
                        />
                      </div>
                      <small>{{
                        t("{p0} 份影像", { p0: item.media_count })
                      }}</small>
                    </div></template
                  >
                  <template v-else-if="item.kind === 'event'"
                    ><div class="shared-diary">
                      <small>{{ t("成长日记") }}</small>
                      <h3>{{ item.title }}</h3>
                      <p>{{ item.content }}</p>
                    </div></template
                  >
                  <template v-else
                    ><SharedThumbnail :base="base" :media="item" /><span
                      v-if="item.title"
                      class="shared-caption"
                      >{{ item.title }}</span
                    ></template
                  >
                </button>
              </div>
              <div v-if="day.total > 8" class="expand-actions">
                <button
                  v-if="!expanded[day.day] || day.items.length < day.total"
                  class="button"
                  :disabled="!!busyDay"
                  @click="expand(day)"
                >
                  <ChevronDown :size="15" />{{
                    t("展开更多（剩余 {p0} 项）", {
                      p0:
                        day.total - (expanded[day.day] ? day.items.length : 8),
                    })
                  }}</button
                ><button
                  v-if="expanded[day.day]"
                  class="text-button"
                  @click="expanded[day.day] = false"
                >
                  {{ t("收起") }}
                </button>
              </div>
            </section>
          </TimelineMonths>
          <div v-if="!days.length && !loading" class="shared-empty">
            {{ t("这个范围还没有可分享的回忆") }}
          </div>
          <footer class="shared-footer">
            <button
              v-if="nextDate"
              class="button"
              :disabled="loading"
              @click="load(true)"
            >
              {{
                loading
                  ? t("正在加载…")
                  : timelineOrder === "asc"
                    ? t("更晚的日子")
                    : t("更早的日子")
              }}</button
            ><span v-else>{{ t("— 这些日子，都在这里 —") }}</span>
          </footer>
        </div>
      </div>
    </template>
    <div v-else-if="loading" class="shared-empty">{{ t("正在加载…") }}</div>
    <ElDialog
      :model-value="!!folder"
      :title="folder?.name"
      width="850px"
      class="shared-folder-dialog"
      @close="folder = null"
      ><div v-if="folder" class="shared-grid">
        <button
          v-for="item in folder.items"
          :key="item.id"
          class="shared-card"
          @click="openMedia(item)"
        >
          <SharedThumbnail :base="base" :media="item" /><span
            v-if="item.title"
            class="shared-caption"
            >{{ item.title }}</span
          >
        </button>
      </div>
      <button
        v-if="folder && folder.items.length < folder.total"
        class="button"
        :disabled="folderBusy"
        @click="openFolder(folder, true)"
      >
        {{ t("加载更多") }}
      </button></ElDialog
    >
    <ElDialog
      :model-value="!!selected"
      :title="selected?.title || t('影像预览')"
      width="1000px"
      class="shared-viewer-dialog"
      append-to-body
      @close="
        selected = null;
        previewGeneration++;
      "
    >
      <article v-if="selected?.kind === 'event'" class="shared-story">
        {{ selected.content }}
      </article>
      <template v-else-if="selected"
        ><div class="shared-viewer">
          <VideoPlayer
            v-if="video && preview"
            :key="selected.id + '-' + live"
            :load-source="videoSource"
          /><ImageViewer
            v-else-if="preview"
            :src="preview"
            :alt="selected.title"
            @error="
              preview = '';
              previewError = t('预览加载失败');
            "
          />
          <div v-else class="shared-status">
            <p>{{ previewLoading ? t("正在加载预览…") : previewError }}</p>
            <button
              v-if="!previewLoading"
              class="button"
              @click="openMedia(selected, live)"
            >
              {{ t("重试") }}
            </button>
          </div>
        </div>
        <button
          v-if="selected.media_type === 'live_photo'"
          class="button"
          @click="openMedia(selected, !live)"
        >
          {{ live ? t("静态照片") : t("播放 LIVE") }}
        </button></template
      >
    </ElDialog>
  </main>
</template>
<style scoped>
.shared-sort {
  display: flex;
  justify-content: flex-end;
  margin-bottom: 16px;
}
.shared-page {
  max-width: 1040px;
  margin: auto;
  padding: 0 28px 40px;
}
.shared-nav {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 24px 0;
  border-bottom: 1px solid var(--line);
}
.shared-brand {
  display: flex;
  align-items: center;
  gap: 9px;
  font-family: Georgia, serif;
  font-size: 23px;
  color: var(--sage);
}
.shared-intro {
  text-align: center;
  padding: 52px 0 42px;
}
.shared-intro h1 {
  font-size: 34px;
  margin: 16px 0;
  font-weight: var(--weight-medium);
  overflow-wrap: anywhere;
}
.shared-intro p {
  color: var(--muted);
}
.shared-intro small {
  display: flex;
  justify-content: center;
  align-items: center;
  gap: 5px;
  font-size: 11px;
  color: var(--muted);
}
.shared-reader.has-rail {
  display: grid;
  grid-template-columns: 56px minmax(0, 1fr);
  gap: 24px;
}
.shared-reading {
  min-width: 0;
}
.rail-hint {
  color: var(--muted);
  font-size: 11px;
  margin: 0 0 20px;
}
.shared-day {
  scroll-margin-top: 28px;
  margin-bottom: 36px;
}
.shared-day > header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 16px;
}
.shared-day h2::before {
  content: "";
  display: inline-block;
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--sage);
  margin-right: 9px;
  vertical-align: middle;
}
.shared-day h2 {
  font-family: Georgia, serif;
  font-size: 22px;
  font-weight: var(--weight-medium);
}
.shared-day > header span {
  font-size: 12px;
  color: var(--muted);
}
.shared-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 12px;
  align-items: start;
}
.shared-card {
  position: relative;
  padding: 0;
  min-width: 0;
  background: none;
  border: 0;
  color: var(--text);
  text-align: left;
  cursor: pointer;
}
.shared-card:focus-visible {
  outline: 2px solid var(--sage);
  outline-offset: 4px;
  border-radius: 10px;
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
.shared-folder,
.shared-diary {
  aspect-ratio: 4/3;
  border: 1px solid transparent;
  border-radius: 10px;
  padding: 12px;
  overflow: hidden;
  background: var(--surface-soft);
}
.shared-folder b {
  display: flex;
  align-items: center;
  gap: 7px;
  font-size: 13px;
  white-space: nowrap;
  overflow: hidden;
}
.shared-folder small {
  color: var(--muted);
  font-size: 10px;
}
.shared-folder-previews {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 3px;
  margin: 14px 0 7px;
}
.shared-folder-previews :deep(.shared-thumb) {
  border-radius: 3px;
}
.shared-folder-previews :deep(.type-icon) {
  display: none;
}
.shared-diary {
  background: var(--surface);
}
.shared-diary small {
  color: var(--sage);
  font-size: 10px;
}
.shared-diary h3 {
  margin: 8px 0;
  font-size: 16px;
}
.shared-diary p {
  font-size: 12px;
  color: var(--muted);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.expand-actions {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 18px;
  margin-top: 16px;
}
.shared-footer {
  text-align: center;
  padding: 30px;
  font-size: 12px;
  color: var(--muted);
}
.shared-empty {
  text-align: center;
  padding: 80px 10px;
  color: var(--muted);
}
.shared-empty h1 {
  font-size: 24px;
}
.shared-viewer {
  height: 65dvh;
  background: #14221b;
  border-radius: 10px;
  overflow: hidden;
  color: white;
}
.shared-status {
  height: 100%;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
}
.shared-story {
  white-space: pre-wrap;
  line-height: 1.9;
  overflow-wrap: anywhere;
}
@media (max-width: 700px) {
  .shared-page {
    padding: 0 16px 30px;
  }
  .shared-nav {
    padding: 18px 0;
  }
  .shared-intro {
    padding: 32px 0;
  }
  .shared-intro h1 {
    font-size: 27px;
  }
  .shared-intro small {
    font-size: 10px;
    flex-wrap: wrap;
  }
  .shared-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
  }
  .shared-day h2 {
    font-size: 18px;
  }
  .shared-folder,
  .shared-diary {
    padding: 10px;
  }
  .shared-viewer {
    height: 60dvh;
  }
  .shared-reader.has-rail {
    grid-template-columns: 32px minmax(0, 1fr);
    gap: 12px;
  }
  .shared-day > header {
    flex-wrap: wrap;
    gap: 6px;
  }
}
</style>
