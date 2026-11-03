<script setup lang="ts">
import { ref, computed, watch, onMounted, onBeforeUnmount } from "vue";
import { useRoute, useRouter } from "vue-router";
import {
  ArrowUpRight,
  Plus,
  Upload,
  CalendarDays,
  LayoutGrid,
  CheckSquare,
  Search,
  SlidersHorizontal,
  BookHeart,
  X,
  Users,
  RotateCcw,
  ChevronDown,
  MousePointer2,
  Leaf,
} from "lucide-vue-next";
import { api, post, notify, localDate } from "../lib/api";
import { useYearly } from "../stores/yearly";
import ChildPicker from "../components/ChildPicker.vue";
import EmptyState from "../components/EmptyState.vue";
import MediaCard from "../components/MediaCard.vue";
import MediaDetail from "../components/MediaDetail.vue";
import EventEditor from "../components/EventEditor.vue";
import EventCover from "../components/EventCover.vue";
const yearly = useYearly(),
  route = useRoute(),
  router = useRouter();
const nextCursor = ref<string | null>(null);
const items = ref<any[]>([]),
  events = ref<any[]>([]),
  total = ref(0),
  page = ref(1),
  loading = ref(false),
  error = ref(""),
  selection = ref(false),
  selected = ref<number[]>([]),
  detail = ref<number | null>(null),
  eventOpen = ref(false),
  eventId = ref<number | null>(null),
  eventDate = ref("");
const q = ref(""),
  type = ref(""),
  year = ref(""),
  month = ref(""),
  day = ref(""),
  match = ref("any"),
  view = ref("calendar"),
  stages = ref([
    { label: "0～1 个月", start: 0, end: 1 },
    { label: "1～3 个月", start: 1, end: 3 },
    { label: "3～6 个月", start: 3, end: 6 },
    { label: "6～12 个月", start: 6, end: 12 },
    { label: "1～2 岁", start: 12, end: 24 },
    { label: "2～3 岁", start: 24, end: 36 },
  ]),
  stage = ref(-1),
  markers = ref<any[]>([]),
  batchOpen = ref(false),
  batchKids = ref<number[]>([]),
  batchMode = ref("add"),
  stageDialog = ref(false);
const grid = ref<HTMLElement>(),
  rect = ref<any>(null),
  anchor = ref(0),
  dragEnabled = ref(false),
  sentinel = ref<HTMLElement>();
let dragStart: any = null,
  observer: IntersectionObserver,
  searchTimer: ReturnType<typeof setTimeout>,
  generation = 0;
