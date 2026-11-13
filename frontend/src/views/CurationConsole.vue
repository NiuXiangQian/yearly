<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from "vue";
import { api, post } from "../lib/api";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
import MediaCard from "../components/MediaCard.vue";
import MediaViewer from "../components/MediaViewer.vue";
import MotionDialog from "../components/MotionDialog.vue";
import OrganizationReview from "../components/OrganizationReview.vue";
import type { ReviewMedia } from "../lib/memory-review";

type Quality = { thumbnail: string; representative: number; seconds: (number | null)[]; frames: { frame: number; clarity: number; blurred: boolean; face_visibility: string; reason: string }[] };
type Item = { media: ReviewMedia; disposition: string; quality: Quality | null };
type Group = { key: string; kind: string; items: Item[] };
type Queue = { items: Group[]; next_cursor: number | null; group_count: number; unfiled_media: number; total_media: number; quality_enabled: boolean };
const yearly = useYearly();
const queue = ref<Queue>(), scope = ref("unfiled"), tab = ref("media");
const selected = ref<number[]>([]), children = ref<number[]>([]), expanded = ref<string[]>([]);
const before = ref<number | null>(null), history = ref<(number | null)[]>([]);
const reviewing = ref(false);
const busy = ref(false), loading = ref(false), error = ref(""), notice = ref(""), undoToken = ref("");
const previewing = ref<ReviewMedia>(), seconds = ref<number>(), completed = ref(0), stop = ref(false);
let active = true, generation = 0;
onBeforeUnmount(() => { active = false; generation++; stop.value = true; });
const pageIds = computed(() => queue.value?.items.flatMap(g => g.items.map(i => i.media.id)) ?? []);
function toggle(ids: number[]) {
  const next = new Set(selected.value), remove = ids.every(id => next.has(id));
  ids.forEach(id => remove ? next.delete(id) : next.add(id));selected.value = [...next];
}
async function load() {
  const request = ++generation;loading.value = true;error.value = "";
  try {
    const data = await api<Queue>(`/curation/groups?scope=${scope.value}${before.value ? `&before=${before.value}` : ""}`);
    if (!active || request !== generation) return;
    queue.value = data;selected.value = [];expanded.value = [];
  } catch (e) { if (active && request === generation) error.value = (e as Error).message; }
  finally { if (active && request === generation) loading.value = false; }
}
function reset() { before.value = null;history.value = [];void load(); }
function next() { history.value.push(before.value);before.value = queue.value?.next_cursor ?? null;void load(); }
function previous() { before.value = history.value.pop() ?? null;void load(); }
function show(item: Item, representative = false) {
  previewing.value = item.media;
  seconds.value = representative && item.quality ? item.quality.seconds[item.quality.representative] ?? undefined : undefined;
}
async function save(action: "add" | "done" | "ignore") {
  if (busy.value || !selected.value.length) return;
  busy.value = true;error.value = "";notice.value = "";
  try {
    const result = await post<{ count: number; undo_token: string }>("/curation/batch", { media_ids: selected.value, child_ids: children.value, action });
    undoToken.value = result.undo_token;notice.value = t("已处理 {n} 份影像，可撤销。", { n: result.count });
    await load();
  } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function undo() {
  busy.value = true;error.value = "";
  try { await post(`/curation/undo/${undoToken.value}`);undoToken.value = "";notice.value = t("已撤销上次整理。");await load(); }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function quality() {
  const ids = [...selected.value];
  if (ids.length > 20) { error.value = t("每次最多复核20份影像，请减少选择。");return; }
  busy.value = true;reviewing.value = true;stop.value = false;completed.value = 0;error.value = "";notice.value = "";
  try {
    for (const id of ids) {
      if (!active || stop.value) break;
      const result = await post<Quality>(`/curation/media/${id}/quality`);
      if (!active) break;
      for (const group of queue.value?.items ?? []) for (const item of group.items) if (item.media.id === id) item.quality = result;
      completed.value++;
    }
    if (active) notice.value = t("已复核 {n} 份影像。", { n: completed.value });
  } catch (e) { if (active) error.value = (e as Error).message; }
  finally { if (active) { busy.value = false;reviewing.value = false; } }
}
void load();
</script>

<template>
  <main class="curation-console">
    <header><h1>{{ t("相册整理") }}</h1><p>{{ t("按影像整理，一次选择，批量归档。已有的人物与宠物关联会直接用于相册。") }}</p></header>
    <nav class="tabs" aria-label="整理内容"><button class="button" @click="tab = 'media'">{{ t("影像归档") }}</button><button class="button" @click="tab = 'tags'">{{ t("标签与处理记录") }}</button></nav>
    <OrganizationReview v-if="tab === 'tags'" />
    <template v-else>
      <p v-if="queue" class="summary">{{ t("{n} 份影像尚未归档", { n: queue.unfiled_media }) }} · {{ t("当前筛选共 {n} 组", { n: queue.group_count }) }}</p>
      <div class="tools"><label>{{ t("显示") }} <select v-model="scope" :disabled="busy || loading" @change="reset"><option value="unfiled">{{ t("尚未关联人物或宠物") }}</option><option value="all">{{ t("全部影像（含已归档）") }}</option><option value="handled">{{ t("已处理和已略过") }}</option></select></label><button class="button" :disabled="busy || loading" @click="load">{{ t("刷新") }}</button></div>
      <p class="muted">{{ t("未归档不影响浏览。完全重复的文件合并展示；拍摄时间接近的照片可展开检查，同组不表示同一个人物。") }}</p>
      <div class="batch-tools">
        <button class="button" :disabled="busy || loading || !pageIds.length" @click="toggle(pageIds)">{{ t("选择／取消本页") }}</button>
        <strong>{{ t("已选 {n} 份", { n: selected.length }) }}</strong>
        <fieldset :disabled="busy || loading"><legend>{{ t("批量添加到人物／宠物相册") }}</legend><label v-for="person in yearly.children" :key="person.id"><input v-model="children" type="checkbox" :value="person.id" />{{ person.name }}</label></fieldset>
        <div class="tools"><button class="button primary" :disabled="busy || loading || !selected.length || !children.length" @click="save('add')">{{ t("添加关联并完成") }}</button><button class="button" :disabled="busy || loading || !selected.length" @click="save('done')">{{ t("标记整理完成") }}</button><button class="button" :disabled="busy || loading || !selected.length" @click="save('ignore')">{{ t("略过所选") }}</button><button class="button" :disabled="busy || loading || !selected.length || !queue?.quality_enabled" @click="quality">{{ t("大模型画质复核") }}</button><button v-if="reviewing" class="button" @click="stop = true">{{ t("停止后续复核") }}</button></div>
        <p class="muted">{{ t("操作只影响所选影像。略过不会删除照片；画质复核评估画面和抽样帧，结果缓存，可随时查看。") }}</p>
      </div>
      <p v-if="error" role="alert" class="notice">{{ error }}</p><p v-if="notice" role="status">{{ notice }}</p>
      <button v-if="undoToken" class="button" :disabled="busy || loading" @click="undo">{{ t("撤销上次整理") }}</button>
      <p v-if="loading" role="status">{{ t("正在加载…") }}</p>
      <div class="groups" :aria-busy="busy || loading">
        <section v-for="group in queue?.items ?? []" :key="group.key" class="group">
          <header><label><input type="checkbox" :checked="group.items.every(i => selected.includes(i.media.id))" :disabled="busy || loading" @change="toggle(group.items.map(i => i.media.id))" />{{ t(group.kind === 'duplicate' ? '完全重复内容' : group.kind === 'capture' ? '拍摄时间接近' : group.items[0].media.media_type === 'video' ? '一段视频' : '一份影像') }} · {{ group.items.length }}</label><button v-if="group.items.length > 1" class="button small" :disabled="busy" @click="expanded.includes(group.key) ? expanded = expanded.filter(k => k !== group.key) : expanded.push(group.key)">{{ t(expanded.includes(group.key) ? '收起' : '展开检查') }}</button></header>
          <div class="items"><article v-for="item in expanded.includes(group.key) ? group.items : group.items.slice(0, 1)" :key="item.media.id" class="item">
            <label class="item-choice"><input type="checkbox" :checked="selected.includes(item.media.id)" :disabled="busy || loading" @change="toggle([item.media.id])" />{{ item.media.title || t('未命名影像') }}</label>
            <button v-if="item.quality" class="representative" @click="show(item, true)"><img :src="item.quality.thumbnail" :alt="t('代表画面')" /><span>{{ t("查看代表画面") }}</span></button>
            <MediaCard v-else :media="item.media" @open="show(item)" />
            <p>{{ t("已关联") }}：{{ item.media.child_ids.map(id => yearly.children.find(p => p.id === id)?.name).filter(Boolean).join('、') || t('尚未关联') }}</p>
            <template v-if="item.quality"><p v-for="frame in item.quality.frames" :key="frame.frame" class="quality">{{ item.quality.seconds[frame.frame] == null ? t('画面') : `${item.quality.seconds[frame.frame]}s` }} · {{ frame.clarity }}/5 · {{ frame.reason }}</p><button class="button small" @click="show(item)">{{ t("查看原影像") }}</button></template>
          </article></div>
        </section>
      </div>
      <p v-if="queue && !queue.items.length && !loading">{{ t("这里没有需要处理的影像，可以继续浏览相册。") }}</p>
      <footer class="tools"><button class="button" :disabled="busy || loading || !history.length" @click="previous">{{ t("上一页") }}</button><button class="button" :disabled="busy || loading || !queue?.next_cursor" @click="next">{{ t("下一页") }}</button></footer>
    </template>
    <MotionDialog :model-value="!!previewing" :title="t('查看影像')" width="1000px" @update:model-value="(value: boolean) => { if (!value) previewing = undefined }"><MediaViewer v-if="previewing" :key="`${previewing.id}-${seconds}`" :media="previewing" :initial-seconds="seconds" /></MotionDialog>
  </main>
</template>

<style scoped>
.curation-console { max-width: 1200px; margin: auto; padding: 24px; display: grid; gap: 18px; }
h1, p { margin: 0; } header p, .muted, .quality { color: var(--muted); font-size: 13px; line-height: 1.6; } .tools, .tabs { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
.batch-tools { padding: 16px; border: 1px solid var(--line); border-radius: 12px; display: grid; gap: 14px; } fieldset { display: flex; flex-wrap: wrap; gap: 12px; border: 0; padding: 0; } legend { margin-bottom: 8px; } label { display: inline-flex; align-items: center; gap: 7px; } select { max-width: 100%; padding: 8px; }
.groups { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 320px), 1fr)); gap: 18px; } .group { border: 1px solid var(--line); border-radius: 12px; padding: 14px; min-width: 0; } .group > header { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 12px; } .items { display: grid; gap: 18px; } .item { display: grid; gap: 10px; } .item-choice { overflow-wrap: anywhere; } .representative { background: none; color: inherit; border: 0; padding: 0; cursor: pointer; display: grid; gap: 5px; } .representative img { width: 100%; max-height: 300px; object-fit: contain; background: #111; border-radius: 8px; } input[type=checkbox] { min-width: 20px; min-height: 20px; }
@media(max-width: 600px) { .curation-console { padding: 14px; } .tools .button { flex-grow: 1; } }
</style>
