<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref } from "vue";
import { ScanFace, PawPrint, MessageCircle, RefreshCw, Check, ArrowRight } from "lucide-vue-next";
import { api, post, put, localDate } from "../lib/api";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
import MediaCard from "../components/MediaCard.vue";
import MediaViewer from "../components/MediaViewer.vue";
import MotionDialog from "../components/MotionDialog.vue";
import OrganizationReview from "../components/OrganizationReview.vue";
import MemoryInterview from "../components/MemoryInterview.vue";
import type { ReviewFace, ReviewMedia, ReviewQueue } from "../lib/memory-review";

const yearly = useYearly();
type PetGroup = { media: ReviewMedia; dogs: (Omit<ReviewFace, "id" | "media"> & { index: number; appearance: string })[] };
type PetQueue = { items: PetGroup[]; next_cursor: number | null; pending_pets: number; unanalysed_media: number };
type Cursor = { faces?: number | null; pets?: number | null; memories?: number | null; facesDone?: boolean; petsDone?: boolean };
type Subject = ReviewFace & { key: string; pet: boolean; appearance?: string };
const tab = ref<"faces" | "memories" | "organization">("faces"), all = ref(false);
const pets = ref<PetQueue>(), pageFaces = ref<ReviewFace[]>([]), pagePets = ref<PetGroup[]>([]);
const subjects = computed<Subject[]>(() => [
  ...pageFaces.value.map(face => ({ ...face, key: `face-${face.id}`, pet: false })),
  ...pagePets.value.flatMap(group => group.dogs.filter(dog => all.value || (!dog.child_id && !dog.ignored)).map(dog => ({ ...dog, id: dog.index, media: group.media, key: `pet-${group.media.id}-${dog.index}`, pet: true }))),
].sort((a, b) => b.media.id - a.media.id || a.key.localeCompare(b.key)));
const queue = ref<ReviewQueue>(), memories = ref<ReviewMedia[]>([]);
const selected = ref<ReviewMedia>(), revision = ref(0);
const previewing = ref<Subject>();
const autoLinkedCount = ref(0);
const loading = ref(false), error = ref(""), notice = ref("");
const cursor = ref<Cursor>({}), nextCursor = ref<Cursor | null>(null), history = ref<Cursor[]>([]);
const filterMedia = ref<number | null>(null);
const choices = ref<Record<string, string>>({}), saving = ref<Record<string, boolean>>({});
const scanning = ref(false), scanned = ref(0), stopScan = ref(false);
const people = computed(() => yearly.children.filter(p => p.profile_type !== "pet"));
const dogs = computed(() => yearly.children.filter(p => p.profile_type === "pet" && p.species === "狗"));
let generation = 0, active = true;
onBeforeUnmount(() => { active = false; generation++; stopScan.value = true; });

