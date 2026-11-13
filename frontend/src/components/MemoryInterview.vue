<script setup lang="ts">
import { computed, reactive, watch, onBeforeUnmount } from "vue";
import { api, post, put } from "../lib/api";
import { t } from "../lib/i18n";
import type { InterviewState, ReviewMedia } from "../lib/memory-review";
import ChildPicker from "./ChildPicker.vue";
const props = defineProps<{ media: ReviewMedia; revision: number }>();
const emit = defineEmits<{ saved: [id: number]; reviewFaces: [id: number]; reviewPets: [id: number] }>();
type Draft = { data?: InterviewState; answer: string; addition: string; extraTag: string; tags: string[];
  people: number[]; peopleEdited: boolean; busy: boolean; error: string; notice: string; tagsEdited: boolean; noteEdited: boolean };
const drafts = reactive<Record<number, Draft>>({});
const current = computed(() => drafts[props.media.id]);
const evidenceLabels = { visual: "画面描述", answer: "你的回答", existing: "已有记录" };
let active = true;
onBeforeUnmount(() => { active = false; });
function accept(draft: Draft, data: InterviewState, generated = false) {
  const firstLoad = !draft.data;
  draft.data = data;
  if (!draft.peopleEdited) draft.people = [...data.media.child_ids];
  if (generated || firstLoad) {
    if (!draft.tagsEdited) draft.tags = data.suggestions?.tags.map(tag => tag.name) ?? [];
    if (!draft.noteEdited) draft.addition = data.suggestions?.story ?? "";
  }
}
async function load() {
  const id = props.media.id;
  if (!drafts[id]) drafts[id] = { answer: "", addition: "", extraTag: "", tags: [], people: [], peopleEdited: false, busy: false, error: "", notice: "", tagsEdited: false, noteEdited: false };
  const draft = drafts[id];
  draft.busy = true; draft.error = "";
  try { accept(draft, await api<InterviewState>(`/memory-interviews/${id}`)); }
  catch (e) { draft.error = (e as Error).message; }
  finally { draft.busy = false; }
}
watch(() => [props.media.id, props.revision], load, { immediate: true });
async function prepare() {
  const draft = current.value, id = props.media.id;
  if (draft.busy) return;
  draft.busy = true; draft.error = ""; draft.notice = "";
  try { accept(draft, await post<InterviewState>(`/memory-interviews/${id}/prepare`, { refresh: !!draft.data?.outdated || draft.data?.status === 'completed' }), true); }
  catch (e) { draft.error = (e as Error).message; }
  finally { draft.busy = false; }
}
async function reply() {
  const draft = current.value, id = props.media.id;
  if (draft.busy || !draft.answer.trim()) return;
  draft.busy = true; draft.error = ""; draft.notice = "";
  try {
    accept(draft, await post<InterviewState>(`/memory-interviews/${id}/reply`, { answer: draft.answer }), true);
    draft.answer = "";
  } catch (e) { draft.error = (e as Error).message; }
  finally { draft.busy = false; }
}
function addTag() {
  const draft = current.value, tag = draft.extraTag.trim();
  if (tag && !draft.tags.includes(tag) && !draft.data?.media.tags.includes(tag)) draft.tags.push(tag);
  draft.extraTag = ""; draft.tagsEdited = true;
}
async function savePeople() {
  const draft = current.value, id = props.media.id;
  if (draft.busy) return;
  draft.busy = true; draft.error = "";
  try {
    const data = await put<InterviewState>(`/memory-interviews/${id}/people`, { child_ids: draft.people });
    draft.peopleEdited = false; accept(draft, data); draft.notice = t("人物关联已保存，人脸身份仍可逐一确认。");
    if (active) emit("saved", id);
  } catch (e) { draft.error = (e as Error).message; }
  finally { draft.busy = false; }
}
async function analyzePets() {
  const draft = current.value, id = props.media.id;
  if (draft.busy) return;
  draft.busy = true; draft.error = ""; draft.notice = "";
  try {
    const data = await post<{ dogs: unknown[] }>(`/pets/media/${id}/analyze`);
    if (data.dogs.length && active) emit("reviewPets", id);
    else draft.notice = t("未检测到真实的狗，可继续手动关联宠物。");
  } catch (e) { draft.error = (e as Error).message; }
  finally { draft.busy = false; }
}
async function save() {
  const draft = current.value, id = props.media.id;
  if (draft.busy) return;
  draft.busy = true; draft.error = ""; draft.notice = "";
  try {
    accept(draft, await post<InterviewState>(`/memory-interviews/${id}/apply`, { tags: draft.tags, remark_addition: draft.addition }));
    draft.addition = ""; draft.tags = []; draft.tagsEdited = false; draft.noteEdited = false;
    draft.notice = t("标签和小记已保存。");
    if (active) emit("saved", id);
  } catch (e) { draft.error = (e as Error).message; }
  finally { draft.busy = false; }
}
</script>

