<script setup lang="ts">
import MotionDialog from "../components/MotionDialog.vue";
import {
  computed,
  ref,
  watch,
  nextTick,
  onMounted,
  onBeforeUnmount,
} from "vue";
import { useRoute } from "vue-router";
import {
  ArrowDown, ArrowUp, CalendarDays, ChevronDown, ChevronLeft, ChevronRight, ChevronUp,
  Ellipsis, ImageOff, ListCollapse, ListRestart, RefreshCw, ShieldCheck,
} from "lucide-vue-next";
import { api, post, notify } from "../lib/api";
import { cacheScope, clearCachedScope } from "../lib/local-cache";
import { t, locale } from "../lib/i18n";
import LanguageSwitch from "../components/LanguageSwitch.vue";
import TimelineMonths from "../components/TimelineMonths.vue";
import ScrollLoader from "../components/ScrollLoader.vue";
import TimelineOrder from "../components/TimelineOrder.vue";
import TimelineRail from "../components/TimelineRail.vue";
import SharedMediaCardContent from "../components/SharedMediaCardContent.vue";
import LivePhotoViewer from "../components/LivePhotoViewer.vue";
import { cachedMediaResource, releaseMediaResource, type MediaResource } from "../lib/media-resource";
import ImageViewer from "../components/ImageViewer.vue";
import VideoPlayer from "../components/VideoPlayer.vue";
const route = useRoute();
const shareLogo = import.meta.env.BASE_URL + "share-logo.png";
const initialTitle = document.title;
const titleMeta = document.querySelector<HTMLMetaElement>('meta[property="og:title"]');
const initialMetaTitle = titleMeta?.content ?? "";
const base = `/public/shares/${encodeURIComponent(String(route.params.token))}`;
const timelineOrder = ref(
  localStorage.getItem("yearly-shared-order") === "asc" ? "asc" : "desc",
);
type SharedMedia = { kind: "media"; id: number; title: string; media_type: string; child_ages?: { name: string; age: string }[] };
type SharedDiary = { kind: "event"; id: number; title: string; content: string };
type SharedItem = SharedMedia | SharedDiary;
type SharedDay = { day: string; total: number; items: SharedItem[] };
type Share = {
  scope: "selection" | "date_range";
  title: string;
  card_title: string;
  start_date: string;
  end_date: string;
  expires_at: string;
  has_avatar: boolean;
  profile_name: string | null;
};
type SharedPage = { share: Share; days: SharedDay[]; next_before: string | null; next_after: string | null };
type ShareIndex = { dates: string[]; total: number; media_counts: Record<string, number> };

const share = ref<Share | null>(null),
  days = ref<SharedDay[]>([]),
  nextDate = ref<string | null>(null);
watch([share, locale], () => {
  document.title = share.value?.card_title || share.value?.title || t("我们的家庭时光");
  if (titleMeta) titleMeta.content = document.title;
}, { immediate: true });
const dateIndex = ref<string[]>([]);
const total = ref(0);
const mediaCounts = ref<Record<string, number>>({});
const showingSelection = computed(() => share.value?.scope === "selection");
const railDates = computed(() =>
  timelineOrder.value === "asc"
    ? dateIndex.value
    : [...dateIndex.value].reverse(),
);
const previousDate = computed(() => {
  const first = days.value[0]?.day;
  return first && railDates.value.indexOf(first) > 0 ? first : null;
});
const pendingDay = computed(() => days.value.find((day) => day.items.length < day.total));
const currentDate = ref("");
const anchorDate = ref("");
const railHeld = ref(false);
let railTarget: string | undefined;
let applyingRail = false;
function holdRail(held: boolean) {
  railHeld.value = held;
  if (!held) void applyRail();
}
function selectDate(date: string) {
  railTarget = date;
  void applyRail();
}
function cancelRail() { railTarget = undefined; }
async function applyRail() {
  const target = railTarget;
  if (!target || applyingRail || loading.value || busyDay.value) return;
  applyingRail = true;
  try {
    if (!days.value.some(day => day.day === target)) {
      if (railHeld.value) return;
      await load("replace", target);
      if (!days.value.some(day => day.day === target)) {
        if (railTarget === target) railTarget = undefined;
        return;
      }
    }
    if (railTarget !== target) return;
    monthList.value?.reveal(target);
    await nextTick();
    if (railTarget !== target) return;
    currentDate.value = target;
    scrollToDay(target);
    if (!railHeld.value) railTarget = undefined;
  } finally {
    applyingRail = false;
    if (railTarget && railTarget !== target) void applyRail();
  }
}
function scrollToDay(day: string) {
  document.getElementById(`shared-day-${day}`)?.scrollIntoView({ block: "start" });
}

