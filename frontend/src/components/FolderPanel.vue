<script setup lang="ts">
import { t } from "../lib/i18n";
import { ref, watch, computed } from "vue";
import { useRouter } from "vue-router";
import {
  FolderOpen,
  Plus,
  ArrowLeft,
  ArrowRight,
  GripVertical,
  FolderInput,
  Pencil,
  Trash2,
  RotateCcw,
} from "lucide-vue-next";
import { api, post, put, del, notify } from "../lib/api";
import { useYearly } from "../stores/yearly";
import MediaCard from "./MediaCard.vue";
import MediaDetail from "./MediaDetail.vue";
import FolderMoveDialog from "./FolderMoveDialog.vue";
const props = defineProps<{ id: number | null; match?: string }>(),
  emit = defineEmits(["close", "changed"]);
const yearly = useYearly(),
  router = useRouter();
const folder = ref<any>(),
  items = ref<any[]>([]),
  total = ref(0),
  page = ref(1),
  loading = ref(false),
  busy = ref(false),
  error = ref(""),
  selected = ref<number[]>([]),
  selection = ref(false),
  sorting = ref(false),
  dragged = ref<number | null>(null),
  movingOut = ref(false),
  detail = ref<number | null>(null),
  moving = ref(false),
  renaming = ref(false),
  name = ref(""),
  shareAllowed = ref(true);
