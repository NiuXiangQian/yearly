<script setup lang="ts">
import { onMounted, ref } from "vue";
import { api, put, post, localDate } from "../lib/api";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
import MediaViewer from "./MediaViewer.vue";
import MotionDialog from "./MotionDialog.vue";
import type { ReviewMedia } from "../lib/memory-review";

type Settings = { tags_enabled: boolean; people_enabled: boolean; tag_rules: Record<string, { target: string; mode: string }>; person_rules: Record<string, string> };
type Entry = { auto_linked?: number; auto_reset?: number; id: number; kind: string; status: string; automatic: boolean; media: ReviewMedia; created_at: string; updated_at: string;
  before: { tags?: string[]; child_id?: number | null }; proposed: { tags?: string[]; child_id?: number | null }; current: { tags?: string[]; decisions?: Record<string, string | null>; child_id?: number | null };
  names: Record<string, string>; thumbnail: string; frame_seconds?: number | null;
  evidence: { tags?: { name: string; evidence: string; rule: string }[]; reason?: string; similarity?: number; model?: string; description?: string };
  events: { action: string; at: string; actor_name: string; value: { tags?: string[]; child_id?: number | null; remember?: boolean } }[] };
const emit = defineEmits<{ updated: [] }>();
const yearly = useYearly(), options = ref<Settings>(), entries = ref<Entry[]>([]), all = ref(false), kind = ref("");
const autoLinkedCount = ref(0);
const pending = ref(0), before = ref<number>(), next = ref<number | null>(), history = ref<(number | undefined)[]>([]);
const busy = ref(false), error = ref(""), notice = ref(""), failures = ref<{ media_id: number; message: string }[]>([]), preview = ref<Entry>();
const labels = ref<Record<number, Record<string, string>>>({}), enabled = ref<Record<number, Record<string, boolean>>>({}), people = ref<Record<number, string>>({}), remember = ref<Record<number, boolean>>({});
const eventTime = (value: string) => new Date(value + "Z").toLocaleString(undefined, { timeZone: "Asia/Shanghai" });
const statusLabel = (value: string) => t(({ imported: "补录现有结果", applied: "自动写入", confirmed: "人工确认", pending: "待审核", automatic: "已自动确认", approved: "已审核", corrected: "已修改", rejected: "已撤回", superseded: "已有后续修改" } as Record<string, string>)[value] ?? value);
const personName = (entry: Entry, id?: number | null) => id ? yearly.children.find(p => p.id === id)?.name || entry.names[id] || `#${id}` : t("未关联");
async function load(reset = false) {
  busy.value = true; error.value = "";
  if (reset) { before.value = undefined; history.value = []; }
  try {
    const query = new URLSearchParams({ scope: all.value ? "all" : "pending", limit: "12" });
    if (before.value) query.set("before", String(before.value)); if (kind.value) query.set("kind", kind.value);
    const [settings, queue] = await Promise.all([api<Settings>("/organization/settings"), api<{ items: Entry[]; next_cursor: number | null; pending: number; errors: typeof failures.value }>(`/organization/reviews?${query}`)]);
    options.value = settings; entries.value = queue.items; next.value = queue.next_cursor; pending.value = queue.pending; failures.value = queue.errors;
    for (const entry of queue.items) {
      labels.value[entry.id] = Object.fromEntries((entry.proposed.tags ?? []).map(tag => [tag, entry.current.decisions?.[tag] || tag]));
      enabled.value[entry.id] = Object.fromEntries((entry.proposed.tags ?? []).map(tag => [tag, entry.current.decisions ? entry.current.decisions[tag] != null : entry.status === "pending" || (entry.current.tags?.includes(tag) ?? true)]));
      people.value[entry.id] = String(entry.current.child_id ?? ""); remember.value[entry.id] = false;
    }
  } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function saveSettings() {
  busy.value = true; error.value = "";
  try { options.value = await put("/organization/settings", options.value); notice.value = t("自动整理习惯已保存，仅影响后续处理；所有记录保留。"); }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function review(entry: Entry, action: string) {
  busy.value = true; error.value = "";
  try {
    const body = { action, remember: remember.value[entry.id], ...(entry.kind === "tags" ? { tag_decisions: Object.fromEntries((entry.proposed.tags ?? []).map(tag => [tag, enabled.value[entry.id][tag] ? labels.value[entry.id][tag] : null])) } : { child_id: people.value[entry.id] ? Number(people.value[entry.id]) : null }) };
    const result = await put<Entry>(`/organization/reviews/${entry.id}`, body); autoLinkedCount.value = result.auto_linked ?? 0; notice.value = t("审核已保存，变更与处理习惯已记录。"); emit("updated"); await load();
  } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function run(retry = false) {
  busy.value = true; error.value = "";
  try { const result = await post<{ processed: number; busy: boolean }>(`/organization/run?limit=3&retry_failed=${retry}`); notice.value = result.busy ? t("后台正在自动整理，请稍后刷新审核列表。") : t("已处理 {n} 份影像，后续由后台继续整理。", { n: result.processed }); emit("updated"); await load(); }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
onMounted(() => load());
</script>
<template>
  <section class="organization-review" :aria-label="t('自动整理审核')">
    <p>{{ t("标签自动保存并确认，无需逐条处理。人物与宠物仍可核对；所有结果都保留记录。") }}</p>
    <p v-if="error" role="alert" class="notice">{{ error }}</p><p v-if="notice" role="status">{{ notice }}</p>
    <details v-if="options" class="habits"><summary>{{ t("自动整理与我的习惯") }}</summary>
      <label><input type="checkbox" v-model="options.tags_enabled" :disabled="busy" />{{ t("自动保存并确认标签，无需人工审核") }}</label>
      <label><input type="checkbox" v-model="options.people_enabled" :disabled="busy" />{{ t("自动关联明确匹配的人物与宠物并记录") }}</label>
      <p class="muted">{{ t("在审核时勾选“以后按这次处理”，记住标签用词或人物处理方式；自动通过的结果仍可在全部记录中复审。") }}</p>
      <div v-for="(rule, source) in options.tag_rules" :key="source" class="habit-row"><span>{{ source }} → {{ t(rule.mode === 'skip' ? '不再添加' : '自动确认') }} {{ rule.target }}</span><button class="button small" :disabled="busy" @click="delete options.tag_rules[source]">{{ t("移除习惯") }}</button></div>
      <div v-for="(mode, id) in options.person_rules" :key="id" class="habit-row"><span>{{ yearly.children.find(p => p.id === Number(id))?.name || id }} · {{ t(mode === 'manual' ? '每次人工确认' : '明确匹配时自动通过') }}</span><button class="button small" :disabled="busy" @click="delete options.person_rules[id]">{{ t("移除习惯") }}</button></div>
      <button class="button primary" :disabled="busy" @click="saveSettings">{{ t("保存整理习惯") }}</button>
    </details>
    <div class="review-toolbar"><label><input type="checkbox" v-model="all" :disabled="busy" @change="load(true)" />{{ t("全部记录，可复审修改") }}</label><select v-model="kind" :disabled="busy" :aria-label="t('记录类型')" @change="load(true)"><option value="">{{ t("全部类型") }}</option><option value="tags">{{ t("标签") }}</option><option value="face">{{ t("人物") }}</option><option value="pet">{{ t("宠物") }}</option></select><span>{{ t("{n} 条人物与宠物待核对", { n: pending }) }}</span><button class="button" :disabled="busy" @click="load()">{{ t("刷新") }}</button><button class="button" :disabled="busy || !options?.tags_enabled" @click="run()">{{ t("立即整理一批") }}</button></div>
    <div v-if="failures.length" class="notice"><p v-for="item in failures" :key="item.media_id">#{{ item.media_id }} · {{ item.message }}</p><button class="button" :disabled="busy" @click="run(true)">{{ t("重试失败影像") }}</button></div>
    <p v-if="busy" role="status">{{ t("正在处理，请稍候…") }}</p>
    <article v-for="entry in entries" :key="entry.id" class="organization-entry">
      <header><strong>{{ t(entry.kind === 'tags' ? '自动标签' : entry.kind === 'pet' ? '宠物关联' : '人物关联') }}</strong><span>{{ statusLabel(entry.status) }}</span><small>{{ localDate(entry.media.timeline_day || undefined) }} · #{{ entry.media.id }}</small></header>
      <button class="button source-entry" :disabled="busy" @click="preview = entry"><img v-if="entry.thumbnail" :src="entry.thumbnail" alt="" />{{ t("查看来源照片或视频") }}<span v-if="entry.frame_seconds != null"> · {{ entry.frame_seconds }} s</span></button>
      <template v-if="entry.kind === 'tags'"><p class="muted">{{ t("原有标签") }} · {{ entry.before.tags?.join('、') || t('无') }}</p><div v-for="tag in entry.proposed.tags" :key="tag" class="tag-review-row"><label><input type="checkbox" v-model="enabled[entry.id][tag]" :disabled="busy" />{{ tag }}</label><input v-model="labels[entry.id][tag]" :disabled="busy || !enabled[entry.id][tag]" :aria-label="t('修改标签 {name}', { name: tag })" maxlength="80" /><small>{{ entry.evidence.tags?.find(item => item.name === tag)?.evidence }}</small></div><p class="muted">{{ t("当前影像标签") }} · {{ entry.media.tags.join('、') || t('无') }}</p></template>
      <template v-else><p>{{ personName(entry, entry.before.child_id) }} → {{ personName(entry, entry.proposed.child_id) }}</p><p class="muted">{{ entry.evidence.reason }}<span v-if="entry.evidence.similarity != null"> · {{ t('相似度 {score}', { score: entry.evidence.similarity }) }}</span></p><select v-model="people[entry.id]" :disabled="busy" :aria-label="t('修改关联人物')"><option value="">{{ t("未关联") }}</option><option v-for="profile in yearly.children.filter(p => entry.kind === 'pet' ? p.profile_type === 'pet' && p.species === '狗' : p.profile_type !== 'pet')" :key="profile.id" :value="String(profile.id)">{{ profile.name }}</option></select></template>
      <p v-if="entry.status === 'superseded'" class="muted">{{ t("此记录已有后续修改，可打开来源查看当前结果。") }}</p>
      <label v-else class="remember"><input type="checkbox" v-model="remember[entry.id]" :disabled="busy" />{{ t("以后按这次处理") }}</label>
      <div v-if="entry.status !== 'superseded'" class="review-actions"><button v-if="entry.kind !== 'tags'" class="button primary" :disabled="busy || people[entry.id] !== String(entry.current.child_id ?? '')" @click="review(entry, 'approve')">{{ t("保留结果") }}</button><button class="button" :disabled="busy" @click="review(entry, 'correct')">{{ t("保存修改") }}</button><button class="button danger" :disabled="busy" @click="review(entry, 'reject')">{{ t("撤回这次结果") }}</button></div>
      <details><summary>{{ t("处理记录与依据") }} · {{ eventTime(entry.created_at) }}</summary><p v-if="entry.evidence.model">{{ entry.evidence.model }}</p><p v-if="entry.evidence.description">{{ entry.evidence.description }}</p><div v-for="(event, i) in entry.events" :key="i" class="history-event"><strong>{{ event.actor_name }} · {{ statusLabel(event.action) }}</strong><small>{{ eventTime(event.at) }}</small><p>{{ event.value.tags ? event.value.tags.join('、') || t('未添加标签') : personName(entry, event.value.child_id) }}<span v-if="event.value.remember"> · {{ t("已记住本次处理习惯") }}</span></p></div></details>
    </article>
    <p v-if="!busy && !entries.length">{{ t("当前没有待审核记录，可查看全部记录。") }}</p>
    <div class="review-toolbar"><button class="button" :disabled="busy || !history.length" @click="before = history.pop(); load()">{{ t("上一页") }}</button><button class="button" :disabled="busy || !next" @click="history.push(before); before = next ?? undefined; load()">{{ t("下一页") }}</button></div>
    <MotionDialog :model-value="!!preview" @update:model-value="(value: boolean) => { if (!value) preview = undefined }" :title="t('识别来源')" width="900px" destroy-on-close><MediaViewer v-if="preview" :key="preview.id" :media="preview.media" :initial-seconds="preview.frame_seconds ?? undefined" /></MotionDialog>
    <MotionDialog :model-value="autoLinkedCount > 0" @update:model-value="(value: boolean) => { if (!value) autoLinkedCount = 0 }" :title="t('已自动整理相似人脸')" width="420px">
      <p>{{ t("已将另外 {n} 张明确匹配的人脸关联到对应人物，可在已处理项中查看和修改。", { n: autoLinkedCount }) }}</p>
      <template #footer><button class="button primary" @click="autoLinkedCount = 0">{{ t("知道了") }}</button></template>
    </MotionDialog>
  </section>
</template>
<style scoped>
.organization-review { display: grid; gap: 20px; }
.organization-review p { margin: 0; line-height: 1.7; }
.habits, .organization-entry { padding: 20px; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; }
.habits[open], .organization-entry { display: grid; gap: 16px; }
summary { cursor: pointer; min-height: 32px; line-height: 1.6; }
label { display: flex; flex-direction: row; justify-content: flex-start; text-align: start; align-items: center; gap: 8px; min-height: 44px; }
input[type=checkbox] { width: auto; flex-shrink: 0; }
.habit-row, .review-toolbar, .review-actions, header { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.habit-row { justify-content: space-between; }
header small { margin-left: auto; color: var(--muted); }
.source-entry { justify-self: start; min-height: 44px; }
.source-entry img { width: 48px; height: 56px; object-fit: cover; border-radius: 6px; }
.tag-review-row { display: grid; grid-template-columns: minmax(120px, .6fr) minmax(0, 1fr); gap: 8px 16px; align-items: center; }
.tag-review-row small { grid-column: 2; color: var(--muted); }
.history-event { padding-block: 12px; border-top: 1px solid var(--line); }
.history-event small { display: block; color: var(--muted); margin: 6px 0; }
pre { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 12px; font-family: inherit; }
@media(max-width:520px) { .habits,.organization-entry { padding: 14px; } .tag-review-row { grid-template-columns: minmax(0,1fr); } .tag-review-row small { grid-column: 1; } header small { margin-left: 0; } .review-actions .button { flex: 1; } }
</style>