async function load(refreshPeople = false) {
  const requested = ++generation;
  loading.value = true; error.value = "";
  const params = new URLSearchParams({ scope: all.value ? "all" : "pending", limit: "12" });
  if (tab.value === "faces" && cursor.value.faces) params.set("before", String(cursor.value.faces));
  if (tab.value === "faces" && filterMedia.value) params.set("media_id", String(filterMedia.value));
  const petParams = new URLSearchParams({ scope: all.value ? "all" : "pending", limit: "12" });
  if (cursor.value.pets) petParams.set("before", String(cursor.value.pets));
  if (filterMedia.value) petParams.set("media_id", String(filterMedia.value));
  const memoryParams = new URLSearchParams({ scope: all.value ? "all" : "pending", limit: "12" });
  if (cursor.value.memories) memoryParams.set("before", String(cursor.value.memories));
  try {
    const [faces, petList, memoryList, profiles] = await Promise.all([
      tab.value === "faces" && !cursor.value.facesDone ? api<ReviewQueue>(`/faces/review?${params}`) : Promise.resolve(null),
      tab.value === "faces" && !cursor.value.petsDone ? api<PetQueue>(`/pets/review?${petParams}`) : Promise.resolve(null),
      tab.value === "memories" ? api<{ items: ReviewMedia[]; next_cursor: number | null }>(`/memory-interviews?${memoryParams}`) : Promise.resolve(null),
      refreshPeople ? api<any[]>("/children", { cache: "reload" }) : Promise.resolve(null),
    ]);
    if (!active || requested !== generation) return;
    const previous = new Map(subjects.value.map(item => [item.key, item.ignored ? "ignore" : String(item.child_id ?? "")]));
    if (faces) queue.value = faces;
    if (petList) pets.value = petList;
    pageFaces.value = faces?.items ?? []; pagePets.value = petList?.items ?? [];
    if (profiles) yearly.children = profiles;
    for (const item of subjects.value) if (!(item.key in choices.value) || choices.value[item.key] === previous.get(item.key)) choices.value[item.key] = item.ignored ? "ignore" : String(item.child_id ?? "");
    if (memoryList) memories.value = memoryList.items;
    nextCursor.value = memoryList ? (memoryList.next_cursor ? { memories: memoryList.next_cursor } : null)
      : faces?.next_cursor || petList?.next_cursor ? { faces: faces?.next_cursor, pets: petList?.next_cursor, facesDone: !faces?.next_cursor, petsDone: !petList?.next_cursor } : null;
    if (!selected.value) selected.value = memoryList?.items[0] ?? subjects.value[0]?.media;
  } catch (e) { if (active && requested === generation) error.value = (e as Error).message; }
  finally { if (active && requested === generation) loading.value = false; }
}
function reset() { cursor.value = {}; history.value = []; void load(); }
function switchTab(value: "faces" | "memories" | "organization") { tab.value = value; filterMedia.value = null; if (value !== "organization") reset(); }
async function choose(media: ReviewMedia) {
  selected.value = media;
  await nextTick();
  const workspace = document.getElementById("memory-workspace");
  if (workspace) workspace.scrollTop = 0;
  if (window.matchMedia("(max-width: 1000px)").matches) workspace?.scrollIntoView({ block: "start", behavior: "smooth" });
}
function reviewPets(id: number) { reviewFaces(id); }
function reviewFaces(id: number) { tab.value = "faces"; filterMedia.value = id; reset(); }
async function saveFace(face: Subject, ignore = false) {
  if (saving.value[face.key]) return;
  saving.value[face.key] = true; error.value = ""; notice.value = ""; autoLinkedCount.value = 0;
  const choice = ignore ? "ignore" : choices.value[face.key];
  try {
    const assignment = { child_id: choice && choice !== "ignore" ? Number(choice) : null, ignored: choice === "ignore" };
    const response = await put<{ auto_linked?: number; auto_reset?: number }>(`/${face.pet ? "pets" : "faces"}/media/${face.media.id}/confirm`, face.pet ? { index: face.id, ...assignment } : { assignments: [{ face_id: face.id, ...assignment }] });
    notice.value = face.pet ? t("宠物确认已保存，后续候选会参考这些样本。") : response.auto_linked ? t("人物已确认，另自动关联 {n} 张高相似人脸。", { n: response.auto_linked }) : t(ignore ? "已忽略这张脸。" : "人物确认已保存。");
    if (response.auto_reset) notice.value += " " + t("另撤回 {n} 条不再明确匹配的自动关联。", { n: response.auto_reset });
    autoLinkedCount.value = response.auto_linked ?? 0;
    delete choices.value[face.key];
    if (selected.value && (selected.value.id === face.media.id || response.auto_linked || response.auto_reset)) revision.value++;
    await load();
  } catch (e) { error.value = (e as Error).message; }
  finally { saving.value[face.key] = false; }
}
async function scanPets() {
  scanning.value = true; error.value = "";
  try { const result = await post<{ processed: number[] }>("/pets/analyze-next"); notice.value = t("本次已分析 {n} 份影像。", { n: result.processed.length }); await load(); }
  catch (e) { error.value = (e as Error).message; }
  finally { scanning.value = false; }
}
async function scan() {
  if (scanning.value) return;
  scanning.value = true; scanned.value = 0; stopScan.value = false; error.value = ""; notice.value = "";
  let failure = "";
  try {
    for (let batch = 0; batch < 4 && !stopScan.value; batch++) {
      const response = await post<{ processed: number[]; failed: { message: string }[]; remaining: number }>("/faces/analyze-next?limit=5");
      scanned.value += response.processed.length;
      if (response.failed.length) { failure = response.failed.map(f => f.message).join("；"); break; }
      if (!response.remaining || !response.processed.length) break;
    }
    if (active) { notice.value = t("本次已分析 {n} 份影像。", { n: scanned.value }); await load(); if (failure) error.value = failure; }
  } catch (e) { if (active) error.value = (e as Error).message; }
  finally { scanning.value = false; }
}
function next() { history.value.push(cursor.value); cursor.value = nextCursor.value ?? {}; void load(); }
function previous() { cursor.value = history.value.pop() ?? {}; void load(); }
function saved(id: number) { if (selected.value?.id === id) revision.value++; void load(); }
void load(true);
</script>

