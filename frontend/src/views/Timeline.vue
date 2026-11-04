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
  GripVertical,
  ArrowLeft,
  ArrowRight,
  FolderInput,
  Pencil,
  Folder,
} from "lucide-vue-next";
import { api, post, notify, localDate } from "../lib/api";
import { useYearly } from "../stores/yearly";
import ChildPicker from "../components/ChildPicker.vue";
import EmptyState from "../components/EmptyState.vue";
import MediaCard from "../components/MediaCard.vue";
import MediaDetail from "../components/MediaDetail.vue";
import EventEditor from "../components/EventEditor.vue";
import EventCover from "../components/EventCover.vue";
import FolderPanel from "../components/FolderPanel.vue";
import FolderMoveDialog from "../components/FolderMoveDialog.vue";
const yearly = useYearly(),
  route = useRoute(),
  router = useRouter();
const nextCursor = ref<string | null>(null);
const folderId = ref<number | null>(null),
  folderCreate = ref(false),
  folderName = ref(""),
  folderDay = ref(""),
  folderBusy = ref(false),
  folderMoving = ref(false),
  folderMoveDay = ref(""),
  folderDrag = ref<number | null>(null),
  dragDay = ref(""),
  dragFromFolder = ref<number | null>(null),
  dropFolder = ref<number | null>(null);
