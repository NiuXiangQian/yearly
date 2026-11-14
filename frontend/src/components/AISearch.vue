<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { Search, Sparkles } from "lucide-vue-next";
import { api, post, localDate } from "../lib/api";
import { t } from "../lib/i18n";
import MotionDialog from "./MotionDialog.vue";
import MediaCard from "./MediaCard.vue";
import MediaDetail from "./MediaDetail.vue";
const props = defineProps<{ filters: Record<string, unknown> }>();
const emit = defineEmits(["close", "locate"]);
const query = ref("");
const busy = ref(false), composing = ref(false);
const error = ref("");
const stage = ref("waiting"), elapsed = ref(0);
const stageLabels: Record<string, string> = { waiting: "正在提交搜索…", understanding: "正在理解描述…", matching: "正在查找候选影像…", ranking: "正在核对画面并筛选结果…", complete: "正在整理结果…" };
let activeRequestID: string | undefined;
let progressTimer: ReturnType<typeof setInterval> | undefined;
onUnmounted(() => clearInterval(progressTimer));
interface SearchPage {
  items: any[];
  search_id: string;
  page: number;
  total: number;
  page_size: number;
}
const results = ref<SearchPage>();
const pageCount = computed(() => results.value ? Math.ceil(results.value.total / results.value.page_size) : 0);
const paging = ref(false);
const detail = ref<number | null>(null);
const status = ref<{ enabled: boolean; indexed: number; total: number; failed: number }>();
const interpreted = ref<{ start?: string; end?: string; media_type?: string }>();
const scope = computed(() => {
  const f = props.filters;
  return [Array.isArray(f.child_ids) && f.child_ids.length ? t("已选人物") : "", f.owner_id ? t("已选上传人") : "",
    f.media_type ? t(String(f.media_type === "video" ? "视频" : f.media_type === "photo" ? "照片" : "Live Photo")) : "",
    f.start || f.end ? `${String(f.start || "").slice(0, 10)} — ${String(f.end || "").slice(0, 10)} ${t('结束日不含')}` : ""].filter(Boolean).join(" · ");
});
async function loadStatus() {
  error.value = "";
  try { status.value = await api("/ai-search/status"); }
  catch (e) { error.value = (e as Error).message; }
}
async function search() {
  if (composing.value || busy.value || paging.value || !query.value.trim() || !status.value?.enabled || !status.value.indexed) return;
  busy.value = true; error.value = ""; results.value = undefined; interpreted.value = undefined;
  const requestID = crypto.randomUUID(); activeRequestID = requestID;
  stage.value = "waiting"; elapsed.value = 0;
  let polling = false;
  progressTimer = setInterval(async () => {
    elapsed.value++;
    if (polling) return;
    polling = true;
    try {
      const progress = await api(`/ai-search/progress/${requestID}`);
      if (busy.value && activeRequestID === requestID && progress.stage in stageLabels) stage.value = progress.stage;
    } catch { clearInterval(progressTimer); }
    finally { polling = false; }
  }, 1000);
  try {
    const result = await post("/ai-search", { ...props.filters, query: query.value.trim(), request_id: requestID });
    results.value = result; interpreted.value = result.filters;
  } catch (e) { error.value = (e as Error).message; }
  finally { clearInterval(progressTimer); activeRequestID = undefined; busy.value = false; }
}
async function changePage(page: number) {
  if (!results.value || paging.value || busy.value || page < 1 || page > pageCount.value) return;
  paging.value = true;
  error.value = "";
  try { results.value = await api<SearchPage>(`/ai-search/results/${results.value.search_id}?page=${page}`); }
  catch (e) { error.value = (e as Error).message; }
  finally { paging.value = false; }
}
onMounted(loadStatus);
</script>
<template>
  <MotionDialog :model-value="true" :title="t('智能找回忆')" class="ai-search-dialog" width="960px" top="5vh" @close="emit('close')">
    <div class="ai-search-intro"><Sparkles :size="20" /><p>{{ t("描述一个画面，找回照片和视频里的瞬间。") }}</p></div>
    <p v-if="scope" class="ai-search-note">{{ t("沿用当前筛选") }}：{{ scope }}</p>
    <form class="ai-search-form" @submit.prevent="search">
      <input v-model="query" :aria-label="t('描述想找的回忆')" :placeholder="t('例如：去年夏天在海边玩沙子')" maxlength="200" :disabled="busy"
        @compositionstart="composing = true" @compositionend="composing = false" @keydown.enter="($event.isComposing || composing) && $event.preventDefault()" />
      <button class="button primary" type="submit" :disabled="busy || paging || !query.trim() || !status?.enabled || !status?.indexed"><Search :size="16" />{{ t(busy ? "正在寻找…" : "查找") }}</button>
    </form>
    <div class="ai-search-note" aria-live="polite">
      <template v-if="status && !status.enabled">{{ t("智能搜索尚未启用，请管理员配置 OpenAI API Key 并建立索引") }}</template>
      <template v-else-if="status">{{ t("已分析") }} {{ status.indexed }} / {{ status.total }} {{ t("项影像") }}<span v-if="status.failed"> · {{ status.failed }} {{ t("项分析失败，等待重试") }}</span></template>
      <template v-else>{{ t("正在读取搜索状态…") }}</template>
      <button class="text-button" :disabled="busy" @click="loadStatus">{{ t("刷新状态") }}</button>
    </div>
    <p v-if="status?.enabled && !status.indexed" class="ai-search-note">{{ t("正在等待后台建立索引，完成后即可搜索。") }}</p>
    <p class="ai-search-note">{{ t("仅搜索已分析的影像。视频按抽样画面匹配，可能遗漏短暂片段；Live Photo 按静态照片匹配。") }}</p>
    <p v-if="error" role="alert" class="ai-search-error">{{ error }}</p>
    <p v-if="interpreted?.start || interpreted?.end" class="ai-search-note">{{ t("识别到的归档日期") }}：{{ interpreted?.start || '…' }} — {{ interpreted?.end || '…' }}{{ t("（含起止日）") }}</p>
    <p v-if="busy" role="status">{{ t(stageLabels[stage]) }} · {{ t("已等待") }} {{ elapsed }} {{ t("秒") }}</p>
    <template v-else-if="results">
      <p class="ai-search-count" role="status">{{ results.total }} {{ t("项相关回忆") }} · {{ t("按相关程度排列") }}</p>
      <nav v-if="pageCount > 1" class="ai-search-pages" :aria-label="t('搜索结果分页')" :aria-busy="paging">
        <button class="chip" :disabled="paging || results.page === 1" @click="changePage(results.page - 1)">{{ t("上一页") }}</button>
        <span role="status">{{ t("第 {page} / {pages} 页", { page: results.page, pages: pageCount }) }}</span>
        <button class="chip" :disabled="paging || results.page === pageCount" @click="changePage(results.page + 1)">{{ t("下一页") }}</button>
      </nav>
      <div v-if="results.items.length" class="ai-search-grid">
        <div v-for="item in results.items" :key="item.id" class="ai-search-result">
          <MediaCard :media="item" thumbnail @open="detail = item.id" />
          <button class="text-button ai-search-open" @click="detail = item.id">{{ item.title || localDate(item.timeline_day) }} · {{ t("查看") }}</button>
          <button class="text-button ai-search-locate" @click="emit('locate', item)">{{ t("在时间线查看") }}</button>
          <p>{{ item.search_description }}</p>
        </div>
      </div>
      <div v-else class="ai-search-empty">{{ t("没有找到相关影像，试试描述场景、物体或动作，或放宽时间线筛选。") }}</div>
    </template>
    <div v-else-if="!busy" class="ai-search-examples">
      <span>{{ t("试着找找") }}</span>
      <button v-for="example in ['在草地上奔跑的小狗', '吹生日蜡烛的视频', '穿黄色雨衣踩水坑']" :key="example" class="chip" @click="query = t(example)">{{ t(example) }}</button>
    </div>
    <MediaDetail :id="detail" @close="detail = null" @saved="detail = null; search()" />
  </MotionDialog>