const draggedMediaIds = computed(() =>
  dragged.value === null
    ? []
    : selected.value.includes(dragged.value)
      ? items.value
          .filter((m) => selected.value.includes(m.id))
          .map((m) => m.id)
      : [dragged.value],
);
async function resetOrder() {
  busy.value = true;
  try {
    await post("/media/reset-order", {
      day: folder.value.timeline_day,
      folder_id: props.id,
    });
    await load();
    emit("changed");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function dropOutside() {
  if (busy.value || !draggedMediaIds.value.length) return;
  const ids = [...draggedMediaIds.value];
  dragged.value = null;
  movingOut.value = false;
  busy.value = true;
  try {
    await post("/folders/move-media", { media_ids: ids, folder_id: null });
    await changed();
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
let generation = 0;
async function load(reset = true) {
  const id = props.id;
  if (!id) return;
  const ticket = ++generation;
  loading.value = true;
  error.value = "";
  try {
    const params = new URLSearchParams({
      folder_id: String(id),
      match: props.match || "any",
      page: String(reset ? 1 : page.value + 1),
      page_size: "40",
    });
    yearly.selected.forEach((cid) => params.append("child_id", String(cid)));
    const [f, data] = await Promise.all([
      api(`/folders/${id}`),
      api("/media?" + params),
    ]);
    if (ticket !== generation) return;
    folder.value = f;
    items.value = reset ? data.items : [...items.value, ...data.items];
    total.value = data.total;
    page.value = reset ? 1 : page.value + 1;
  } catch (e) {
    if (ticket === generation)
      error.value = e instanceof Error ? e.message : t("加载失败");
  } finally {
    if (ticket === generation) loading.value = false;
  }
}
watch(
  () => props.id,
  (id) => {
    generation++;
    folder.value = null;
    items.value = [];
    selected.value = [];
    selection.value = false;
    sorting.value = false;
    detail.value = null;
    moving.value = false;
    renaming.value = false;
    if (id) load();
  },
  { immediate: true },
);
function toggle(m: any) {
  selected.value = selected.value.includes(m.id)
    ? selected.value.filter((id) => id !== m.id)
    : [...selected.value, m.id];
}
async function rename() {
  busy.value = true;
  try {
    await put(`/folders/${props.id}`, {
      name: name.value.trim(),
      share_allowed: shareAllowed.value,
    });
    renaming.value = false;
    await load();
    emit("changed");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function remove() {
  busy.value = true;
  try {
    await del(`/folders/${props.id}`);
    emit("changed");
    emit("close");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function order(
  id: number,
  target: number,
  placement = "before",
  batch = false,
) {
  const ids = batch ? [...draggedMediaIds.value] : [id];
  if (busy.value || ids.includes(target)) return;
  busy.value = true;
  try {
    await post("/media/reorder", {
      media_ids: ids,
      target_id: target,
      placement,
    });
    await load();
    emit("changed");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
    dragged.value = null;
  }
}
async function changed() {
  selected.value = [];
  await load();
  emit("changed");
}
</script>
<template>
  <ElDialog
    :model-value="!!id"
    width="1080px"
    class="folder-panel"
    destroy-on-close
    @close="emit('close')"
  >
    <template #header
      ><div class="folder-panel-title">
        <FolderOpen :size="25" />
        <div>
          <h2>{{ folder?.name || t("文件夹") }}</h2>
          <small
            >{{ folder?.timeline_day }} · {{ total }} {{ t("份影像") }}
          </small>
        </div>
      </div></template
    >
    <div v-if="folder" class="folder-panel-actions">
      <button
        class="button small"
        @click="
          selection = !selection;
          selected = [];
        "
      >
        {{ selection ? t("退出多选") : t("多选") }}
      </button>
      <template v-if="yearly.canEdit"
        ><button
          class="button small"
          @click="
            emit('close');
            router.push({
              path: '/upload',
              query: { date: folder.timeline_day, folder: String(folder.id) },
            });
          "
        >
          <Plus :size="14" /> {{ t("追加到文件夹") }}</button
        ><button
          class="text-button"
          @click="
            renaming = true;
            name = folder.name;
            shareAllowed = folder.share_allowed;
          "
        >
          <Pencil :size="14" /> {{ t("编辑文件夹") }}</button
        ><button class="text-button" @click="sorting = !sorting">
          <GripVertical :size="14" />{{
            sorting ? t("完成排序") : t("排序")
          }}</button
        ><ElPopconfirm
          :width="280"
          :title="t('仅将此文件夹内的全部影像恢复为拍摄时间从新到旧排列？')"
          :confirm-button-text="t('恢复排序')"
          :cancel-button-text="t('取消')"
          @confirm="resetOrder"
          ><template #reference
            ><button class="text-button" :disabled="busy || !total">
              <RotateCcw :size="14" /> {{ t("恢复默认排序") }}
            </button></template
          ></ElPopconfirm
        ><ElPopconfirm
          :confirm-button-text="t('删除文件夹')"
          :cancel-button-text="t('取消')"
          :title="t('删除文件夹？里面的影像会移回当天时间线，原文件保留。')"
          @confirm="remove"
          ><template #reference
            ><button class="text-button danger" :disabled="busy">
              <Trash2 :size="14" /> {{ t("删除文件夹") }}
            </button></template
          ></ElPopconfirm
        ></template
      >
    </div>
    <div v-if="selection" class="folder-panel-actions">
      <button class="text-button" @click="selected = items.map((m) => m.id)">
        {{ t("选中已加载") }} {{ items.length }} {{ t("项") }}</button
      ><span> {{ t("已选") }} {{ selected.length }} {{ t("项") }} </span
      ><button
        v-if="yearly.canEdit"
        class="button small"
        :disabled="!selected.length"
        @click="moving = true"
      >
        <FolderInput :size="14" /> {{ t("移入 / 移出文件夹") }}
      </button>
    </div>
    <p v-if="yearly.canEdit" class="muted">
      {{ t("可直接拖动排序，拖到上方区域移回当天；多选后可一起移动。") }}
    </p>
    <div
      v-if="yearly.canEdit"
      class="folder-drop-out"
      :class="{ active: movingOut }"
      @dragover.prevent="movingOut = true"
      @dragleave="movingOut = false"
      @drop.prevent="dropOutside"
    >
      {{
        dragged
          ? t("松开移回当天时间线（{p0} 份影像）", {
              p0: draggedMediaIds.length,
            })
          : t("拖到这里移回当天时间线")
      }}
    </div>
    <p v-if="error" class="error-panel">
      {{ error }}
      <button class="text-button" @click="load()">{{ t("重试") }}</button>
    </p>
    <div class="folder-media-grid">
      <div
        v-for="(media, index) in items"
        :key="media.id"
        :draggable="yearly.canEdit && !busy"
        @dragstart="
          dragged = media.id;
          $event.dataTransfer?.setData('text/plain', String(media.id));
        "
        @dragover="
          dragged &&
          !draggedMediaIds.includes(media.id) &&
          $event.preventDefault()
        "
        @drop.prevent="
          dragged &&
          order(
            dragged,
            media.id,
            items.findIndex((m) => m.id === dragged) < index
              ? 'after'
              : 'before',
            true,
          )
        "
        @dragend="
          dragged = null;
          movingOut = false;
        "
      >
        <div v-if="sorting" class="folder-item-order">
          <button
            class="text-button"
            :disabled="busy || index === 0"
            @click="order(media.id, items[index - 1].id)"
          >
            <ArrowLeft :size="13" /> {{ t("前移") }}</button
          ><button
            class="text-button"
            :disabled="busy || index === items.length - 1"
            @click="order(media.id, items[index + 1].id, 'after')"
          >
            {{ t("后移") }} <ArrowRight :size="13" />
          </button>
        </div>
        <MediaCard
          :media="media"
          :selection="selection"
          :selected="selected.includes(media.id)"
          @select="toggle"
          @longpress="
            selection = true;
            toggle(media);
          "
          @open="!sorting && (detail = media.id)"
        />
      </div>
    </div>
    <p v-if="!items.length && !loading && !error" class="folder-empty">
      {{
        t("这里还没有符合条件的影像。可以追加上传，或从当天时间线批量移入。")
      }}
    </p>
    <div class="folder-panel-actions">
      <span v-if="loading"> {{ t("正在加载…") }} </span
      ><button
        v-else-if="items.length < total"
        class="button"
        @click="load(false)"
      >
        {{ t("加载更多") }}
      </button>
    </div>
    <MediaDetail :id="detail" @close="detail = null" @saved="changed" />
    <FolderMoveDialog
      :open="moving"
      :day="folder?.timeline_day || ''"
      :ids="selected"
      :current-folder="id || undefined"
      @close="moving = false"
      @saved="changed"
    />
    <ElDialog
      v-model="renaming"
      :title="t('编辑文件夹')"
      width="440px"
      append-to-body
      ><form @submit.prevent="rename">
        <label>
          {{ t("文件夹名称") }} <input v-model="name" maxlength="255"
        /></label>
        <label class="checkbox-label"
          ><input v-model="shareAllowed" type="checkbox" />{{
            t("允许分享")
          }}</label
        >
        <p class="muted">
          {{ t("关闭后，此文件夹及其内容不会出现在任何分享链接中。") }}
        </p>
        <div class="dialog-actions">
          <button class="button primary" :disabled="busy || !name.trim()">
            {{ t("保存设置") }}
          </button>
        </div>
      </form></ElDialog
    >
  </ElDialog>
</template>
<style scoped>
.folder-drop-out {
  position: sticky;
  top: 0;
  z-index: 2;
  padding: 12px;
  margin-bottom: 18px;
  border: 2px dashed var(--primary);
  border-radius: 12px;
  background: var(--surface);
  text-align: center;
  color: var(--primary);
}
.folder-drop-out.active {
  background: color-mix(in srgb, var(--primary) 18%, var(--surface));
}

.folder-panel-title {
  display: flex;
  gap: 12px;
  align-items: center;
  color: var(--primary);
}
.folder-panel-title h2 {
  font-size: 22px;
  margin: 0 0 6px;
}
.folder-panel-title small {
  color: var(--muted);
}
.folder-panel-actions {
  display: flex;
  align-items: center;
  gap: 14px;
  flex-wrap: wrap;
  margin: 16px 0;
}
.folder-panel-actions button,
.folder-item-order button {
  display: inline-flex;
  gap: 5px;
  align-items: center;
}
.folder-media-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
  gap: 10px;
}
.folder-item-order {
  display: flex;
  justify-content: space-between;
  padding: 8px;
}
.folder-empty {
  text-align: center;
  padding: 65px 20px;
  color: var(--muted);
}
@media (max-width: 700px) {
  .folder-media-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
</style>