const dayLimit = 8;
const expandedDays = ref<Record<string, boolean>>({});
const expandAllDays = ref(false);
function dayExpanded(day: string) { return expandedDays.value[day] ?? expandAllDays.value; }
function visibleDayItems(day: SharedDay) {
  return showingSelection.value || dayExpanded(day.day) ? day.items : day.items.slice(0, dayLimit);
}
async function toggleDay(day: string) {
  expandedDays.value[day] = !dayExpanded(day);
  if (!dayExpanded(day)) {
    await nextTick();
    scrollToDay(day);
  }
}
function setExpanded(expanded: boolean) {
  cancelRail();
  expandedDays.value = {};
  expandAllDays.value = expanded;
  monthList.value?.setAll(!expanded);
}
const monthList = ref<{ reveal(date: string): void; setAll(collapsed: boolean): void }>();
const reading = ref<HTMLElement>();
const sortMenu = ref<HTMLDetailsElement>();
const actionsMenu = ref<HTMLDetailsElement>();
function closeMenu(menu?: HTMLDetailsElement) { if (menu) menu.open = false; }
function toggleMenu(menu?: HTMLDetailsElement, other?: HTMLDetailsElement) {
  if (menu?.open) closeMenu(other);
}
function closeOutsideMenus(event: PointerEvent) {
  if (!(event.target instanceof Node)) return;
  for (const menu of [sortMenu.value, actionsMenu.value]) {
    if (menu?.open && !menu.contains(event.target)) closeMenu(menu);
  }
}
function chooseOrder(order: "asc" | "desc") {
  timelineOrder.value = order;
  closeMenu(sortMenu.value);
}
async function returnToStart() {
  cancelRail();
  anchorDate.value = "";
  await load();
  window.scrollTo({ top: 0, behavior: "instant" });
}
async function refreshTimeline() {
  const anchor = anchorDate.value;
  if (!anchor) { await returnToStart(); return; }
  cancelRail();
  await load("replace", anchor, true);
  if (!days.value.some(day => day.day === anchor)) return;
  monthList.value?.reveal(anchor);
  await nextTick();
  currentDate.value = anchor;
  scrollToDay(anchor);
}
function runAction(action: "refresh" | "expand" | "collapse") {
  closeMenu(actionsMenu.value);
  if (action === "refresh") void refreshTimeline();
  else setExpanded(action === "expand");
}
const loading = ref(false),
  error = ref(""),
  unavailable = ref(false),
  selected = ref<SharedItem | null>(null);
const dayErrors = ref<Record<string, string>>({}),
  pageError = ref(""),
  previousError = ref(""),
  busyDay = ref("");
const preview = ref(""),
  previewError = ref(""),
  live = ref(false),
  previewLoading = ref(false);