<template>
  <div class="face-console">
    <header class="console-heading"><div><span class="eyebrow">{{ t("认出家人，留住故事") }}</span><h1>{{ t("人物与宠物确认及智能打标签") }}</h1><p>{{ t("确认人物与宠物，再智能推荐有依据的标签。") }}</p></div><button class="button console-refresh" :aria-label="t('刷新')" :disabled="loading" @click="load(true)"><RefreshCw :size="16" /><span>{{ t("刷新") }}</span></button></header>
    <div class="console-summary" v-if="queue && tab !== 'organization'">
      <div><strong>{{ queue.pending_faces }}</strong><span>{{ t("张脸待确认") }}</span></div>
      <div><strong>{{ pets?.pending_pets ?? 0 }}</strong><span>{{ t("条宠物待确认") }}</span></div>
      <div><strong>{{ queue.unanalysed_photos }}</strong><span>{{ t("份照片待分析") }}</span></div>
      <div><strong>{{ queue.pending_memories }}</strong><span>{{ t("份回忆待补充") }}</span></div>
      <div class="scan-action"><button class="button primary" :disabled="scanning || !queue.enabled || !queue.ready || !queue.unanalysed_photos" @click="scan"><ScanFace :size="17" />{{ t("分析下一批照片") }}</button><button class="button" :disabled="scanning || loading || !pets?.unanalysed_media" @click="scanPets"><PawPrint :size="17" />{{ t("补充宠物识别") }}</button><small>{{ t("每批最多20份，包含实况照片。") }}</small></div>
    </div>
    <p v-if="tab !== 'organization' && queue?.auto_link_enabled" class="muted">{{ t("每次确认人物后会自动整理相似人脸，关联到其他人脸时弹窗提醒；可在已处理项中纠正。") }}</p>
    <p v-if="tab !== 'organization' && queue && (!queue.enabled || !queue.ready)" class="notice">{{ t(queue.message) }}</p>
    <div v-if="scanning" class="scan-progress" role="status"><span>{{ t("已分析 {n} 份，正在处理下一组…", { n: scanned }) }}</span><button class="button small" @click="stopScan = true" :disabled="stopScan">{{ t(stopScan ? "当前一组完成后停止" : "停止后续分析") }}</button></div>
    <p v-if="error" role="alert" class="notice">{{ error }} <button class="button small" :disabled="loading" @click="load(true)">{{ t("重试") }}</button></p>
    <p v-if="notice" role="status" class="console-notice">{{ notice }}</p>
    <div class="console-layout" :class="{ organization: tab === 'organization' }">
      <section class="review-list" :aria-label="t('集中确认队列')">
        <div class="queue-toolbar"><div class="queue-tabs" role="tablist" :aria-label="t('处理内容')"><button role="tab" :aria-selected="tab === 'faces'" @click="switchTab('faces')"><ScanFace :size="16" />{{ t("人物与宠物") }}</button><button role="tab" :aria-selected="tab === 'memories'" @click="switchTab('memories')"><MessageCircle :size="16" />{{ t("智能打标签") }}</button><button role="tab" :aria-selected="tab === 'organization'" @click="switchTab('organization')">{{ t("审核记录") }}</button></div><label v-if="tab !== 'organization'" class="queue-all"><input type="checkbox" v-model="all" @change="reset" />{{ t("含已处理") }}</label></div>
        <div v-if="filterMedia" class="queue-filter"><span>{{ t("只看当前影像的人物与宠物") }}</span><button class="text-button" @click="filterMedia = null; reset()">{{ t("清除筛选") }}</button></div>
        <p v-if="loading" class="muted" role="status">{{ t("正在读取待处理内容…") }}</p>
        <template v-if="tab === 'faces'">
          <div v-if="subjects.length" class="face-grid">
            <article v-for="(face, index) in subjects" :key="face.key" class="review-face" :class="{ selected: selected?.id === face.media.id }">
              <span class="subject-kind"><PawPrint v-if="face.pet" :size="15" /><ScanFace v-else :size="15" />{{ t(face.pet ? "识别到宠物" : "识别到人物") }}</span><div class="review-face-top"><button class="source-thumbnail" :aria-label="t('查看来源照片或视频')" @click="previewing = face"><img class="review-face-image" :src="face.thumbnail" :alt="t(face.pet ? '待确认的狗狗' : '待确认人脸 {n}', { n: index + 1 })" /></button><div><p class="muted">{{ localDate(face.media.timeline_day || face.media.taken_at_local || undefined) }}</p><strong>{{ t(face.ignored ? "已忽略" : face.child_id ? "已确认" : face.pet ? "这只宠物是谁？" : "这张脸是谁？") }}</strong><small v-if="face.auto_assigned">{{ t("已自动关联，可人工纠正") }}</small><small v-if="face.frame_seconds !== null">{{ t("视频 {seconds} 秒", { seconds: face.frame_seconds }) }}</small></div></div>
              <button class="button small source-preview" @click="previewing = face">{{ t(face.media.media_type === "video" || face.frame_seconds != null ? "查看来源视频" : "查看来源照片") }}</button>
              <div class="review-candidates" v-if="face.candidates.length"><button v-for="candidate in face.candidates" :key="candidate.child_id" class="candidate-choice" :class="{ chosen: choices[face.key] === String(candidate.child_id) }" :disabled="saving[face.key]" :aria-label="t(face.pet ? '选择推荐宠物 {name}' : '选择推荐人物 {name}', { name: candidate.name })" @click="choices[face.key] = String(candidate.child_id)"><img :src="candidate.reference_thumbnail" :alt="t('{name} 的参考样本', { name: candidate.name })" /><span>{{ t("可能是 {name}", { name: candidate.name }) }}<small>{{ t("相似度 {score}，供人工判断", { score: candidate.similarity.toFixed(2) }) }}</small></span><Check v-if="choices[face.key] === String(candidate.child_id)" :size="16" /></button></div>
              <p v-if="face.pet" class="muted no-candidate">{{ face.appearance }}</p>
              <p v-if="!face.pet && !face.candidates.length && !face.child_id && !face.ignored" class="muted no-candidate">{{ t("没有足够相似的样本，请选择人物。") }}</p>
              <label class="face-person"><span>{{ t(face.pet ? "关联宠物" : "关联人物") }}</span><select v-model="choices[face.key]" :disabled="saving[face.key]" :aria-label="t(face.pet ? '为宠物 {n} 选择档案' : '为人脸 {n} 选择人物', { n: index + 1 })"><option value="">{{ t("待确认") }}</option><option v-for="person in (face.pet ? dogs : people)" :key="person.id" :value="String(person.id)">{{ person.name }}</option><option value="ignore">{{ t(face.pet ? "忽略" : "忽略这张脸") }}</option></select></label>
              <div class="face-actions"><button class="button primary small" :disabled="saving[face.key] || (!face.auto_assigned && choices[face.key] === (face.ignored ? 'ignore' : String(face.child_id ?? '')))" @click="saveFace(face)">{{ t(face.pet ? "确认宠物" : "确认人物") }}</button><button class="button small" :disabled="saving[face.key] || face.ignored" @click="saveFace(face, true)">{{ t("忽略") }}</button></div>
              <button class="face-context" @click="choose(face.media)">{{ t("智能打标签") }}<ArrowRight :size="14" /></button>
            </article>
          </div>
          <div v-else-if="!loading" class="console-empty"><ScanFace :size="28" /><h2>{{ t("当前没有待确认的人物或宠物") }}</h2><p>{{ t("可分析下一批照片，或使用智能打标签整理标签。") }}</p><button class="button" @click="switchTab('memories')">{{ t("去智能打标签") }}</button></div>
        </template>
        <template v-else-if="tab === 'memories'"><div v-if="memories.length" class="memory-grid"><div v-for="media in memories" :key="media.id" class="memory-pick" :class="{ selected: selected?.id === media.id }"><MediaCard :media="media" thumbnail @open="choose(media)" /><button class="memory-pick-label" @click="choose(media)"><span>{{ media.title || localDate(media.timeline_day || media.taken_at_local || undefined) }}</span><small>{{ t(media.interview_status === 'completed' ? "已保存" : media.interview_status === 'draft' ? "继续完善标签" : "智能推荐标签") }}</small></button></div></div><div v-else-if="!loading" class="console-empty"><MessageCircle :size="28" /><h2>{{ t("当前回忆已处理完成") }}</h2><p>{{ t("可以勾选含已处理，继续查看和补充。") }}</p></div></template>
        <OrganizationReview v-if="tab === 'organization'" @updated="revision++" />
        <div v-if="tab !== 'organization'" class="queue-pagination"><button class="button small" :disabled="loading || !history.length" @click="previous">{{ t("上一页") }}</button><button class="button small" :disabled="loading || !nextCursor" @click="next">{{ t("下一页") }}</button></div>
      </section>
      <aside v-if="tab !== 'organization'" id="memory-workspace" class="memory-workspace" :aria-label="t('当前回忆')">
        <template v-if="selected"><div class="console-preview"><MediaViewer :key="selected.id" :media="selected" /></div><MemoryInterview :media="selected" :revision="revision" @saved="saved" @review-faces="reviewFaces" @review-pets="reviewPets" /></template>
        <div v-else class="workspace-empty"><MessageCircle :size="30" /><h2>{{ t("一起把记忆补完整") }}</h2><p>{{ t("选择一张脸或一份回忆，在这里确认人物、回答问题并保存标签。") }}</p></div>
      </aside>
    </div>
    <MotionDialog :model-value="!!previewing" @update:model-value="(value: boolean) => { if (!value) previewing = undefined }" :title="t('识别来源')" width="900px" destroy-on-close>
      <template v-if="previewing"><p>{{ localDate(previewing.media.timeline_day || undefined) }}<span v-if="previewing.frame_seconds != null"> · {{ t("视频 {seconds} 秒", { seconds: previewing.frame_seconds }) }}</span></p><MediaViewer :key="previewing.key" :media="previewing.media" :initial-seconds="previewing.frame_seconds ?? undefined" /></template>
    </MotionDialog>
    <MotionDialog :model-value="autoLinkedCount > 0" @update:model-value="(value: boolean) => { if (!value) autoLinkedCount = 0 }" :title="t('已自动整理相似人脸')" width="420px">
      <p>{{ t("已将另外 {n} 张明确匹配的人脸关联到对应人物，可在已处理项中查看和修改。", { n: autoLinkedCount }) }}</p>
      <template #footer><button class="button primary" @click="autoLinkedCount = 0">{{ t("知道了") }}</button></template>
    </MotionDialog>
  </div>
