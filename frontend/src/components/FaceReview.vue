<script setup lang="ts">
import MotionDialog from "./MotionDialog.vue";
import { computed, ref, watch, onBeforeUnmount } from "vue";
import { api, post, put, del } from "../lib/api";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";

type Candidate = { child_id: number; name: string; similarity: number; reference_thumbnail: string };
type Face = { id: number; thumbnail: string; child_id: number | null; ignored: boolean; frame_seconds: number | null; candidates: Candidate[] };
type FaceState = { enabled: boolean; ready: boolean; message: string; analyzed: boolean; refresh_supported?: boolean; reference_people: number; faces: Face[]; child_ids: number[]; auto_linked?: number; auto_reset?: number };
const props = defineProps<{ mediaId: number; linkedIds: number[] }>();
const emit = defineEmits<{ updated: [ids: number[]]; processing: [value: boolean] }>();
const yearly = useYearly();
const open = ref(false), busy = ref(false), error = ref(""), notice = ref("");
const state = ref<FaceState>();
const choices = ref<Record<number, string>>({});
const clearing = ref(false), autoLinkedCount = ref(0);
watch(busy, value => emit("processing", value));
let active = true;
onBeforeUnmount(() => { active = false; emit("processing", false); });
const people = computed(() => yearly.children.filter(p => p.profile_type !== "pet"));
const changed = computed(() => state.value?.faces.some(f => choices.value[f.id] !== (f.ignored ? "ignore" : String(f.child_id ?? ""))));