const trash = computed(() => !!route.meta.trash);
const activeChild = computed(() =>
  yearly.selected.length === 1
    ? yearly.children.find((c) => c.id === yearly.selected[0])
    : null,
);
const groups = computed(() => {
  const map = new Map<string, any[]>();
  for (const item of items.value) {
    const key = (item.taken_at_local || "unknown").slice(0, 10);
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(item);
  }
  return [...map].map(([date, media]) => ({ date, media }));
});
function calendarMonth(birth: string, months: number) {
  const [y, m, d] = birth.split("-").map(Number);
  const value = new Date(y, m - 1 + months, 1, 12);
  const last = new Date(value.getFullYear(), value.getMonth() + 1, 0).getDate();
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(Math.min(d, last)).padStart(2, "0")}T00:00:00`;
}
function range() {
  if (view.value === "age" && activeChild.value && stage.value >= 0) {
    const s = stages.value[stage.value];
    return {
      start: calendarMonth(activeChild.value.birthday, s.start),
      end: calendarMonth(activeChild.value.birthday, s.end),
    };
  }
  if (day.value) {
    const next = new Date(day.value + "T12:00:00");
    next.setDate(next.getDate() + 1);
    return {
      start: day.value + "T00:00:00",
      end: `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, "0")}-${String(next.getDate()).padStart(2, "0")}T00:00:00`,
    };
  }
  if (year.value) {
    const m = +(month.value || 1);
    return {
      start: `${year.value}-${String(m).padStart(2, "0")}-01T00:00:00`,
      end: month.value
        ? `${m === 12 ? +year.value + 1 : year.value}-${String(m === 12 ? 1 : m + 1).padStart(2, "0")}-01T00:00:00`
        : `${+year.value + 1}-01-01T00:00:00`,
    };
  }
  return {};
}
async function load(reset = true) {
  const ticket = ++generation;
  if (reset) {
    page.value = 1;
    items.value = [];
    nextCursor.value = null;
  }
  loading.value = true;
  error.value = "";
  try {
    const params = new URLSearchParams({
      page: String(page.value),
      page_size: "40",
      match: match.value,
      status: trash.value ? "deleted" : "active",
      q: q.value,
    });
    if (!reset && nextCursor.value) params.set("cursor", nextCursor.value);
    yearly.selected.forEach((id) => params.append("child_id", String(id)));
    if (type.value) params.set("media_type", type.value);
    Object.entries(range()).forEach(([k, v]) => params.set(k, v!));
    const data = await api("/timeline?" + params);
    if (ticket !== generation) return;
    items.value = reset ? data.items : [...items.value, ...data.items];
    total.value = data.total;
    nextCursor.value = data.next_cursor;
  } catch (e) {
    if (ticket === generation) {
      error.value = e instanceof Error ? e.message : "加载失败";
    }
  } finally {
    if (ticket === generation) loading.value = false;
  }
}
async function next() {
  if (loading.value || !nextCursor.value) return;
  page.value++;
  await load(false);
}
watch(
  [
    () => yearly.selected,
    year,
    month,
    day,
    type,
    match,
    view,
    stage,
    () => route.path,
  ],
  () => {
    selected.value = [];
    load();
    loadMarkers();
  },
  { deep: true },
);
watch(q, () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => load(), 350);
});
async function loadMarkers() {
  if (activeChild.value) {
    try {
      markers.value = await api(`/children/${activeChild.value.id}/milestones`);
    } catch (e) {
      notify(e);
    }
  } else markers.value = [];
}
onMounted(() => {
  try {
    const saved = localStorage.getItem("yearly-age-stages");
    if (saved) stages.value = JSON.parse(saved);
  } catch {}
  load();
  loadMarkers();
  observer = new IntersectionObserver(
    (entries) => {
      if (entries[0].isIntersecting) next();
    },
    { rootMargin: "200px" },
  );
  if (sentinel.value) observer.observe(sentinel.value);
  window.addEventListener("pointerup", endDrag);
});
onBeforeUnmount(() => {
  observer?.disconnect();
  clearTimeout(searchTimer);
  window.removeEventListener("pointerup", endDrag);
});
function toggle(m: any, shift = false) {
  const index = items.value.findIndex(
    (x) => x.kind === "media" && x.id === m.id,
  );
  if (shift) {
    const ids = items.value
      .slice(Math.min(anchor.value, index), Math.max(anchor.value, index) + 1)
      .filter((x) => x.kind === "media")
      .map((x) => x.id);
    selected.value = [...new Set([...selected.value, ...ids])];
  } else
    selected.value = selected.value.includes(m.id)
      ? selected.value.filter((id) => id !== m.id)
      : [...selected.value, m.id];
  anchor.value = index;
}
function longpress(m: any) {
  selection.value = true;
  if (!selected.value.includes(m.id)) selected.value.push(m.id);
}
function startDrag(e: PointerEvent) {
  if (!selection.value || !dragEnabled.value || e.pointerType !== "mouse")
    return;
  e.preventDefault();
  dragStart = {
    x: e.clientX,
    y: e.clientY,
    base: e.ctrlKey ? [...selected.value] : [],
  };
  rect.value = { left: e.clientX, top: e.clientY, width: 0, height: 0 };
}
function moveDrag(e: PointerEvent) {
  if (!dragStart || !grid.value) return;
  const r = {
    left: Math.min(e.clientX, dragStart.x),
    top: Math.min(e.clientY, dragStart.y),
    width: Math.abs(e.clientX - dragStart.x),
    height: Math.abs(e.clientY - dragStart.y),
  };
  rect.value = r;
  const ids: number[] = [];
  grid.value.querySelectorAll("[data-media-id]").forEach((el) => {
    const b = el.getBoundingClientRect();
    if (
      b.right > r.left &&
      b.left < r.left + r.width &&
      b.bottom > r.top &&
      b.top < r.top + r.height
    )
      ids.push(Number((el as HTMLElement).dataset.mediaId));
  });
  selected.value = [...new Set([...dragStart.base, ...ids])];
}
function endDrag() {
  dragStart = null;
  setTimeout(() => (rect.value = null), 0);
}
function openMedia(m: any) {
  if (dragEnabled.value && selection.value) return;
  if (!trash.value) detail.value = m.id;
}
function newEvent() {
  eventId.value = null;
  eventDate.value = "";
  eventOpen.value = true;
}
async function batch() {
  try {
    await post("/media/batch-children", {
      media_ids: selected.value,
      child_ids: batchKids.value,
      mode: batchMode.value,
    });
    batchOpen.value = false;
    selected.value = [];
    await load();
  } catch (e) {
    notify(e);
  }
}
async function restore(id: number, kind = "media") {
  try {
    await post(`/${kind === "event" ? "events" : "media"}/${id}/restore`);
    await yearly.load();
    load();
  } catch (e) {
    notify(e);
  }
}
function jump(marker: any) {
  day.value = marker.date;
  view.value = "calendar";
}
function saveStages() {
  if (stages.value.some((s) => s.start < 0 || s.end <= s.start)) {
    notify(new Error("年龄阶段结束月龄需大于开始月龄"));
    return;
  }
  localStorage.setItem("yearly-age-stages", JSON.stringify(stages.value));
  stage.value = -1;
  stageDialog.value = false;
}
</script>
<template>
  <div class="timeline-page">
    <div class="page-heading">
      <div>
        <span class="eyebrow">OUR FAMILY, FRAME BY FRAME</span>
        <h1>
          {{
            trash
              ? "留一点反悔的余地"
              : activeChild
                ? `${activeChild.nickname || activeChild.name}的成长时光`
                : "把日子，慢慢收藏。"
          }}<span class="heading-leaf"><Leaf :size="24" /></span>
        </h1>
        <p>
          {{
            trash
              ? "这里的回忆可以恢复，原文件会继续安全保存。"
              : "每一个平凡的瞬间，都是长大后最珍贵的礼物。"
          }}
        </p>
      </div>
      <RouterLink
        v-if="yearly.canEdit && !trash"
        to="/upload"
        class="button primary"
        ><Plus :size="18" />珍藏新回忆</RouterLink
      >
    </div>
    <div v-if="!trash" class="memory-summary">
      <div>
        <span class="summary-icon sage"><LayoutGrid :size="21" /></span
        ><span
          ><b>{{ yearly.stats.media }}</b
          ><small>珍藏的瞬间</small></span
        >
      </div>
      <div>
        <span class="summary-icon peach"><BookHeart :size="21" /></span
        ><span
          ><b>{{ yearly.stats.events }}</b
          ><small>写下的成长故事</small></span
        >
      </div>
      <div>
        <span class="summary-icon sand"><Users :size="21" /></span
        ><span
          ><b>{{ yearly.stats.children }}</b
          ><small>正在长大的小小人</small></span
        >
      </div>
      <p>时光会走远<br /><em>回忆会留下。</em></p>
    </div>
    <div class="timeline-controls">
      <div class="child-filter">
        <ChildPicker v-model="yearly.selected" all
          ><RouterLink
            v-if="yearly.canEdit"
            to="/children"
            class="add-child-link"
            ><Plus :size="15" />添加孩子</RouterLink
          ></ChildPicker
        ><select
          v-if="yearly.selected.length > 1"
          v-model="match"
          class="compact-select"
          aria-label="多孩子匹配方式"
        >
          <option value="any">包含任意孩子</option>
          <option value="all">同时包含全部孩子</option>
        </select>
      </div>
      <div class="view-bar">
        <div class="view-tabs">
          <button
            :class="{ active: view === 'calendar' }"
            @click="view = 'calendar'"
          >
            <CalendarDays :size="15" />按日历</button
          ><button
            :class="{ active: view === 'age' }"
            :disabled="!activeChild"
            title="选择一个孩子后浏览年龄阶段"
            @click="view = 'age'"
          >
            按年龄
          </button>
        </div>
        <div class="filter-tools">
          <div class="search-box">
            <Search :size="16" /><input
              v-model="q"
              placeholder="搜索标题、备注、地点"
              aria-label="搜索回忆"
            />
          </div>
          <select v-model="type" class="compact-select" aria-label="媒体类型">
            <option value="">全部类型</option>
            <option value="photo">照片</option>
            <option value="video">视频</option>
            <option value="live_photo">Live Photo</option></select
          ><button
            v-if="yearly.canEdit && !trash"
            class="button small"
            :class="{ pressed: selection }"
            @click="
              selection = !selection;
              selected = [];
              dragEnabled = false;
            "
          >
            <CheckSquare :size="15" />多选
          </button>
        </div>
      </div>
      <div class="date-filters" v-if="view === 'calendar'">
        <label
          >年份<input
            v-model="year"
            type="number"
            placeholder="全部年份"
            min="1900"
            max="2200" /></label
        ><label
          >月份<select v-model="month" :disabled="!year">
            <option value="">全年</option>
            <option v-for="n in 12" :key="n" :value="String(n)">
              {{ n }} 月
            </option>
          </select></label
        ><label>某一天<input v-model="day" type="date" /></label
        ><button
          v-if="year || day"
          class="text-button"
          @click="
            year = '';
            month = '';
            day = '';
          "
        >
          清除日期</button
        ><span class="result-count">{{ total }} 条记录 · 按拍摄时间排列</span>
      </div>
      <div v-else class="age-stage-list">
        <button
          class="chip"
          :class="{ active: stage === -1 }"
          @click="stage = -1"
        >
          全部年龄</button
        ><button
          v-for="(s, i) in stages"
          :key="i"
          class="chip"
          :class="{ active: stage === i }"
          @click="stage = i"
        >
          {{ s.label }}</button
        ><button class="text-button" @click="stageDialog = true">
          设置阶段
        </button>
      </div>
    </div>
    <div v-if="activeChild && markers.length && !trash" class="milestone-bar">
      <span>成长足迹</span
      ><button v-for="m in markers" :key="m.title" @click="jump(m)">
        {{ m.title }}<small>{{ localDate(m.date) }}</small></button
      ><button
        v-if="yearly.canEdit"
        @click="
          eventId = null;
          eventDate = day ? day + 'T00:00' : '';
          eventOpen = true;
        "
      >
        ＋ 写下里程碑
      </button>
    </div>
    <div v-if="selection" class="selection-toolbar">
      <span
        >已选 <b>{{ selected.length }}</b> 份回忆</span
      ><button
        class="text-button"
        @click="
          selected = items.filter((m) => m.kind === 'media').map((m) => m.id)
        "
      >
        选择已加载影像</button
      ><button
        class="button small desktop-only"
        :class="{ pressed: dragEnabled }"
        @click="dragEnabled = !dragEnabled"
      >
        <MousePointer2 :size="14" />框选模式</button
      ><button
        class="button small"
        :disabled="!selected.length"
        @click="
          batchKids = [];
          batchOpen = true;
        "
      >
        关联孩子</button
      ><button
        class="button primary small"
        :disabled="!selected.length"
        @click="newEvent"
      >
        <BookHeart :size="14" />创建成长日记</button
      ><button
        class="icon-button"
        aria-label="退出多选"
        @click="
          selection = false;
          selected = [];
        "
      >
        <X :size="17" />
      </button>
    </div>
    <div v-if="error" class="error-panel">
      <h3>暂时没能翻开回忆</h3>
      <p>{{ error }}</p>
      <button class="button" @click="load()">重新加载</button>
    </div>
    <div
      v-else
      ref="grid"
      class="timeline-content"
      :class="{ 'drag-mode': dragEnabled }"
      @pointerdown="startDrag"
      @pointermove="moveDrag"
    >
      <div v-for="group in groups" :key="group.date" class="day-group">
        <div class="date-heading">
          <span class="date-dot"></span>
          <h2>
            {{
              group.date === "unknown" ? "拍摄时间未知" : localDate(group.date)
            }}
          </h2>
          <span>{{ group.media.length }} 条记录</span>
          <div class="date-rule"></div>
        </div>
        <div class="media-grid">
          <div v-for="m in group.media" :key="m.kind + '-' + m.id">
            <button
              v-if="m.kind === 'event'"
              class="timeline-diary"
              @click="!trash && ((eventId = m.id), (eventOpen = true))"
            >
              <EventCover :media-id="m.cover_media_id" /><BookHeart
                :size="27"
                stroke-width="1.3"
              /><span class="eyebrow">成长日记</span>
              <h3>{{ m.title }}</h3>
              <p>{{ m.content }}</p>
              <small
                >{{ localDate(m.start_at)
                }}<template v-if="m.end_at">
                  — {{ localDate(m.end_at) }}</template
                ></small
              >
              <div class="age-labels">
                <span v-for="c in m.children" :key="c.id"
                  >{{ c.name }} · {{ c.age_start || "年龄未知"
                  }}<template v-if="c.age_end && c.age_end !== c.age_start">
                    ～ {{ c.age_end }}</template
                  ></span
                >
              </div>
              <small
                >{{ m.media_ids.length }} 份回忆 · 全部事件媒体</small
              ></button
            ><MediaCard
              v-else
              :media="m"
              :selection="selection"
              :selected="selected.includes(m.id)"
              @open="openMedia"
              @select="toggle"
              @longpress="longpress"
            /><button
              v-if="trash && yearly.canEdit"
              class="button small restore-button"
              @click="restore(m.id, m.kind)"
            >
              <RotateCcw :size="14" />恢复这份回忆
            </button>
          </div>
        </div>
      </div>
      <div v-if="loading" class="media-grid loading-grid">
        <div v-for="i in 4" :key="i" class="loading-card skeleton"></div>
      </div>
      <EmptyState
        v-if="!items.length && !loading"
        :title="
          trash
            ? '回收站空空的'
            : q || yearly.selected.length || year || day || type
              ? '还没有符合条件的回忆'
              : undefined
        "
        :description="
          trash
            ? '每一份回忆，都在好好收藏。'
            : q || yearly.selected.length || year || day || type
              ? '换个筛选条件，或为这个孩子上传新的成长影像。'
              : undefined
        "
        ><RouterLink
          v-if="yearly.canEdit && !trash"
          to="/upload"
          class="button primary"
          ><Upload :size="16" />上传第一份回忆</RouterLink
        ><span v-if="!trash" class="empty-footnote"
          >照片、视频、Live Photo · 原文件无损珍藏</span
        ></EmptyState
      >
    </div>
    <div ref="sentinel" class="load-more">
      <button v-if="nextCursor && !loading" class="button" @click="next">
        加载更多回忆</button
      ><span v-else-if="items.length && !loading">— 这些日子，都在这里 —</span>
    </div>
    <div
      v-if="rect"
      class="selection-rect"
      :style="{
        left: rect.left + 'px',
        top: rect.top + 'px',
        width: rect.width + 'px',
        height: rect.height + 'px',
      }"
    ></div>
    <MediaDetail
      :id="detail"
      @close="detail = null"
      @saved="
        load();
        yearly.load();
      "
    /><EventEditor
      :open="eventOpen"
      :event-id="eventId"
      :media-ids="selected"
      :initial-date="eventDate"
      @close="eventOpen = false"
      @saved="
        selected = [];
        selection = false;
        load();
      "
    />
    <ElDialog v-model="batchOpen" title="批量关联孩子" width="540px"
      ><p class="muted">
        将调整已选 {{ selected.length }} 份回忆的关联，原文件保持独立保存。
      </p>
      <label
        >操作方式<select v-model="batchMode">
          <option value="add">追加关联</option>
          <option value="remove">解除选中的孩子关联</option>
          <option value="replace">替换为所选孩子（可清空）</option>
        </select></label
      ><ChildPicker v-model="batchKids" />
      <div class="dialog-actions">
        <button class="button primary" @click="batch">保存关联</button>
      </div></ElDialog
    >
    <ElDialog v-model="stageDialog" title="自定义年龄阶段" width="600px"
      ><p class="muted">按真实日历月龄筛选，结束月龄不包含在本阶段内。</p>
      <div v-for="(s, i) in stages" :key="i" class="stage-row">
        <input v-model="s.label" aria-label="阶段名称" /><input
          type="number"
          v-model.number="s.start"
          min="0"
          aria-label="开始月龄"
        /><span>～</span
        ><input
          type="number"
          v-model.number="s.end"
          min="1"
          aria-label="结束月龄"
        /><button class="icon-button" @click="stages.splice(i, 1)">
          <X :size="15" />
        </button>
      </div>
      <button
        class="text-button"
        @click="stages.push({ label: '新的阶段', start: 36, end: 48 })"
      >
        ＋ 添加阶段
      </button>
      <div class="dialog-actions">
        <button class="button primary" @click="saveStages">保存阶段</button>
      </div></ElDialog
    >
  </div>
</template>