const video = computed(
  () => selected.value?.kind === "media" && selected.value.media_type === "video",
);
watch([loading, busyDay], ([pageLoading, dayLoading]) => { if (!pageLoading && !dayLoading) void applyRail(); });
let expiryTimer: ReturnType<typeof setTimeout>;
const clock = ref(Date.now());
const remainingSeconds = computed(() =>
  share.value ? Math.max(0, Math.ceil((new Date(share.value.expires_at).getTime() - clock.value) / 1000)) : 0,
);
const countdown = computed(() => {
  const seconds = remainingSeconds.value;
  const days = Math.floor(seconds / 86400);
  const time = `${String(Math.floor(seconds / 3600) % 24).padStart(2, "0")}:${String(Math.floor(seconds / 60) % 60).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
  return days ? t("{p0} 天 {p1}", { p0: days, p1: time }) : time;
});
let countdownTimer: ReturnType<typeof setInterval>;
const avatar = computed(() => share.value?.has_avatar ? import.meta.env.BASE_URL + `api/public/shares/${encodeURIComponent(String(route.params.token))}/avatar` : "");
let previewGeneration = 0;
let loadGeneration = 0;
let visitRecorded = false;
function expire() {
  void clearCachedScope(cacheScope(base)!);
  releaseMediaResource(preview.value);
  unavailable.value = true;
  error.value = t("分享已失效或不存在");
  share.value = null;
  days.value = [];
  dateIndex.value = [];
  total.value = 0;
  mediaCounts.value = {};
  cancelRail();
  loadGeneration++;
  selected.value = null;
  preview.value = "";
  previewGeneration++;
}
async function load(direction: "replace" | "next" | "previous" = "replace", anchor?: string, refreshIndex = false) {
  const more = direction !== "replace";
  if (more && (loading.value || busyDay.value)) return;
  const generation = ++loadGeneration;
  const order = timelineOrder.value;
  loading.value = true;
  error.value = "";
  unavailable.value = false;
  if (direction === "previous") previousError.value = "";
  else {
    pageError.value = "";
    if (!more) previousError.value = "";
  }
  if (!more && !anchor) {
    days.value = [];
    nextDate.value = null;
    dayErrors.value = {};
  }
  try {
    const params = new URLSearchParams({ order });
    const prior = new URLSearchParams({
      order, backward: "true",
      [order === "asc" ? "before" : "after"]: anchor || previousDate.value || "",
    });
    if (direction === "next" && nextDate.value)
      params.set(order === "asc" ? "after" : "before", nextDate.value);
    if (anchor) params.set("anchor", anchor);
    const [data, index, earlier] = await Promise.all([
      direction === "previous" ? null : api<SharedPage>(`${base}?${params}`),
      more || (anchor && !refreshIndex) ? null : api<ShareIndex>(`${base}/dates`),
      direction === "previous" || anchor ? api<SharedPage>(`${base}?${prior}`) : null,
    ]);
    if (generation !== loadGeneration) return;
    if (direction === "previous") {
      const first = document.getElementById(`shared-day-${previousDate.value}`);
      const top = first?.getBoundingClientRect().top;
      days.value = [...earlier!.days, ...days.value];
      await nextTick();
      if (first && top !== undefined && generation === loadGeneration)
        window.scrollBy(0, first.getBoundingClientRect().top - top);
      return;
    }
    if (!data) return;
    share.value = data.share;
    clock.value = Date.now();
    if (!visitRecorded) {
      visitRecorded = true;
      void post(`${base}/visits`).catch(() => {});
    }
    if (index) {
      dateIndex.value = index.dates;
      total.value = index.total;
      mediaCounts.value = index.media_counts || {};
    }
    if (!more) currentDate.value = data.days[0]?.day || "";
    days.value = more ? [...days.value, ...data.days] : [...(earlier?.days || []), ...data.days];
    if (!more) anchorDate.value = anchor && data.days.some(day => day.day === anchor) ? anchor : "";
    nextDate.value = order === "asc" ? data.next_after : data.next_before;
    clearTimeout(expiryTimer);
    expiryTimer = setTimeout(
      expire,
      Math.max(0, new Date(data.share.expires_at).getTime() - Date.now()),
    );
  } catch (e) {
    if (generation === loadGeneration) {
      if (direction === "previous") previousError.value = e instanceof Error ? e.message : t("请求失败");
      else if (more) pageError.value = e instanceof Error ? e.message : t("请求失败");
      else if (anchor) notify(e);
      else {
        error.value = e instanceof Error ? e.message : t("请求失败");
        unavailable.value = error.value === t("分享已失效或不存在") ||
          (e instanceof Error && "status" in e && (e.status === 403 || e.status === 404 || e.status === 410));
      }
    }
  } finally {
    if (generation === loadGeneration) loading.value = false;
  }
}
async function loadDay(day: SharedDay) {
  if (busyDay.value || loading.value || day.items.length >= day.total) return;
  busyDay.value = day.day;
  dayErrors.value[day.day] = "";
  const generation = loadGeneration;
  try {
    const data = await api(
      `${base}/days/${day.day}?offset=${day.items.length}&order=${timelineOrder.value}`,
    );
    if (generation !== loadGeneration) return;
    day.items.push(...data.items);
    day.total = data.total;
  } catch (e) {
    if (generation === loadGeneration)
      dayErrors.value[day.day] = e instanceof Error ? e.message : t("请求失败");
  } finally {
    if (busyDay.value === day.day) busyDay.value = "";
  }
}
async function loadNext() {
  if (pendingDay.value) await loadDay(pendingDay.value);
  else if (nextDate.value) await load("next");
}
const viewerDay = computed(() => days.value.find(day =>
  day.items.some(item => item.kind === selected.value?.kind && item.id === selected.value.id)));
const mediaTotal = computed(() => Object.values(mediaCounts.value).reduce((sum, count) => sum + count, 0));
const previewPosition = computed(() => {
  const day = viewerDay.value;
  if (!day || selected.value?.kind !== "media") return null;
  const items = day.items.filter(item => item.kind === "media");
  const dayIndex = items.findIndex(item => item.id === selected.value!.id) + 1;
  let preceding = 0;
  for (const date of railDates.value) {
    if (date === day.day) break;
    preceding += mediaCounts.value[date] ?? 0;
  }
  return {
    day: day.day,
    dayIndex,
    dayTotal: Math.max(items.length, mediaCounts.value[day.day] ?? 0),
    index: preceding + dayIndex,
    total: mediaTotal.value,
  };
});
const pagingPreview = ref(false);
const previewPageError = ref("");
function canMovePreview(step: -1 | 1) {
  const position = previewPosition.value;
  if (!position) return false;
  if (position.total) return step < 0 ? position.index > 1 : position.index < position.total;
  const media = days.value.flatMap(day => day.items.filter(item => item.kind === "media"));
  const index = media.findIndex(item => item.id === selected.value?.id);
  return step < 0 ? index > 0 || !!previousDate.value
    : index < media.length - 1 || !!nextDate.value || !!pendingDay.value;
}
async function movePreview(step: -1 | 1) {
  const origin = selected.value;
  const originDay = viewerDay.value?.day;
  if (origin?.kind !== "media" || !originDay || pagingPreview.value || !canMovePreview(step)) return;
  pagingPreview.value = true;
  previewPageError.value = "";
  let date = originDay;
  try {
    while (selected.value === origin) {
      const dayIndex = days.value.findIndex(day => day.day === date);
      const day = days.value[dayIndex];
      if (!day) return;
      const initial = date === originDay;
      const hasMore = day.items.length < day.total;
      const start = initial ? day.items.findIndex(item => item.kind === "media" && item.id === origin.id)
        : step > 0 ? -1 : day.items.length;
      if (step > 0 || initial || !hasMore) {
        for (let index = start + step; index >= 0 && index < day.items.length; index += step) {
          const item = day.items[index];
          if (item.kind === "media") { void openMedia(item); return; }
        }
      }
      if (hasMore && (step > 0 || !initial)) {
        const offset = day.items.length;
        await loadDay(day);
        if (offset < day.items.length || day.items.length >= day.total) continue;
        previewPageError.value = dayErrors.value[day.day] || t("请求失败");
        return;
      }
      const adjacent = days.value[dayIndex + step];
      if (adjacent) { date = adjacent.day; continue; }
      if (!(step < 0 ? previousDate.value : nextDate.value)) return;
      const size = days.value.length;
      await load(step < 0 ? "previous" : "next");
      if (days.value.length === size) {
        previewPageError.value = (step < 0 ? previousError.value : pageError.value) || "";
        return;
      }
    }
  } finally {
    pagingPreview.value = false;
  }
}
function onPreviewKey(event: KeyboardEvent) {
  if (selected.value?.kind !== "media" || event.defaultPrevented ||
      (event.target instanceof HTMLElement && event.target.closest("input, video, [role=slider]"))) return;
  const step = event.key === "ArrowLeft" ? -1 : event.key === "ArrowRight" ? 1 : null;
  if (!step) return;
  event.preventDefault();
  void movePreview(step);
}
let swipe: { id: number; x: number; y: number } | undefined;
function beginSwipe(event: PointerEvent) {
  if (!event.isPrimary) { swipe = undefined; return; }
  if (event.pointerType === "mouse" ||
      (event.target as HTMLElement).closest("button, input, .zoomed")) return;
  swipe = { id: event.pointerId, x: event.clientX, y: event.clientY };
}
function endSwipe(event: PointerEvent) {
  const start = swipe;
  swipe = undefined;
  if (!start || start.id !== event.pointerId || (event.target as HTMLElement).closest(".zoomed")) return;
  const dx = event.clientX - start.x, dy = event.clientY - start.y;
  if (Math.abs(dx) > 48 && Math.abs(dx) > Math.abs(dy) * 1.5) void movePreview(dx < 0 ? 1 : -1);
}
async function openMedia(item: SharedItem, playLive = item.kind === "media" && item.media_type === "live_photo") {
  selected.value = item;
  live.value = playLive;
  releaseMediaResource(preview.value);
  preview.value = "";
  previewError.value = "";
  previewPageError.value = "";
  const generation = ++previewGeneration;
  if (item.kind === "event") { previewLoading.value = false; return; }
  previewLoading.value = true;
  try {
    const purpose = item.media_type === "video" ? "thumbnail" : "preview";
    const data = await cachedMediaResource(
      `${base}/media/${item.id}/url?purpose=${purpose}&live=false`, true,
    );
    if (generation !== previewGeneration) { releaseMediaResource(data.url); return; }
    if (data.url) preview.value = data.url;
    else previewError.value = t("压缩预览仍在准备，请稍后再试");
  } catch (e) {
    if (generation === previewGeneration)
      previewError.value = e instanceof Error ? e.message : t("请求失败");
  } finally {
    if (generation === previewGeneration) previewLoading.value = false;
  }
}
function previewFailed() {
  releaseMediaResource(preview.value);
  preview.value = "";
  previewError.value = t("预览加载失败");
}
function motionSource() {
  return api<MediaResource>(`${base}/media/${selected.value!.id}/url?purpose=preview&live=true`);
}
async function videoSource() {
  const data = await api(
    `${base}/media/${selected.value!.id}/url?purpose=preview&live=${live.value}`,
  );
  if (!data.url) throw new Error(t("压缩预览仍在准备，请稍后再试"));
  return data.url;
}
let scrollFrame = 0;
function trackDate() {
  if (scrollFrame) return;
  scrollFrame = requestAnimationFrame(() => {
    scrollFrame = 0;
    if (railHeld.value || railTarget) return;
    const sections =
      reading.value?.querySelectorAll<HTMLElement>(".shared-day");
    if (!sections?.length) return;
    let closest = sections[0];
    for (const section of sections) {
      if (section.getBoundingClientRect().top > 86) break;
      closest = section;
    }
    currentDate.value = closest.dataset.day!;
  });
}
watch(timelineOrder, (value) => {
  localStorage.setItem("yearly-shared-order", value);
  void returnToStart();
});
onMounted(() => {
  countdownTimer = setInterval(() => { clock.value = Date.now(); }, 1000);
  load();
  window.addEventListener("scroll", trackDate, { passive: true });
  window.addEventListener("keydown", onPreviewKey);
  document.addEventListener("pointerdown", closeOutsideMenus);
});
onBeforeUnmount(() => {
  loadGeneration++;
  previewGeneration++;
  cancelRail();
  selected.value = null;
  clearInterval(countdownTimer);
  document.title = initialTitle;
  if (titleMeta) titleMeta.content = initialMetaTitle;
  clearTimeout(expiryTimer);
  cancelAnimationFrame(scrollFrame);
  releaseMediaResource(preview.value);
  window.removeEventListener("scroll", trackDate);
  window.removeEventListener("keydown", onPreviewKey);
  document.removeEventListener("pointerdown", closeOutsideMenus);
});
</script>
<template>
  <main class="shared-page">
    <header class="shared-nav">
      <span class="shared-brand"><img :src="shareLogo" alt="yearly" width="26" height="26" /></span>
      <span class="shared-nav-title">{{ t("成长时间线") }}</span>
      <div class="shared-nav-actions">
        <LanguageSwitch />
        <details v-if="share" ref="actionsMenu" class="shared-menu" @toggle="toggleMenu(actionsMenu, sortMenu)" @keydown.esc="closeMenu(actionsMenu)">
          <summary class="shared-icon-button" :aria-label="t('更多时间线操作')"><Ellipsis :size="22" aria-hidden="true" /></summary>
          <div class="shared-menu-panel">
            <button type="button" :disabled="loading || !!busyDay" @click="runAction('refresh')">
              <RefreshCw :size="16" aria-hidden="true" />{{ t("刷新时间线") }}
            </button>
            <template v-if="!showingSelection">
              <button type="button" @click="runAction('expand')">
                <ListRestart :size="16" aria-hidden="true" />{{ t("展开全部回忆") }}
              </button>
              <button type="button" @click="runAction('collapse')">
                <ListCollapse :size="16" aria-hidden="true" />{{ t("收起全部回忆") }}
              </button>
            </template>
          </div>
        </details>
      </div>
    </header>
    <div v-if="error" class="shared-empty" role="alert">
      <ShieldCheck :size="36" aria-hidden="true" />
      <h1>{{ error }}</h1>
      <p v-if="unavailable">{{ t("请联系分享者获取新的链接") }}</p>
      <button v-else type="button" class="button" @click="load()">{{ t("重新加载") }}</button>
    </div>
    <template v-else-if="share">
      <section class="shared-intro">
        <div class="shared-title">
          <img v-if="avatar" :src="avatar" :alt="share.profile_name || ''" class="shared-avatar" />
          <div>
            <h1>{{ share.card_title || share.title || t("一起长大的日子") }}</h1>
            <p v-if="showingSelection">{{ t("指定影像分享") }}</p>
            <p v-else><time :datetime="share.start_date">{{ share.start_date }}</time> — <time :datetime="share.end_date">{{ share.end_date }}</time></p>
          </div>
        </div>
        <div class="share-access">
          <span><ShieldCheck :size="14" aria-hidden="true" />{{ t("只读分享") }}</span>
          <p>{{ t("有效至 {p0}", { p0: new Date(share.expires_at).toLocaleString(locale) }) }}</p>
          <p class="share-countdown">{{ t("链接剩余有效时间") }} <time :datetime="`PT${remainingSeconds}S`">{{ countdown }}</time></p>
        </div>
      </section>
      <div class="shared-reader" :class="{ 'has-rail': !showingSelection && railDates.length > 1 }">
        <TimelineRail v-if="!showingSelection" :dates="railDates" :current="currentDate"
          @hold="holdRail" @scrub="selectDate" @select="selectDate" @cancel="cancelRail" />
        <div ref="reading" class="shared-reading">
          <div class="reading-toolbar">
            <span>{{ showingSelection ? t("所选影像") : t("所有回忆") }}</span>
            <span>{{ t("{p0} 项", { p0: total ?? days.reduce((count, day) => count + day.total, 0) }) }}</span>
            <details v-if="!showingSelection" ref="sortMenu" class="shared-menu shared-sort" @toggle="toggleMenu(sortMenu, actionsMenu)" @keydown.esc="closeMenu(sortMenu)">
              <summary class="shared-sort-button" :aria-label="t('排序')" :title="t('时间顺序')">
                <ArrowUp v-if="timelineOrder === 'asc'" :size="14" aria-hidden="true" />
                <ArrowDown v-else :size="14" aria-hidden="true" />{{ t("归档") }}
              </summary>
              <div class="shared-menu-panel">
                <TimelineOrder :model-value="timelineOrder" :disabled="loading || !!busyDay" @update:model-value="chooseOrder" />
              </div>
            </details>
          </div>
          <div v-if="anchorDate" class="reading-anchor">
            <span>{{ t("已定位到 {p0}", { p0: anchorDate }) }}</span>
            <button type="button" :disabled="loading || !!busyDay" @click="returnToStart">{{ t("回到起点") }}</button>
          </div>
          <div v-if="previousDate" class="shared-footer shared-previous">
            <ScrollLoader :loading="railHeld || loading || !!busyDay || !!selected" :has-more="!!previousDate"
              :error="previousError" @load="load('previous')" />
          </div>
          <TimelineMonths ref="monthList" :days="days" :ungrouped="showingSelection" compact v-slot="{ day }">
            <section class="shared-day" :id="`shared-day-${day.day}`" :data-day="day.day">
              <header v-if="!showingSelection">
                <h2>{{ day.day.replaceAll("-", ".") }}</h2>
                <span>{{ t("{p0} 项", { p0: day.total }) }}</span>
              </header>
              <div class="shared-grid">
                <button v-for="item in visibleDayItems(day)" :key="item.kind + item.id"
                  type="button" class="shared-card" @click="openMedia(item)">
                  <div v-if="item.kind === 'event'" class="shared-diary">
                    <small>{{ t("成长日记") }}</small>
                    <h3>{{ item.title }}</h3>
                    <p>{{ item.content }}</p>
                  </div>
                  <SharedMediaCardContent v-else :base="base" :media="item" />
                </button>
              </div>
              <button v-if="!showingSelection && day.items.length > dayLimit" type="button"
                class="day-toggle" :aria-expanded="dayExpanded(day.day)" @click="toggleDay(day.day)">
                <ChevronUp v-if="dayExpanded(day.day)" :size="15" aria-hidden="true" />
                <ChevronDown v-else :size="15" aria-hidden="true" />
                {{ dayExpanded(day.day) ? t("收起当天影像") : t("展开其余 {p0} 项", { p0: day.items.length - dayLimit }) }}
              </button>
              <ScrollLoader v-if="day.items.length < day.total" :loading="railHeld || loading || !!busyDay || !!selected"
                :has-more="day.items.length < day.total" :error="dayErrors[day.day]" @load="loadDay(day)" />
            </section>
          </TimelineMonths>
          <div v-if="!days.length && !loading" class="shared-empty">
            <ImageOff :size="36" aria-hidden="true" />
            <p>{{ t("这个范围还没有可分享的回忆") }}</p>
          </div>
          <footer class="shared-footer">
            <ScrollLoader v-if="nextDate || pendingDay" :loading="railHeld || loading || !!busyDay || !!selected"
              :has-more="!!nextDate || !!pendingDay" :error="pageError || dayErrors[pendingDay?.day || '']" @load="loadNext" />
          </footer>
        </div>
      </div>
    </template>
    <div v-else-if="loading" class="shared-empty" role="status">{{ t("正在加载…") }}</div>

    <MotionDialog :model-value="!!selected" :title="selected?.kind === 'event' ? t('成长日记') : selected?.title || t('影像预览')"
      class="shared-viewer-dialog" modal-class="shared-overlay"
      :class="selected?.kind === 'event' ? 'shared-diary-fullscreen' : 'shared-media-fullscreen'"
      fullscreen append-to-body destroy-on-close
      @close="releaseMediaResource(preview); preview = ''; selected = null; previewGeneration++">
      <article v-if="selected?.kind === 'event'" class="shared-story">
        <p v-if="viewerDay" class="story-date"><CalendarDays :size="18" aria-hidden="true" />
          <time :datetime="viewerDay.day">{{ viewerDay.day.replaceAll("-", ".") }}</time>
        </p>
        <h2>{{ selected.title }}</h2>
        <p class="story-content">{{ selected.content.trim() ? selected.content : t("这篇日记还没有正文。") }}</p>
      </article>
      <template v-else-if="selected?.kind === 'media'">
        <div class="shared-viewer" @pointerdown.capture="beginSwipe" @pointerup.capture="endSwipe" @pointercancel.capture="swipe = undefined">
          <LivePhotoViewer v-if="live && preview" :key="selected.id" :src="preview" :alt="selected.title"
            :load-motion="motionSource" autoplay @error="previewFailed" />
          <VideoPlayer v-else-if="video && !previewLoading" :key="selected.id" :poster="preview || undefined" :load-source="videoSource" />
          <ImageViewer v-else-if="preview" :key="selected.id" :src="preview" :alt="selected.title"
            :min-zoom="1" :max-zoom="4" @error="previewFailed" />
          <div v-else class="shared-status">
            <p>{{ previewLoading ? t("正在加载预览…") : previewError }}</p>
            <button v-if="!previewLoading" type="button" class="button" @click="openMedia(selected, live)">{{ t("重试") }}</button>
          </div>
        </div>
        <button v-if="selected.media_type === 'live_photo'" class="button shared-live-toggle" type="button" @click="live = !live">
          {{ live ? t("静态照片") : t("实况照片") }}
        </button>
        <p v-if="previewPageError" class="shared-preview-error" role="alert">{{ previewPageError }}</p>
        <div v-if="previewPosition" class="shared-preview-navigation">
          <button type="button" :aria-label="t('上一项')" :disabled="pagingPreview || !canMovePreview(-1)" @click="movePreview(-1)">
            <ChevronLeft :size="22" aria-hidden="true" />
          </button>
          <div class="shared-preview-position" aria-live="polite">
            <time v-if="!showingSelection" :datetime="previewPosition.day">{{ previewPosition.day.replaceAll("-", ".") }}</time>
            <div>
              <span v-if="!showingSelection">{{ t("当天 {p0} / {p1}", { p0: previewPosition.dayIndex, p1: previewPosition.dayTotal }) }}</span>
              <span v-if="previewPosition.total">{{ t("全部 {p0} / {p1}", { p0: previewPosition.index, p1: previewPosition.total }) }}</span>
            </div>
          </div>
          <button type="button" :aria-label="t('下一项')" :disabled="pagingPreview || !canMovePreview(1)" @click="movePreview(1)">
            <ChevronRight :size="22" aria-hidden="true" />
          </button>
        </div>
      </template>
    </MotionDialog>
  </main>
</template>

<style scoped>
.shared-page {
  --shared-bar-height: 54px;
  max-width: 1040px;
  min-height: 100vh;
  margin: auto;
  padding: 0 16px 32px;
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Microsoft YaHei", sans-serif;
}
.shared-nav {
  position: sticky;
  top: 0;
  z-index: 10;
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr);
  align-items: center;
  min-height: var(--shared-bar-height);
  background: var(--bg);
  border-bottom: 1px solid var(--line);
}
.shared-brand img { display: block; border-radius: 6px; }
.shared-nav-title { font-size: 16px; font-weight: 650; }
.shared-nav-actions { display: flex; align-items: center; justify-content: flex-end; gap: 4px; min-width: 0; }
.shared-nav-actions :deep(.language-switch) { gap: 0; padding: 1px; }
.shared-nav-actions :deep(.language-switch button) { min-width: 31px; padding: 4px; }
.shared-menu { position: relative; color: var(--sage); }
.shared-menu summary {
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  list-style: none;
}
.shared-menu summary::-webkit-details-marker { display: none; }
.shared-icon-button { width: 44px; height: 44px; }
.shared-menu-panel {
  position: absolute;
  z-index: 7;
  right: 0;
  top: calc(100% + 3px);
  min-width: max-content;
  padding: 5px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: var(--surface);
  box-shadow: 0 5px 24px #0002;
}
.shared-menu-panel > button {
  display: flex;
  align-items: center;
  gap: 9px;
  width: 100%;
  min-height: 44px;
  padding: 8px 10px;
  border: none;
  border-radius: 7px;
  background: transparent;
  color: var(--text);
  text-align: left;
  cursor: pointer;
}
.shared-menu-panel > button:hover { background: var(--surface-hover); }
.shared-menu-panel > button:disabled { opacity: .6; cursor: wait; }
.shared-intro {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 12px 24px;
  padding: 14px 0;
  margin-bottom: 12px;
  border-bottom: 1px solid var(--line);
}
.shared-title { display: flex; align-items: center; min-width: 0; gap: 12px; }
.shared-title h1 {
  margin: 0 0 3px;
  font: 650 clamp(21px, 4vw, 27px)/1.25 var(--serif);
  overflow-wrap: anywhere;
}
.shared-avatar { width: 44px; height: 44px; flex: 0 0 44px; border-radius: 50%; object-fit: cover; }
.shared-intro p { color: var(--muted); font-size: 12px; }
.share-access { display: flex; flex-wrap: wrap; align-items: center; gap: 3px 10px; font-size: 12px; }
.share-access > span { display: flex; align-items: center; gap: 4px; color: var(--sage); }
.share-countdown time {
  display: inline-block;
  color: var(--sage);
  font-weight: 600;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}
.shared-reader.has-rail { display: grid; grid-template-columns: 44px minmax(0, 1fr); gap: 12px; }
.shared-reading { min-width: 0; }
.reading-toolbar {
  display: flex;
  align-items: center;
  gap: 9px;
  min-height: 44px;
  color: var(--muted);
  font-size: 14px;
  font-weight: 500;
  font-variant-numeric: tabular-nums;
}
.reading-toolbar > span:first-child { margin-inline-end: auto; }
.shared-sort-button {
  min-height: 36px;
  gap: 5px;
  padding: 0 9px;
  border: 1px solid var(--line);
  border-radius: 9px;
  color: var(--sage);
  background: var(--surface);
  font-size: 13px;
}
.shared-sort :deep(.timeline-order button) { min-height: 44px; }
.reading-anchor { display: flex; align-items: center; justify-content: space-between; gap: 8px; color: var(--muted); font-size: 12px; }
.reading-anchor button { min-height: 44px; padding: 0 6px; background: none; border: none; color: var(--sage); cursor: pointer; }
.reading-anchor button:disabled { opacity: .6; }
.day-toggle {
  display: flex;
  justify-content: center;
  align-items: center;
  gap: 7px;
  width: 100%;
  min-height: 44px;
  margin-top: 8px;
  background: none;
  border: none;
  color: var(--sage);
  cursor: pointer;
}
.shared-day { scroll-margin-top: calc(var(--shared-bar-height) + 10px); margin-bottom: 14px; }
.shared-day > header {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 5px 12px;
  margin-bottom: 14px;
}
.shared-day h2::before {
  content: "";
  display: inline-block;
  width: 7px;
  height: 7px;
  margin-right: 9px;
  border-radius: 50%;
  background: var(--sage);
  vertical-align: 2px;
}
.shared-day h2 { margin: 0; font: 650 17px/1.3 var(--serif); font-variant-numeric: tabular-nums; }
.shared-day > header span { font-size: 12px; color: var(--muted); white-space: nowrap; }
.shared-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(120px, 100%), 1fr));
  gap: 12px 10px;
  align-items: start;
}
.shared-card {
  width: 100%;
  max-width: 240px;
  padding: 0;
  min-width: 0;
  background: none;
  border: 0;
  color: var(--text);
  text-align: left;
  cursor: pointer;
}
.shared-card:focus-visible { outline: 2px solid var(--sage); outline-offset: 3px; border-radius: 14px; }
.shared-diary {
  aspect-ratio: 4/3;
  border-radius: 10px;
  padding: 12px;
  overflow: hidden;
  background: color-mix(in srgb, var(--sage) 7%, var(--bg));
}
.shared-diary small { color: var(--sage); font-size: 11px; }
.shared-diary h3, .shared-diary p {
  margin: 5px 0 0;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  overflow: hidden;
  overflow-wrap: anywhere;
}
.shared-diary h3 { font: 650 16px/1.25 -apple-system, BlinkMacSystemFont, sans-serif; -webkit-line-clamp: 2; }
.shared-diary p { font-size: 12px; line-height: 1.4; color: var(--muted); -webkit-line-clamp: 3; }
.shared-footer { text-align: center; }
.shared-empty { text-align: center; padding: 52px 8px; color: var(--muted); }
.shared-empty svg { color: var(--sage); margin-bottom: 10px; }
.shared-empty p, .shared-empty h1 { margin: 8px 0; }
.shared-empty h1 { font-size: 24px; }
.shared-status {
  min-height: 100%;
  display: flex;
  flex-direction: column;
  justify-content: center;
  align-items: center;
  gap: 12px;
  padding: 12px;
  text-align: center;
}
.shared-story {
  max-width: 680px;
  margin: auto;
  padding: 32px max(24px, env(safe-area-inset-left));
  overflow-wrap: anywhere;
}
.story-date { display: flex; align-items: center; gap: 7px; color: var(--sage); font-size: 14px; }
.shared-story h2 { margin: 10px 0 24px; font: 650 clamp(27px, 5vw, 36px)/1.32 var(--serif); }
.story-content { white-space: pre-wrap; font-size: 18px; line-height: 1.85; }
.story-content::before { content: ""; display: block; width: 36px; height: 2px; margin-bottom: 22px; background: var(--sage); }
.shared-preview-navigation { display: flex; align-items: center; justify-content: center; gap: 18px; padding: 0 12px 8px; color: #fff; }
.shared-preview-navigation button {
  display: grid;
  place-items: center;
  min-width: 44px;
  min-height: 44px;
  border: 0;
  background: transparent;
  color: inherit;
  cursor: pointer;
}
.shared-preview-navigation button:disabled { opacity: .42; cursor: default; }
.shared-preview-position { min-width: 110px; text-align: center; font-variant-numeric: tabular-nums; }
.shared-preview-position time { display: block; font-size: 15px; font-weight: 650; }
.shared-preview-position div { display: flex; flex-wrap: wrap; justify-content: center; gap: 3px 10px; font-size: 12px; color: #ffffffbf; }
.shared-preview-error { margin: 3px 10px; text-align: center; font-size: 12px; color: #ffc5bb; }
@media (max-width: 540px) {
  .shared-page { padding: 0 12px 24px; }
  .shared-reader.has-rail { gap: 8px; }
  .shared-nav-title { justify-self: center; }
  .shared-grid { grid-template-columns: repeat(auto-fill, minmax(min(115px, 100%), 1fr)); }
  .shared-intro { gap: 7px; }
  .share-countdown { margin: 0; }
}
@media (max-width: 370px) {
  .shared-nav { grid-template-columns: auto 1fr auto; }
}
</style>

<style>
.shared-overlay .el-overlay-dialog { overscroll-behavior: contain; }
.el-dialog:is(.shared-media-fullscreen, .shared-diary-fullscreen) {
  width: 100vw;
  max-width: none;
  height: 100dvh;
  margin: 0 !important;
  padding: env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left) !important;
  border-radius: 0 !important;
  display: flex;
  flex-direction: column;
  overflow: hidden;
}
.el-dialog.shared-media-fullscreen { background: #000; color: #fff; }
.el-dialog.shared-diary-fullscreen { background: var(--bg); color: var(--text); }
:is(.shared-media-fullscreen, .shared-diary-fullscreen) .el-dialog__header {
  flex-shrink: 0;
  min-height: 52px;
  margin: 0;
  padding: 15px 56px;
  text-align: center;
  border-bottom: 1px solid color-mix(in srgb, currentColor 15%, transparent);
}
:is(.shared-media-fullscreen, .shared-diary-fullscreen) .el-dialog__title {
  display: block;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font: 650 14px/22px -apple-system, BlinkMacSystemFont, sans-serif;
  color: inherit;
}
:is(.shared-media-fullscreen, .shared-diary-fullscreen) .el-dialog__headerbtn {
  top: max(4px, env(safe-area-inset-top));
  left: max(6px, env(safe-area-inset-left));
  right: auto;
  width: 44px;
  height: 44px;
}
:is(.shared-media-fullscreen, .shared-diary-fullscreen) .el-dialog__close { color: inherit; }
:is(.shared-media-fullscreen, .shared-diary-fullscreen) .el-dialog__body {
  flex: 1;
  min-height: 0;
  padding: 0;
  color: inherit;
}
.shared-diary-fullscreen .el-dialog__body { overflow: auto; }
.shared-media-fullscreen .el-dialog__body { display: flex; flex-direction: column; overflow: hidden; color: #fff; }
.shared-media-fullscreen .shared-viewer {
  position: relative;
  flex: 1;
  min-height: 0;
  overflow: hidden;
  touch-action: pan-y;
}
.shared-media-fullscreen .yearly-player { min-height: 0; }
.shared-media-fullscreen .image-pan { padding: 8px 0 58px; }
.shared-media-fullscreen .image-tools { bottom: 8px; background: #252525e8; padding: 0 5px; }
.shared-media-fullscreen .image-tools button { width: 44px; height: 44px; }
.shared-media-fullscreen .image-gesture-hint { display: none; }
.shared-media-fullscreen .shared-live-toggle {
  flex-shrink: 0;
  align-self: center;
  margin: 4px;
  min-height: 44px;
  color: #fff;
  background: #ffffff12;
  border-color: #ffffff25;
}
</style>