function apply(value: FaceState, sync = false) {
  if (!active) return;
  if (sync) {
    const old = new Set(state.value?.child_ids ?? []), next = new Set(value.child_ids);
    emit("updated", [...new Set([...props.linkedIds.filter(id => !old.has(id) || next.has(id)), ...value.child_ids.filter(id => !old.has(id))])]);
  }
  state.value = value;
  choices.value = Object.fromEntries(value.faces.map(f => [f.id, f.ignored ? "ignore" : String(f.child_id ?? "")]));
}
async function load() {
  busy.value = true; error.value = "";
  try { apply(await api<FaceState>(`/faces/media/${props.mediaId}`)); }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function toggle() {
  open.value = !open.value;
  if (open.value && !state.value) await load();
}
async function analyze(refresh = false) {
  busy.value = true; error.value = ""; notice.value = "";
  try { apply(await post<FaceState>(`/faces/media/${props.mediaId}/analyze`, { refresh }), true); }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function confirm() {
  busy.value = true; error.value = ""; notice.value = "";
  const assignments = state.value!.faces.filter(f => choices.value[f.id] !== (f.ignored ? "ignore" : String(f.child_id ?? ""))).map(f => ({ face_id: f.id, child_id: choices.value[f.id] && choices.value[f.id] !== "ignore" ? Number(choices.value[f.id]) : null, ignored: choices.value[f.id] === "ignore" }));
  try {
    const response = await put<FaceState>(`/faces/media/${props.mediaId}/confirm`, { assignments });
    apply(response, true);
    autoLinkedCount.value = response.auto_linked ?? 0;
    notice.value = t("人物已确认，另自动关联 {n} 张高相似人脸。", { n: response.auto_linked ?? 0 });
    if (response.auto_reset) notice.value += " " + t("另撤回 {n} 条不再明确匹配的自动关联。", { n: response.auto_reset });
  } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function clear() {
  busy.value = true; error.value = ""; notice.value = "";
  try { apply(await del(`/faces/media/${props.mediaId}`), true); clearing.value = false; }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
</script>

<template>
  <section class="face-review" :aria-label="t('人脸匹配')">
    <button type="button" class="face-heading" :aria-expanded="open" @click="toggle">
      <span>{{ t("人脸匹配") }}</span><span class="muted">{{ t(open ? "收起" : "确认这里面有谁") }}</span>
    </button>
    <div v-if="open" class="face-content" :aria-busy="busy">
      <p class="muted">{{ t("选择每张脸对应的人物。确认后会关联档案，并作为后续匹配的参考；候选不会自动保存。") }}</p>
      <p v-if="busy" role="status">{{ t("正在处理人脸，请稍候…") }}</p>
      <p v-if="error" class="notice" role="alert">{{ error }} <button v-if="!state" type="button" class="button small" :disabled="busy" @click="load">{{ t("重新加载") }}</button></p>
      <template v-if="state">
        <p v-if="!state.enabled || !state.ready" class="muted">{{ t(state.message) }}</p>
        <button v-if="!state.analyzed" type="button" class="button" :disabled="busy || !state.enabled || !state.ready" @click="analyze()">{{ t("查找这份影像中的人脸") }}</button>
        <template v-else>
          <template v-if="state.refresh_supported">
            <button type="button" class="button" :disabled="busy || changed || !state.enabled || !state.ready" @click="analyze(true)">{{ t("重新查找人脸") }}</button>
            <p class="muted">{{ t("保留已确认和忽略的记录，补查遗漏的人脸。请先保存当前选择。") }}</p>
          </template>
          <p v-if="!state.faces.length" class="muted">{{ t("未检测到清晰人脸，可继续手动关联人物。") }}</p>
          <p v-else-if="!state.reference_people" class="muted">{{ t("还没有其他影像的已确认样本，请先为人脸选择人物。") }}</p>
          <div v-for="(face, i) in state.faces" :key="face.id" class="face-row">
            <img :src="face.thumbnail" :alt="t('待确认人脸 {n}', { n: i + 1 })" class="face-crop" />
            <div class="face-fields">
              <label :for="`face-${face.id}`">{{ t("人脸 {n}", { n: i + 1 }) }}<small v-if="face.frame_seconds != null"> · {{ t("视频 {seconds} 秒", { seconds: face.frame_seconds }) }}</small></label>
              <select :id="`face-${face.id}`" v-model="choices[face.id]" :disabled="busy">
                <option value="">{{ t("待确认") }}</option>
                <option v-for="person in people" :key="person.id" :value="String(person.id)">{{ person.name }}</option>
                <option value="ignore">{{ t("忽略这张脸") }}</option>
              </select>
              <p v-if="!face.child_id && !face.ignored && !face.candidates.length" class="muted">{{ t("没有足够相似的已确认样本，请手动选择。") }}</p>
              <div v-for="candidate in face.candidates" :key="candidate.child_id" class="face-candidate">
                <img :src="candidate.reference_thumbnail" :alt="t('{name} 的参考样本', { name: candidate.name })" />
                <div><span>{{ t("可能是 {name}", { name: candidate.name }) }}</span><small class="muted">{{ t("相似度 {score}，供人工判断", { score: candidate.similarity.toFixed(2) }) }}</small></div>
                <button type="button" class="button small" :disabled="busy || choices[face.id] === String(candidate.child_id)" @click="choices[face.id] = String(candidate.child_id)">{{ t("选择") }}</button>
              </div>
            </div>
          </div>
          <button v-if="state.faces.length" type="button" class="button primary" :disabled="busy || !changed" @click="confirm">{{ t("确认人物") }}</button>
          <p v-if="notice" role="status">{{ notice }}</p>
          <div class="face-clear">
            <button v-if="!clearing" type="button" class="button small" :disabled="busy" @click="clearing = true">{{ t("清除本影像的人脸样本") }}</button>
            <template v-else><p>{{ t("清除后将移除这些匹配样本及其新增的人物关联，手动关联保留。") }}</p><button type="button" class="button small danger" :disabled="busy" @click="clear">{{ t("清除样本") }}</button><button type="button" class="button small" :disabled="busy" @click="clearing = false">{{ t("取消") }}</button></template>
          </div>
        </template>
      </template>
    </div>
    <MotionDialog :model-value="autoLinkedCount > 0" @update:model-value="(value: boolean) => { if (!value) autoLinkedCount = 0 }" :title="t('已自动整理相似人脸')" width="420px">
      <p>{{ t("已将另外 {n} 张明确匹配的人脸关联到对应人物，可在已处理项中查看和修改。", { n: autoLinkedCount }) }}</p>
      <template #footer><button class="button primary" @click="autoLinkedCount = 0">{{ t("知道了") }}</button></template>
    </MotionDialog>
  </section>
</template>

<style scoped>
.face-review { border-block: 1px solid var(--line); padding-block: 12px; }
.face-heading { display: flex; justify-content: space-between; align-items: center; gap: 12px; width: 100%; min-height: 44px; background: none; border: 0; color: inherit; text-align: start; cursor: pointer; font: inherit; }
.face-content { display: grid; gap: 12px; padding-top: 8px; }
.face-content p { margin: 0; font-size: 13px; line-height: 1.6; }
.face-row { display: grid; grid-template-columns: 64px minmax(0, 1fr); gap: 12px; padding-block: 12px; }
.face-crop { width: 64px; height: 76px; object-fit: cover; border-radius: 8px; }
.face-fields { display: grid; gap: 8px; min-width: 0; }
.face-fields select { width: 100%; min-height: 44px; }
.face-fields label { overflow-wrap: anywhere; }
.face-candidate { display: flex; align-items: center; gap: 8px; min-width: 0; }
.face-candidate img { width: 40px; height: 48px; object-fit: cover; border-radius: 6px; }
.face-candidate > div { flex: 1; min-width: 0; overflow-wrap: anywhere; font-size: 13px; }
.face-candidate small { display: block; }
.face-candidate button { min-height: 44px; flex-shrink: 0; }
.face-clear { padding-top: 8px; }
.face-clear .button { margin: 4px 8px 0 0; }
@media (max-width: 360px) { .face-row { grid-template-columns: 48px minmax(0, 1fr); gap: 8px; } .face-crop { width: 48px; height: 60px; } .face-candidate { flex-wrap: wrap; } }
</style>