</template>

<style scoped>
.source-thumbnail { padding: 0; border: 0; background: none; cursor: pointer; flex-shrink: 0; line-height: 0; }
.subject-kind { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; color: var(--sage); }
.face-console { max-width: 1480px; margin: 0 auto; display: grid; gap: 24px; }
.console-heading { display: flex; justify-content: space-between; align-items: center; gap: 20px; }
.console-heading h1 { font-size: 27px; margin: 8px 0; font-weight: var(--weight-heading); }
.console-heading p { margin: 0; color: var(--muted); line-height: 1.6; }
.console-summary { display: flex; flex-wrap: wrap; gap: 28px; align-items: center; padding: 20px 0; border-block: 1px solid var(--line); }
.console-summary > div { display: grid; gap: 4px; }
.console-summary strong { font-size: 26px; font-weight: var(--weight-medium); font-variant-numeric: tabular-nums; }
.console-summary span, .scan-action small { font-size: 13px; color: var(--muted); }
.console-summary .scan-action { margin-left: auto; gap: 8px; }
.scan-progress { display: flex; align-items: center; gap: 16px; flex-wrap: wrap; }
.console-notice { color: var(--sage); margin: 0; }
.console-layout { display: grid; grid-template-columns: minmax(0, 1.12fr) minmax(350px, 1fr); gap: 28px; align-items: start; }
.console-layout.organization { display: block; }
.review-list, .memory-workspace { min-width: 0; }
.queue-toolbar { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; padding-bottom: 18px; }
.queue-tabs { display: flex; flex-wrap: wrap; gap: 8px; }
.queue-tabs button { display: flex; gap: 6px; align-items: center; padding: 10px 9px; min-height: 44px; border: 0; background: none; border-bottom: 2px solid transparent; font: inherit; cursor: pointer; color: var(--muted); }
.queue-tabs button[aria-selected="true"] { border-color: var(--sage); color: var(--text); }
.queue-all { display: flex; flex-direction: row; align-items: center; gap: 7px; min-height: 44px; font-size: 13px; }
.queue-all input { width: auto; }
.queue-filter { display: flex; gap: 12px; align-items: center; margin-bottom: 14px; font-size: 13px; }
.face-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
.review-face { min-width: 0; display: grid; align-content: start; gap: 14px; padding: 16px; background: var(--surface); border: 1px solid var(--line); border-radius: 12px; }
.review-face.selected { border-color: var(--sage); }
.review-face-top { display: flex; gap: 12px; align-items: center; }
.review-face-image { width: 64px; height: 76px; object-fit: cover; border-radius: 8px; }
.review-face-top p { margin: 0 0 6px; font-size: 12px; }
.review-face-top small { display: block; margin-top: 4px; }
.review-candidates { display: grid; gap: 8px; }
.candidate-choice { display: flex; align-items: center; gap: 8px; width: 100%; text-align: start; background: var(--surface-soft); border: 1px solid transparent; border-radius: 8px; padding: 8px; color: var(--text); cursor: pointer; }
.candidate-choice.chosen { border-color: var(--sage); }
.candidate-choice img { width: 34px; height: 42px; border-radius: 5px; object-fit: cover; }
.candidate-choice > span { flex: 1; min-width: 0; overflow-wrap: anywhere; font-size: 13px; }
.candidate-choice small { display: block; font-size: 12px; color: var(--muted); margin-top: 4px; }
.face-person { display: grid; gap: 7px; font-size: 13px; }
.face-person select { width: 100%; min-height: 44px; }
.face-actions { display: flex; gap: 8px; }
.face-actions .primary { flex: 1; }
.face-context { display: flex; align-items: center; justify-content: space-between; min-height: 44px; gap: 8px; padding: 5px 0 0; border: 0; border-top: 1px solid var(--line); background: none; font: inherit; font-size: 12px; color: var(--muted); cursor: pointer; }
.no-candidate { font-size: 13px; margin: 0; line-height: 1.5; }
.memory-workspace { position: sticky; top: 20px; max-height: calc(100dvh - 40px); overflow-y: auto; overscroll-behavior: contain; padding: 20px; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; scroll-margin-top: 20px; }
.console-preview { margin: -20px -20px 24px; overflow: hidden; border-radius: 13px 13px 0 0; }
.console-preview :deep(.media-viewer-shell:not(.expanded)) { height: 280px; min-height: 0; }
.console-preview :deep(.viewer-toolbar) { padding: 8px 12px; }
.memory-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.memory-pick { min-width: 0; border: 1px solid transparent; border-radius: 12px; overflow: hidden; }
.memory-pick.selected { border-color: var(--sage); }
.memory-pick-label { display: grid; gap: 5px; width: 100%; min-height: 60px; padding: 10px; background: var(--surface); border: 0; color: var(--text); text-align: start; cursor: pointer; }
.memory-pick-label span { overflow-wrap: anywhere; }
.memory-pick-label small { color: var(--muted); }
.console-empty, .workspace-empty { display: grid; justify-items: start; align-content: start; gap: 16px; padding: 28px 12px; color: var(--muted); }
.console-empty h2, .workspace-empty h2 { font-size: 18px; margin: 0; color: var(--text); }
.console-empty p, .workspace-empty p { margin: 0; line-height: 1.7; }
.queue-pagination { display: flex; justify-content: space-between; margin-top: 20px; }
.face-console button { min-height: 44px; }
@media (max-width: 1250px) { .face-grid { grid-template-columns: 1fr; } .console-layout { grid-template-columns: minmax(0, 1fr) minmax(340px, 1.1fr); gap: 20px; } }
@media (max-width: 1000px) { .console-layout { grid-template-columns: 1fr; } .face-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } .console-summary { gap: 18px; flex-wrap: wrap; } .console-summary .scan-action { margin-left: 0; } .memory-workspace { position: static; max-height: none; overflow: visible; } }
@media (max-width: 520px) { .console-heading { align-items: flex-start; } .console-heading h1 { font-size: 23px; } .console-refresh { min-width: 44px; flex-shrink: 0; padding-inline: 12px; } .console-refresh span { display: none; } .console-summary { justify-content: space-between; gap: 16px 10px; } .console-summary strong { font-size: 23px; } .console-summary span { font-size: 12px; } .console-summary .scan-action { width: 100%; } .face-grid { grid-template-columns: 1fr; } .memory-workspace { padding: 16px; } .console-preview { margin: -16px -16px 20px; } .queue-tabs { gap: 2px; } .queue-tabs button { padding-inline: 5px; } }
</style>