<template>
  <section v-if="current" class="memory-interview" :aria-label="t('智能打标签')" :aria-busy="current.busy">
    <header class="interview-heading"><div><span class="eyebrow">{{ t("根据画面与补充信息推荐标签") }}</span><h2>{{ t("智能打标签") }}</h2></div><span v-if="current.data?.status === 'completed'" class="interview-done">{{ t("已保存") }}</span></header>
    <p v-if="current.error" role="alert" class="notice">{{ current.error }} <button v-if="!current.data" class="button small" @click="load">{{ t("重新加载") }}</button></p>
    <p v-if="current.busy" role="status" class="muted">{{ t("正在整理这份回忆…") }}</p>
    <template v-if="current.data">
      <p v-if="current.data.confirmed_people.length" class="confirmed-people">{{ t("已确认人物") }} · {{ current.data.confirmed_people.join("、") }}</p>
      <p v-if="current.data.confirmed_pets?.length" class="confirmed-people">{{ t("已确认宠物") }} · {{ current.data.confirmed_pets.join("、") }}</p>
      <button class="button small" :disabled="current.busy" @click="analyzePets">{{ t("查找这份影像中的狗狗") }}</button>
      <div class="interview-people"><strong>{{ t("这份影像里都有谁？") }}</strong><ChildPicker v-model="current.people" :disabled="current.busy" @update:model-value="current.peopleEdited = true" /><button v-if="current.peopleEdited" class="button small" :disabled="current.busy" @click="savePeople">{{ t("保存人物关联") }}</button><small class="muted">{{ t("可补充未检测到的人物或宠物，单张人脸的身份仍需确认。") }}</small></div>
      <div v-if="current.data.identity_questions.length" class="identity-questions">
        <p v-for="q in current.data.identity_questions" :key="q.face_id">{{ q.question }}</p>
        <button class="button small" :disabled="current.busy" @click="emit('reviewFaces', media.id)">{{ t("先确认这里面有谁") }}</button>
      </div>
      <details v-if="current.data.description" class="interview-source"><summary>{{ t("查看已有画面描述") }}</summary><p>{{ current.data.description }}</p></details>
      <p v-if="current.data.outdated" class="notice">{{ t("人物或影像内容有更新，可更新提问和标签建议。") }}</p>
      <button v-if="!current.data.suggestions || current.data.outdated" class="button primary" :disabled="current.busy" @click="prepare">{{ t(current.data.suggestions ? "更新标签建议" : "生成推荐标签") }}</button>
      <button v-else-if="current.data.status === 'completed'" class="button" :disabled="current.busy" @click="prepare">{{ t("补充信息，完善标签") }}</button>
      <template v-if="current.data.suggestions">
        <div class="interview-messages" role="log" :aria-label="t('标签补充信息')">
          <div v-for="(message, index) in current.data.messages" :key="index" class="interview-message" :class="message.role"><small>{{ t(message.role === 'user' ? '你的补充' : '标签助手') }}</small><p>{{ message.content }}</p></div>
        </div>
        <div v-if="current.data.suggestions.options.length" class="interview-options"><button v-for="option in current.data.suggestions.options" :key="option" class="button small" :disabled="current.busy" @click="current.answer = option">{{ option }}</button></div>
        <form class="interview-answer" @submit.prevent="reply">
          <label>{{ t("补充标签依据") }}<textarea v-model="current.answer" rows="3" maxlength="2000" :disabled="current.busy" :placeholder="t('补充场景、活动等信息，帮助完善标签。')" /></label>
          <button class="button" :disabled="current.busy || !current.answer.trim()">{{ t("补充信息并更新标签") }}</button>
        </form>
        <section class="interview-tags" :aria-label="t('推荐标签')">
          <h3>{{ t("推荐标签") }}</h3><p class="muted">{{ t("勾选想保存的标签，也可以补充自己的标签。") }}</p>
          <label v-for="tag in current.data.suggestions.tags" :key="tag.name" class="tag-recommendation">
            <input v-model="current.tags" type="checkbox" :value="tag.name" :disabled="current.busy" @change="current.tagsEdited = true" />
            <span><strong>{{ tag.name }}</strong><small>{{ t(evidenceLabels[tag.source]) }} · {{ tag.evidence }}</small></span>
          </label>
          <p v-if="!current.data.suggestions.tags.length" class="muted">{{ t("现有信息还不足以推荐新标签，可以继续补充或手动添加。") }}</p>
          <div class="tag-entry"><input v-model="current.extraTag" maxlength="80" :disabled="current.busy" :aria-label="t('补充标签')" :placeholder="t('补充标签')" @keydown.enter="if (!$event.isComposing) { $event.preventDefault(); addTag(); }" /><button class="button small" :disabled="current.busy || !current.extraTag.trim()" @click="addTag">{{ t("添加") }}</button></div>
          <div v-if="current.tags.length" class="selected-tags"><span v-for="tag in current.tags" :key="tag">{{ tag }}<button :aria-label="t('移除标签 {name}', { name: tag })" :disabled="current.busy" @click="current.tags = current.tags.filter(v => v !== tag); current.tagsEdited = true">×</button></span></div>
          <p v-if="current.data.media.tags.length" class="muted">{{ t("已有标签") }} · {{ current.data.media.tags.join("、") }}</p>
        </section>
        <details v-if="current.data.media.remark"><summary>{{ t("查看原有小记") }}</summary><p class="saved-remark">{{ current.data.media.remark }}</p></details>
        <label>{{ t("补充到时光小记") }}<textarea v-model="current.addition" rows="3" maxlength="4000" :disabled="current.busy" :placeholder="t('你的回答作为小记草稿，可修改后保存。')" @input="current.noteEdited = true" /></label>
        <button v-if="current.noteEdited && current.data.suggestions.story && current.data.suggestions.story !== current.addition" class="button small" :disabled="current.busy" @click="current.addition = current.data.suggestions.story; current.noteEdited = false">{{ t("使用新生成的小记草稿") }}</button>
        <p class="muted">{{ t("补充内容将追加保存，原有小记与人物关联保留。") }}</p>
        <button class="button primary" :disabled="current.busy || current.data.status === 'completed'" @click="save">{{ t("保存标签与小记") }}</button>
        <p v-if="current.notice" role="status">{{ current.notice }}</p>
      </template>
      <p class="interview-cost muted">{{ t("智能打标签与宠物分析共用AI额度；人脸匹配在本地运行。") }}</p>
    </template>
  </section>