function newFolder(date: string) {
  folderDay.value = date;
  folderName.value = "";
  folderCreate.value = true;
}
async function saveFolder() {
  folderBusy.value = true;
  try {
    await post("/folders", {
      name: folderName.value.trim(),
      timeline_date: folderDay.value,
    });
    folderCreate.value = false;
    await load(true, true);
  } catch (e) {
    notify(e);
  } finally {
    folderBusy.value = false;
  }
}
function moveIntoFolder() {
  const dates = new Set(
    items.value
      .filter((m) => m.kind === "media" && selected.value.includes(m.id))
      .map((m) => m.timeline_day),
  );
  if (dates.size !== 1 || ![...dates][0]) {
    notify(new Error("请先选择同一天且日期已知的影像"));
    return;
  }
  folderMoveDay.value = [...dates][0];
  folderMoving.value = true;
}
const items = ref<any[]>([]),
  total = ref(0),
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
  day = ref(typeof route.query.day === "string" ? route.query.day : ""),
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
const sortDate = ref(""),
  orderSaving = ref(false),
  draggedIds = ref<number[]>([]),
  dropTarget = ref<{
    id: number;
    kind: "media" | "folder";
    placement: "before" | "after";
  } | null>(null),
  organizeOpen = ref(false),
  organizeAction = ref<"name" | "date">("name"),
  organizeName = ref(""),
  organizeDate = ref(""),
  resetDate = ref(false),
  organizeSaving = ref(false),
  dateDialog = ref(false),
  newDate = ref("");
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
    const key =
      item.timeline_day || (item.taken_at_local || "unknown").slice(0, 10);
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(item);
  }
  return [...map].map(([date, media]) => ({
    date,
    media,
    files: media.filter((item) => item.kind === "media"),
    folders: media.filter((item) => item.kind === "folder"),
    orderable: media.filter(
      (item) => item.kind === "folder" || item.kind === "media",
    ),
  }));
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
async function load(reset = true, preserveLoaded = false) {
  const ticket = ++generation;
  const targetCount =
    reset && preserveLoaded ? Math.max(items.value.length, 40) : 40;
  loading.value = true;
  error.value = "";
  try {
    const params = new URLSearchParams({
      page_size: "40",
      match: match.value,
      status: trash.value ? "deleted" : "active",
      q: q.value,
      group_folders:
        view.value === "calendar" && !trash.value ? "true" : "false",
    });
    yearly.selected.forEach((id) => params.append("child_id", String(id)));
    if (type.value) params.set("media_type", type.value);
    if (view.value === "age") params.set("date_basis", "capture");
    Object.entries(range()).forEach(([k, v]) => params.set(k, v!));
    const loaded: any[] = [];
    let cursor = reset ? null : nextCursor.value;
    let result: any;
    do {
      if (cursor) params.set("cursor", cursor);
      else params.delete("cursor");
      params.set("page", "1");
      result = await api("/timeline?" + params);
      if (ticket !== generation) return;
      loaded.push(...result.items);
      cursor = result.next_cursor;
    } while (cursor && loaded.length < targetCount);
    items.value = reset ? loaded : [...items.value, ...loaded];
    total.value = result.total;
    nextCursor.value = cursor;
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
    sortDate.value = "";
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
  grid.value
    .querySelectorAll(".timeline-entry > [data-media-id]")
    .forEach((el) => {
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
  if (sortDate.value || (dragEnabled.value && selection.value)) return;
  if (!trash.value) detail.value = m.id;
}
function newEvent() {
  eventId.value = null;
  eventDate.value = "";
  eventOpen.value = true;
}
function appendToDate(date: string) {
  router.push({ path: "/upload", query: { date } });
}
function selectDay(group: any) {
  selection.value = true;
  const ids = group.media
    .filter((m: any) => m.kind === "media")
    .map((m: any) => m.id);
  if (ids.every((id: number) => selected.value.includes(id)))
    selected.value = selected.value.filter((id) => !ids.includes(id));
  else selected.value = [...new Set([...selected.value, ...ids])];
}
function startSort(date: string) {
  sortDate.value = sortDate.value === date ? "" : date;
  dragEnabled.value = false;
}
function startOrderDrag(event: DragEvent, media: any, group: any) {
  if (
    !yearly.canEdit ||
    trash.value ||
    view.value !== "calendar" ||
    orderSaving.value ||
    dragEnabled.value ||
    media.kind === "event"
  ) {
    event.preventDefault();
    return;
  }
  dragFromFolder.value = media.folder_id || null;
  dragDay.value = group.date;
  folderDrag.value = media.kind === "folder" ? media.id : null;
  draggedIds.value =
    media.kind === "folder"
      ? []
      : selected.value.includes(media.id)
        ? group.files
            .filter((m: any) => selected.value.includes(m.id))
            .map((m: any) => m.id)
        : [media.id];
  if (event.dataTransfer) {
    event.dataTransfer.setData("text/plain", String(media.id));
    event.dataTransfer.effectAllowed = "move";
  }
}
function dragOver(event: DragEvent, media: any, group: any) {
  dropFolder.value = null;
  dropTarget.value = null;
  if (
    orderSaving.value ||
    dragDay.value !== group.date ||
    media.kind === "event"
  )
    return;
  if (!folderDrag.value && !draggedIds.value.length) return;
  if (
    (media.kind === "folder" && media.id === folderDrag.value) ||
    (media.kind === "media" && draggedIds.value.includes(media.id))
  )
    return;
  const bounds = (event.currentTarget as HTMLElement).getBoundingClientRect();
  const position = bounds.width
    ? (event.clientX - bounds.left) / bounds.width
    : 0.5;
  if (
    media.kind === "folder" &&
    draggedIds.value.length &&
    position > 0.25 &&
    position < 0.75
  ) {
    if (media.id === dragFromFolder.value) return;
    event.preventDefault();
    dropFolder.value = media.id;
    return;
  }
  event.preventDefault();
  dropTarget.value = {
    id: media.id,
    kind: media.kind,
    placement: position < 0.5 ? "before" : "after",
  };
}
async function restoreDayOrder(date: string) {
  orderSaving.value = true;
  try {
    await post("/media/reset-order", { day: date === "unknown" ? null : date });
    await load(true, true);
  } catch (e) {
    notify(e);
  } finally {
    orderSaving.value = false;
  }
}
async function saveOrder(
  moving: { id: number; kind: "media" | "folder" }[],
  target: { id: number; kind: "media" | "folder" },
  placement: "before" | "after",
  moveOut = false,
) {
  if (orderSaving.value) return;
  orderSaving.value = true;
  try {
    if (moveOut)
      await post("/folders/move-media", {
        media_ids: moving.map((item) => item.id),
        folder_id: null,
      });
    await post("/timeline/reorder", { items: moving, target, placement });
    await load(true, true);
  } catch (e) {
    notify(e);
  } finally {
    orderSaving.value = false;
  }
}
async function dropOrder(media: any, group: any) {
  if (orderSaving.value || dragDay.value !== group.date) return;
  if (
    draggedIds.value.length &&
    media.kind === "folder" &&
    dropFolder.value === media.id
  ) {
    const ids = [...draggedIds.value];
    dropFolder.value = null;
    draggedIds.value = [];
    orderSaving.value = true;
    try {
      await post("/folders/move-media", {
        media_ids: ids,
        folder_id: media.id,
      });
      selected.value = selected.value.filter((id) => !ids.includes(id));
      await load(true, true);
    } catch (e) {
      notify(e);
    } finally {
      orderSaving.value = false;
    }
    return;
  }
  if (
    !dropTarget.value ||
    dropTarget.value.id !== media.id ||
    dropTarget.value.kind !== media.kind
  )
    return;
  const { id, kind, placement } = dropTarget.value;
  const moving: { id: number; kind: "media" | "folder" }[] = folderDrag.value
    ? [{ id: folderDrag.value, kind: "folder" }]
    : draggedIds.value.map((id) => ({ id, kind: "media" }));
  const moveOut = !!dragFromFolder.value;
  dropTarget.value = null;
  folderDrag.value = null;
  draggedIds.value = [];
  await saveOrder(moving, { id, kind }, placement, moveOut);
}
async function dropToDay(date: string) {
  if (!dragFromFolder.value || dragDay.value !== date || orderSaving.value)
    return;
  const ids = [...draggedIds.value];
  draggedIds.value = [];
  dragFromFolder.value = null;
  orderSaving.value = true;
  try {
    await post("/folders/move-media", { media_ids: ids, folder_id: null });
    await load(true, true);
  } catch (e) {
    notify(e);
  } finally {
    orderSaving.value = false;
  }
}
function moveOne(media: any, group: any, direction: number) {
  const entries = group.orderable;
  const index = entries.findIndex(
    (m: any) => m.id === media.id && m.kind === media.kind,
  );
  const target = entries[index + direction];
  if (target)
    saveOrder(
      [{ id: media.id, kind: media.kind }],
      { id: target.id, kind: target.kind },
      direction < 0 ? "before" : "after",
    );
}
function openOrganize(action: "name" | "date") {
  organizeAction.value = action;
  organizeName.value = "";
  organizeDate.value = "";
  resetDate.value = false;
  organizeOpen.value = true;
}
async function saveOrganization() {
  organizeSaving.value = true;
  try {
    await post("/media/batch-organize", {
      media_ids: selected.value,
      ...(organizeAction.value === "name"
        ? { batch_name: organizeName.value.trim() }
        : { timeline_date: resetDate.value ? null : organizeDate.value }),
    });
    organizeOpen.value = false;
    selected.value = [];
    await load(true, true);
  } catch (e) {
    notify(e);
  } finally {
    organizeSaving.value = false;
  }
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
      <div v-if="yearly.canEdit && !trash" class="timeline-heading-actions">
        <button class="button" @click="dateDialog = true">
          <CalendarDays :size="16" />添加日期
        </button>
        <RouterLink to="/upload" class="button primary"
          ><Plus :size="18" />珍藏新回忆</RouterLink
        >
      </div>
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
              placeholder="搜索批次、标题、地点"
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
        ><span class="result-count">{{ total }} 条记录 · 按天归档</span>
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
        @click="
          sortDate = '';
          dragEnabled = !dragEnabled;
        "
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
        class="button small"
        :disabled="!selected.length"
        @click="openOrganize('name')"
      >
        <Pencil :size="14" />批量命名</button
      ><button
        class="button small"
        :disabled="!selected.length"
        @click="moveIntoFolder"
      >
        <Folder :size="14" />移入文件夹</button
      ><button
        class="button small"
        :disabled="!selected.length"
        @click="openOrganize('date')"
      >
        <FolderInput :size="14" />调整日期</button
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
          <div v-if="yearly.canEdit && !trash" class="day-actions">
            <button
              v-if="group.date !== 'unknown'"
              class="button small"
              @click="appendToDate(group.date)"
            >
              <Plus :size="14" />追加
            </button>
            <button
              class="text-button"
              :disabled="!group.files.length"
              title="选择本日已加载的照片与视频"
              @click="selectDay(group)"
            >
              选本组
            </button>
            <button
              v-if="group.date !== 'unknown'"
              class="text-button"
              @click="newFolder(group.date)"
            >
              <Folder :size="14" />新建文件夹
            </button>
            <button
              class="text-button"
              :disabled="
                orderSaving || (!group.files.length && !group.folders.length)
              "
              @click="startSort(group.date)"
            >
              <GripVertical :size="14" />{{
                sortDate === group.date ? "完成排序" : "排序"
              }}
            </button>
            <ElPopconfirm
              :width="280"
              title="恢复本日默认排序：文件夹置前，全部影像（含文件夹内）按拍摄时间从新到旧排列。其他日期不受影响。"
              confirm-button-text="恢复排序"
              cancel-button-text="取消"
              @confirm="restoreDayOrder(group.date)"
              ><template #reference
                ><button
                  class="text-button"
                  :disabled="orderSaving"
                  title="恢复本日全部影像的拍摄时间排序"
                >
                  <RotateCcw :size="14" />恢复默认排序
                </button></template
              ></ElPopconfirm
            >
          </div>
        </div>
        <p v-if="sortDate === group.date" class="sort-instructions">
          {{
            orderSaving
              ? "正在保存顺序…"
              : "文件夹与影像可自由混排；拖到卡片左右两侧插入排序，拖到文件夹中间移入。多选影像可一起拖动。"
          }}
        </p>
        <div
          v-if="dragFromFolder && dragDay === group.date && draggedIds.length"
          class="day-drop-out"
          @dragover.prevent
          @drop.prevent.stop="dropToDay(group.date)"
        >
          松开移回当天时间线
        </div>
        <div class="media-grid">
          <div
            v-for="m in group.media"
            :key="m.kind + '-' + m.id"
            class="timeline-entry"
            :class="{
              'sortable-entry':
                yearly.canEdit &&
                !trash &&
                view === 'calendar' &&
                !dragEnabled &&
                m.kind !== 'event',
              'drop-into-folder': m.kind === 'folder' && dropFolder === m.id,
              'drop-before':
                dropTarget?.kind === m.kind &&
                dropTarget?.id === m.id &&
                dropTarget?.placement === 'before',
              'drop-after':
                dropTarget?.kind === m.kind &&
                dropTarget?.id === m.id &&
                dropTarget?.placement === 'after',
            }"
            :draggable="
              yearly.canEdit &&
              !trash &&
              view === 'calendar' &&
              !dragEnabled &&
              m.kind !== 'event' &&
              !orderSaving
            "
            @dragstart="startOrderDrag($event, m, group)"
            @dragover="dragOver($event, m, group)"
            @dragleave="
              if (
                !($event.currentTarget as HTMLElement).contains(
                  $event.relatedTarget as Node,
                )
              ) {
                dropFolder = null;
                dropTarget = null;
              }
            "
            @drop.prevent="dropOrder(m, group)"
            @dragend="
              folderDrag = null;
              dragFromFolder = null;
              dragDay = '';
              dropFolder = null;
              draggedIds = [];
              dropTarget = null;
            "
          >
            <div
              v-if="sortDate === group.date && m.kind !== 'event'"
              class="sort-entry-tools"
            >
              <GripVertical :size="16" /><button
                class="text-button"
                :disabled="
                  orderSaving ||
                  (group.orderable[0]?.id === m.id &&
                    group.orderable[0]?.kind === m.kind)
                "
                @click="moveOne(m, group, -1)"
              >
                <ArrowLeft :size="13" />前移</button
              ><button
                class="text-button"
                :disabled="
                  orderSaving ||
                  (group.orderable.at(-1)?.id === m.id &&
                    group.orderable.at(-1)?.kind === m.kind)
                "
                @click="moveOne(m, group, 1)"
              >
                后移<ArrowRight :size="13" />
              </button>
            </div>
            <div
              v-if="m.kind === 'folder'"
              class="day-folder-card"
              role="button"
              tabindex="0"
              :aria-label="`打开文件夹 ${m.name}`"
              :title="
                dropFolder === m.id
                  ? `松开移入 ${draggedIds.length} 份影像`
                  : yearly.canEdit
                    ? '拖动标题排序；拖到两侧插入，中间移入影像'
                    : m.name
              "
              @click="folderId = m.id"
              @keydown.enter.self="folderId = m.id"
              @keydown.space.prevent.self="folderId = m.id"
            >
              <div class="folder-card-body media-visual">
                <div class="folder-card-heading">
                  <Folder :size="23" /><b>{{ m.name }}</b>
                  <span
                    v-if="yearly.canEdit"
                    class="folder-drag-handle"
                    title="拖动文件夹，可放在照片、视频之间"
                    ><GripVertical :size="15"
                  /></span>
                </div>
                <div v-if="m.previews?.length" class="folder-thumbnails">
                  <div
                    v-for="preview in m.previews"
                    :key="preview.id"
                    :draggable="yearly.canEdit && !orderSaving && !dragEnabled"
                    :aria-label="`拖动影像 ${preview.title || preview.id}`"
                    @dragstart.stop="
                      startOrderDrag(
                        $event,
                        { ...preview, kind: 'media' },
                        group,
                      )
                    "
                  >
                    <MediaCard :media="preview" thumbnail />
                  </div>
                </div>
                <div v-else class="folder-empty-preview">
                  <Folder :size="28" />
                </div>
              </div>
            </div>
            <button
              v-else-if="m.kind === 'event'"
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
        <div v-for="i in 4" :key="i" class="media-card" aria-hidden="true">
          <div class="media-visual skeleton"></div>
        </div>
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
            : yearly.selected.length && !q && !year && !day && !type
              ? '这个孩子还没有关联影像。可在“全部孩子”中多选已有影像后关联，也可以直接上传。'
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
    <FolderPanel
      :id="folderId"
      :match="match"
      @close="folderId = null"
      @changed="load(true, true)"
    />
    <FolderMoveDialog
      :open="folderMoving"
      :day="folderMoveDay"
      :ids="selected"
      @close="folderMoving = false"
      @saved="
        selected = [];
        load(true, true);
      "
    />
    <ElDialog v-model="folderCreate" title="新建当天文件夹" width="440px"
      ><form @submit.prevent="saveFolder">
        <p class="muted">{{ folderDay }} · 文件夹仅用于整理当天影像</p>
        <label
          >文件夹名称<input
            v-model="folderName"
            maxlength="255"
            placeholder="例如：出生纪念、家人合影"
        /></label>
        <div class="dialog-actions">
          <button
            class="button primary"
            :disabled="folderBusy || !folderName.trim()"
          >
            创建文件夹
          </button>
        </div>
      </form></ElDialog
    >
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
    <ElDialog v-model="dateDialog" title="添加一个时间节点" width="440px">
      <p class="muted">选择日期，再把这一天的回忆一起上传。</p>
      <label>时间节点日期<input v-model="newDate" type="date" /></label>
      <div class="dialog-actions">
        <button
          class="button primary"
          :disabled="!newDate"
          @click="appendToDate(newDate)"
        >
          选择这一天的文件
        </button>
      </div>
    </ElDialog>
    <ElDialog
      v-model="organizeOpen"
      :title="organizeAction === 'name' ? '给所选回忆命名' : '调整归档日期'"
      width="480px"
    >
      <p class="muted">将应用到已选的 {{ selected.length }} 份回忆。</p>
      <label v-if="organizeAction === 'name'"
        >批次名称<input
          v-model="organizeName"
          maxlength="255"
          placeholder="例如：满月纪念；留空可清除批次名"
      /></label>
      <template v-else
        ><label
          >归档日期<input
            v-model="organizeDate"
            type="date"
            :disabled="resetDate" /></label
        ><label class="checkbox-label"
          ><input
            v-model="resetDate"
            type="checkbox"
          />恢复按各文件的拍摄日期归档</label
        >
        <p class="muted">
          归档日期用于时间线分组，拍摄时间和原始元数据单独保留。
        </p></template
      >
      <div class="dialog-actions">
        <button
          class="button primary"
          :disabled="
            organizeSaving ||
            !selected.length ||
            (organizeAction === 'date' && !organizeDate && !resetDate)
          "
          @click="saveOrganization"
        >
          {{ organizeSaving ? "正在保存…" : "应用到所选回忆" }}
        </button>
      </div>
    </ElDialog>
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
<style scoped>
.folder-drag-handle {
  margin-left: auto;
  display: inline-flex;
  cursor: grab;
}
.sortable-entry .day-folder-card {
  cursor: grab;
}
.folder-card-heading {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 7px;
}
.folder-thumbnails {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 4px;
  width: 100%;
  padding: 8px 0;
}
.folder-thumbnails > div {
  cursor: grab;
  min-width: 0;
}
.folder-thumbnails :deep(.media-card) {
  border-radius: 5px;
}
.folder-empty-preview {
  height: 58px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.day-drop-out {
  padding: 16px;
  margin-bottom: 12px;
  border: 2px dashed var(--sage);
  border-radius: 10px;
  text-align: center;
  color: var(--sage);
  background: var(--sage-light);
}

.drop-into-folder .day-folder-card {
  border: 1px dashed var(--primary);
  background: color-mix(in srgb, var(--primary) 18%, var(--surface));
  box-shadow: 0 0 0 4px color-mix(in srgb, var(--primary) 12%, transparent);
}

.folder-card-body {
  padding: 10px;
  display: flex;
  flex-direction: column;
  justify-content: center;
  gap: 6px;
  background: transparent;
}
.day-folder-card {
  width: 100%;
  overflow: hidden;
  text-align: left;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: linear-gradient(
    135deg,
    var(--surface),
    color-mix(in srgb, var(--primary) 12%, var(--surface))
  );
  color: var(--text);
  cursor: pointer;
}
.day-folder-card svg {
  color: #87996b;
}
.day-folder-card b {
  font-size: 14px;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.folder-card-heading > svg {
  flex-shrink: 0;
}
.day-folder-card span {
  color: var(--muted);
  font-size: 12px;
}
.day-folder-card:hover {
  border-color: #87996b;
}

.timeline-heading-actions,
.day-actions {
  display: flex;
  align-items: center;
  gap: 12px;
}
.day-actions .text-button {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  white-space: nowrap;
}
.selection-toolbar {
  flex-wrap: wrap;
}
.media-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(155px, 1fr));
  gap: 12px;
  columns: auto;
  align-items: start;
}
.media-grid > div {
  margin-bottom: 0;
  min-width: 0;
}
.day-group {
  margin-bottom: 34px;
}
.sort-instructions {
  margin: -5px 0 16px;
  font-size: 12px;
  color: var(--sage);
}
.sortable-entry {
  cursor: grab;
  border-radius: 9px;
}
.sortable-entry :deep(.media-card:hover) {
  transform: none;
}
.sort-entry-tools {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px;
  background: var(--sage-light);
  color: var(--sage);
  border-radius: 8px 8px 0 0;
}
.sort-entry-tools button {
  display: flex;
  align-items: center;
  gap: 4px;
}
.drop-before {
  box-shadow: -4px 0 0 var(--sage);
}
.drop-after {
  box-shadow: 4px 0 0 var(--sage);
}
@media (max-width: 700px) {
  .timeline-heading-actions {
    flex-wrap: wrap;
    gap: 8px;
  }
  .timeline-heading-actions .button {
    padding: 9px 12px;
    font-size: 11px;
  }
  .media-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
  }
  .date-heading {
    flex-wrap: wrap;
    gap: 8px;
  }
  .date-rule {
    display: none;
  }
  .day-actions {
    margin-left: auto;
    gap: 10px;
  }
  .day-actions .button {
    padding: 5px 8px;
  }
  .day-actions .text-button {
    font-size: 10px;
  }
  .sort-entry-tools {
    padding: 7px 5px;
  }
  .sort-entry-tools > svg {
    display: none;
  }
  .sort-instructions {
    font-size: 11px;
    line-height: 1.7;
  }
}
</style>