</template>
<style>
.ai-search-dialog { max-width: calc(100vw - 24px); }
.ai-search-dialog .el-dialog__body { padding-top: 8px; }
.ai-search-intro { display: flex; align-items: center; gap: 10px; color: var(--text); }
.ai-search-intro p { margin: 8px 0 18px; }
.ai-search-form { display: flex; gap: 10px; }
.ai-search-form input { flex: 1; min-width: 0; min-height: 46px; }
.ai-search-form button { flex-shrink: 0; min-height: 46px; }
.ai-search-note { font-size: 13px; color: var(--muted); line-height: 1.7; margin: 10px 0; overflow-wrap: anywhere; }
.ai-search-note button { margin-left: 8px; min-height: 36px; }
.ai-search-error { color: var(--el-color-danger); }
.ai-search-count { margin: 24px 0 14px; font-variant-numeric: tabular-nums; }
.ai-search-pages { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
.ai-search-pages button { min-height: 44px; }
.ai-search-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 20px 14px; }
.ai-search-result { min-width: 0; }
.ai-search-result .media-card { width: 100%; }
.ai-search-result p { font-size: 13px; color: var(--muted); margin: 4px 0; line-height: 1.6; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.ai-search-open { min-height: 40px; text-align: left; overflow-wrap: anywhere; }
.ai-search-locate { display: block; min-height: 44px; }
.ai-search-examples { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; padding: 24px 0; }
.ai-search-examples .chip { min-height: 40px; white-space: normal; text-align: left; }
.ai-search-empty { padding: 32px 0; line-height: 1.8; color: var(--muted); }
@media (max-width: 600px) { .ai-search-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } .ai-search-form { flex-wrap: wrap; } .ai-search-form input { flex-basis: 100%; } .ai-search-form button { width: 100%; } }
</style>