</template>

<style scoped>
.memory-interview { display: grid; gap: 16px; min-width: 0; }
.interview-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.interview-heading h2 { margin: 4px 0 0; font-size: 20px; }
.memory-interview p { margin: 0; line-height: 1.65; overflow-wrap: anywhere; }
.memory-interview label { display: grid; gap: 8px; }
.interview-done, .confirmed-people { color: var(--sage); font-size: 13px; }
.interview-people { display: grid; gap: 10px; padding-block: 12px; border-bottom: 1px solid var(--line); }
.identity-questions { background: var(--surface-soft); border-radius: 10px; padding: 14px; display: grid; gap: 10px; }
.interview-source { font-size: 13px; color: var(--muted); }
.interview-source p { padding-top: 8px; }
.interview-messages { display: grid; gap: 14px; }
.interview-message small { color: var(--muted); display: block; margin-bottom: 5px; }
.interview-message.user { margin-left: 24px; padding: 12px 14px; background: var(--surface-soft); border-radius: 10px; }
.interview-options { display: flex; flex-wrap: wrap; gap: 8px; }
.interview-answer { display: grid; gap: 10px; }
.interview-tags { border-top: 1px solid var(--line); padding-top: 20px; display: grid; gap: 12px; }
.interview-tags h3 { font-size: 16px; margin: 0; }
.memory-interview .tag-recommendation { display: flex; flex-direction: row; align-items: flex-start; gap: 10px; min-height: 44px; cursor: pointer; }
.tag-recommendation input { width: auto; flex-shrink: 0; margin-top: 5px; }
.tag-recommendation small { display: block; color: var(--muted); margin-top: 3px; overflow-wrap: anywhere; }
.tag-entry { display: flex; gap: 8px; }
.tag-entry input { min-width: 0; flex: 1; }
.selected-tags { display: flex; flex-wrap: wrap; gap: 8px; }
.selected-tags > span { display: inline-flex; align-items: center; border-radius: 8px; background: var(--sage-light); padding-left: 10px; overflow-wrap: anywhere; }
.selected-tags button { min-width: 36px; min-height: 36px; border: 0; background: none; color: inherit; cursor: pointer; }
.saved-remark { white-space: pre-wrap; padding-top: 8px; }
.interview-cost { font-size: 12px; }
.memory-interview button { min-height: 44px; }
</style>
