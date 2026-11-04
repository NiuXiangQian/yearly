<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { ElMessage } from "element-plus";
import { Link, Folder, ChevronDown, X } from "lucide-vue-next";
import { api, post, del, notify } from "../lib/api";
import { t, locale } from "../lib/i18n";
import DateField from "./DateField.vue";
import MediaCard from "./MediaCard.vue";
const props = defineProps<{ open: boolean; initialDate?: string }>();
const emit = defineEmits(["close"]);
const title = ref(""),
  start = ref(""),
  end = ref(""),
  hours = ref(24);
const busy = ref(false),
  loading = ref(false),
  reviewed = ref(false);
const rows = ref<any[]>([]),
  cursor = ref<string | null>(null),
  history = ref<any[]>([]);
const excluded = ref({
  days: [] as string[],
  folders: [] as number[],
  media: [] as number[],
  events: [] as number[],
});
const folders = ref<
  Record<number, { items: any[]; total: number; open: boolean }>
>({});
const folderLoading = ref<number | null>(null);
const link = ref("");
let generation = 0;
const groups = computed(() => {
  const result: { day: string; items: any[] }[] = [];
  for (const item of rows.value) {
    const day = item.timeline_day;
    let group = result.find((g) => g.day === day);
    if (!group) result.push((group = { day, items: [] }));
    group.items.push(item);
  }
  return result;
});
const valid = computed(
  () =>
    start.value &&
    end.value &&
    start.value <= end.value &&
    hours.value >= 1 &&
    hours.value <= 168,
);
watch(
  () => props.open,
  async (open) => {
    if (!open) {
      link.value = "";
      return;
    }
    if (!start.value) start.value = props.initialDate || "";
    if (!end.value)
      end.value = props.initialDate || new Date().toLocaleDateString("en-CA");
    try {
      history.value = await api("/shares");
    } catch (e) {
      notify(e);
    }
  },
);
watch([start, end], () => {
  generation++;
  rows.value = [];
  cursor.value = null;
  reviewed.value = false;
  loading.value = false;
});
async function preview(more = false) {
  if (!valid.value || loading.value) return;
  loading.value = true;
  const current = ++generation;
  const after = new Date(end.value + "T12:00:00");
  after.setDate(after.getDate() + 1);
  const endExclusive = `${after.getFullYear()}-${String(after.getMonth() + 1).padStart(2, "0")}-${String(after.getDate()).padStart(2, "0")}`;
  const query = new URLSearchParams({
    group_folders: "true",
    start: start.value + "T00:00:00",
    end: endExclusive + "T00:00:00",
    page_size: "40",
  });
  if (more && cursor.value) query.set("cursor", cursor.value);
  try {
    const data = await api(`/timeline?${query}`);
    if (current !== generation) return;
    rows.value = more ? [...rows.value, ...data.items] : data.items;
    cursor.value = data.next_cursor;
    reviewed.value = true;
  } catch (e) {
    notify(e);
  } finally {
    if (current === generation) loading.value = false;
  }
}
async function openFolder(id: number, more = false) {
  if (folderLoading.value !== null) return;
  if (folders.value[id] && !more) {
    folders.value[id].open = !folders.value[id].open;
    return;
  }
  folderLoading.value = id;
  try {
    const previous = folders.value[id]?.items || [];
    const data = await api(
      `/media?folder_id=${id}&page_size=40&page=${Math.floor(previous.length / 40) + 1}`,
    );
    folders.value[id] = {
      items: [...previous, ...data.items],
      total: data.total,
      open: true,
    };
  } catch (e) {
    notify(e);
  } finally {
    folderLoading.value = null;
  }
}
async function create() {
  if (!valid.value || busy.value || !reviewed.value) return;
  busy.value = true;
  try {
    const data = await post("/shares", {
      title: title.value,
      start_date: start.value,
      end_date: end.value,
      hours: hours.value,
      exclusions: excluded.value,
    });
    link.value = `${location.origin}/share/${data.token}`;
    history.value.unshift(data);
    ElMessage.success(t("分享链接已创建"));
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function copy() {
  try {
    await navigator.clipboard.writeText(link.value);
    ElMessage.success(t("链接已复制"));
  } catch {
    ElMessage.info(t("请选中链接手动复制"));
  }
}
async function revoke(item: any) {
  try {
    await del(`/shares/${item.id}`);
    item.revoked = true;
    if (link.value.endsWith(item.token)) link.value = "";
  } catch (e) {
    notify(e);
  }
}
</script>
<template>
  <ElDialog
    :model-value="open"
    :title="t('分享时间线')"
    width="760px"
    class="share-dialog"
    @close="emit('close')"
  >
    <p class="muted">
      {{ t("选择日期范围和排除内容，生成无需登录的只读链接。") }}
    </p>
    <form @submit.prevent="create">
      <label
        >{{ t("分享标题")
        }}<input
          v-model="title"
          maxlength="120"
          :placeholder="t('例如：一起长大的日子')"
      /></label>
      <div class="share-fields">
        <label>{{ t("开始日期") }}<DateField v-model="start" required /></label>
        <label
          >{{ t("结束日期（含当天）") }}<DateField v-model="end" required
        /></label>
        <label
          >{{ t("有效时长（小时）")
          }}<input
            v-model.number="hours"
            type="number"
            min="1"
            max="168"
            step="1"
            required
          /><small>{{ t("1 小时至 7 天") }}</small></label
        >
      </div>
      <p v-if="start && end && start > end" role="alert">
        {{ t("结束日期不能早于开始日期") }}
      </p>
      <div class="share-help">
        <b>{{ t("勾选要排除的内容") }}</b>
        <p>{{ t("排除整天或文件夹时，其内的全部内容都不会出现在分享中。") }}</p>
        <p>
          {{
            t(
              "分享包含日期范围内全部孩子的内容，并随时间线更新；未排除的新内容也会显示。成长日记正文会分享，请检查私人文字。",
            )
          }}
        </p>
      </div>
      <button
        type="button"
        class="button"
        :disabled="!valid || loading"
        @click="preview()"
      >
        {{ loading ? t("正在加载…") : t("查看范围内的内容") }}
      </button>
      <div v-if="reviewed" class="exclusion-list">
        <p v-if="!rows.length" class="muted">{{ t("这个范围还没有回忆") }}</p>
        <section v-for="group in groups" :key="group.day" class="exclude-day">
          <label class="checkbox-label"
            ><input
              v-model="excluded.days"
              type="checkbox"
              :value="group.day"
            />{{ group.day }} · {{ t("排除这一天") }}</label
          >
          <div
            v-for="item in group.items"
            :key="item.kind + item.id"
            class="exclude-item"
            :class="{ muted: excluded.days.includes(group.day) }"
          >
            <div class="exclude-row">
              <input
                v-model="
                  excluded[
                    item.kind === 'folder'
                      ? 'folders'
                      : item.kind === 'event'
                        ? 'events'
                        : 'media'
                  ]
                "
                type="checkbox"
                :value="item.id"
                :disabled="excluded.days.includes(group.day)"
                :aria-label="
                  t('排除 {p0}', {
                    p0: item.name || item.title || t('影像') + ' ' + item.id,
                  })
                "
              />
              <div class="exclude-thumb">
                <MediaCard
                  v-if="item.kind === 'media'"
                  :media="item"
                  thumbnail
                /><Folder v-else-if="item.kind === 'folder'" :size="24" /><span
                  v-else
                  >✎</span
                >
              </div>
              <span class="exclude-name">{{
                item.name || item.title || t("影像") + " " + item.id
              }}</span>
              <button
                v-if="item.kind === 'folder'"
                type="button"
                class="text-button"
                :disabled="folderLoading !== null"
                @click="openFolder(item.id)"
              >
                <ChevronDown :size="14" />{{ t("选择文件") }}
              </button>
            </div>
            <div
              v-if="item.kind === 'folder' && folders[item.id]?.open"
              class="exclude-folder"
            >
              <label
                v-for="media in folders[item.id].items"
                :key="media.id"
                class="exclude-row"
              >
                <input
                  v-model="excluded.media"
                  type="checkbox"
                  :value="media.id"
                  :disabled="
                    excluded.days.includes(group.day) ||
                    excluded.folders.includes(item.id)
                  "
                />
                <div class="exclude-thumb">
                  <MediaCard :media="media" thumbnail />
                </div>
                <span>{{ media.title || t("影像") + " " + media.id }}</span>
              </label>
              <button
                v-if="folders[item.id].items.length < folders[item.id].total"
                type="button"
                class="text-button"
                :disabled="folderLoading !== null"
                @click="openFolder(item.id, true)"
              >
                {{ t("加载更多") }}
              </button>
            </div>
          </div>
        </section>
        <button
          v-if="cursor"
          type="button"
          class="button"
          :disabled="loading"
          @click="preview(true)"
        >
          {{ t("加载更多") }}
        </button>
      </div>
      <div class="dialog-actions">
        <button class="button primary" :disabled="busy || !valid || !reviewed">
          <Link :size="16" />{{ busy ? t("正在创建…") : t("创建分享链接") }}
        </button>
      </div>
    </form>
    <div v-if="link" class="created-share" role="status">
      <label
        >{{ t("请保存链接，关闭后不再显示完整链接")
        }}<input
          :value="link"
          readonly
          @focus="($event.target as HTMLInputElement).select()"
      /></label>
      <div class="share-link-actions">
        <button class="button primary" @click="copy">{{ t("复制链接") }}</button
        ><a class="button" :href="link" target="_blank" rel="noreferrer">{{
          t("预览分享")
        }}</a>
      </div>
    </div>
    <details v-if="history.length" class="share-history">
      <summary>{{ t("管理最近的分享") }} · {{ history.length }}</summary>
      <div v-for="item in history" :key="item.id" class="history-row">
        <div>
          <b>{{ item.title || t("成长时间线") }}</b
          ><small>{{ item.start_date }} — {{ item.end_date }}</small
          ><small
            >{{ t("到期时间") }}:
            {{ new Date(item.expires_at).toLocaleString(locale) }}</small
          >
        </div>
        <span v-if="item.revoked || item.expired" class="muted">{{
          item.revoked ? t("已撤销") : t("已过期")
        }}</span
        ><button v-else class="text-button" @click="revoke(item)">
          <X :size="14" />{{ t("撤销分享") }}
        </button>
      </div>
    </details>
    <p class="muted share-footnote">
      {{
        t(
          "持有链接的人均可阅读，请只发给信任的人。撤销后停止新的访问，已签发的预览地址最多再有效 60 秒，已保存的内容无法收回。",
        )
      }}
    </p>
  </ElDialog>
</template>
<style scoped>
.share-fields {
  display: grid;
  grid-template-columns: 1fr 1fr 140px;
  gap: 12px;
}
.share-help {
  background: var(--sage-light);
  border-radius: 10px;
  padding: 14px;
  margin: 16px 0;
  line-height: 1.7;
}
.share-help p {
  margin: 5px 0 0;
  font-size: 12px;
}
.exclusion-list {
  max-height: 380px;
  overflow: auto;
  margin-top: 14px;
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 12px;
}
.exclude-day + .exclude-day {
  margin-top: 18px;
}
.exclude-row {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 7px 0;
  min-width: 0;
}
.exclude-row input {
  width: 16px;
  flex-shrink: 0;
}
.exclude-thumb {
  width: 48px;
  flex-shrink: 0;
  color: var(--sage);
}
.exclude-thumb :deep(.media-card) {
  pointer-events: none;
  margin: 0;
}
.exclude-name {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.exclude-folder {
  margin-left: 28px;
  border-left: 2px solid var(--line);
  padding-left: 12px;
}
.exclude-row button {
  display: flex;
  align-items: center;
  white-space: nowrap;
}
.created-share {
  padding: 16px;
  border: 1px solid var(--sage);
  border-radius: 10px;
}
.share-link-actions {
  display: flex;
  gap: 10px;
}
.share-history {
  margin-top: 24px;
}
.share-history summary {
  cursor: pointer;
}
.history-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid var(--line);
}
.history-row small {
  display: block;
  margin-top: 5px;
  color: var(--muted);
}
.share-footnote {
  font-size: 11px;
  line-height: 1.8;
  margin-top: 20px;
}
@media (max-width: 600px) {
  .share-fields {
    grid-template-columns: 1fr;
  }
  .exclusion-list {
    max-height: 320px;
  }
}
</style>
