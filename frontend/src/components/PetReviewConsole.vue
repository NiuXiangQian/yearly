<script setup lang="ts">
import { computed, ref, watch, onBeforeUnmount } from "vue";
import { PawPrint, ArrowRight } from "lucide-vue-next";
import { api, post, put, del, localDate } from "../lib/api";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
import type { ReviewMedia } from "../lib/memory-review";
type Dog = { index: number; child_id: number | null; ignored: boolean; thumbnail: string; appearance: string; frame_seconds: number | null;
  candidates: { child_id: number; name: string; similarity: number; reference_thumbnail: string }[] };
type Group = { media: ReviewMedia; dogs: Dog[] };
type Queue = { items: Group[]; pending_pets: number; unanalysed_media: number; next_cursor: number | null };
const props = defineProps<{ all: boolean; mediaId?: number }>();
const emit = defineEmits<{ choose: [media: ReviewMedia]; saved: [id: number] }>();
const yearly = useYearly(), queue = ref<Queue>(), error = ref(""), notice = ref("");
const busy = ref(false), scanning = ref(false), stopping = ref(false), clearing = ref<number>();
const before = ref<number | null>(null), history = ref<(number | null)[]>([]), choices = ref<Record<string, string>>({});
const profiles = computed(() => yearly.children.filter(p => p.profile_type === "pet" && p.species === "狗"));
let active = true;
onBeforeUnmount(() => { active = false; stopping.value = true; });
async function load() {
  busy.value = true; error.value = "";
  const params = new URLSearchParams({ scope: props.all ? "all" : "pending" });
  if (before.value) params.set("before", String(before.value));
  if (props.mediaId) params.set("media_id", String(props.mediaId));
  try {
    queue.value = await api<Queue>(`/pets/review?${params}`);
    for (const group of queue.value.items) for (const dog of group.dogs) {
      const key = `${group.media.id}:${dog.index}`;
      if (!(key in choices.value)) choices.value[key] = dog.ignored ? "ignore" : String(dog.child_id ?? "");
    }
  } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
watch(() => [props.all, props.mediaId], () => { before.value = null; history.value = []; void load(); }, { immediate: true });
async function confirm(group: Group, dog: Dog, ignore = false) {
  busy.value = true; error.value = ""; notice.value = "";
  const key = `${group.media.id}:${dog.index}`, choice = ignore ? "ignore" : choices.value[key];
  try {
    await put(`/pets/media/${group.media.id}/confirm`, { index: dog.index, child_id: choice && choice !== "ignore" ? Number(choice) : null, ignored: choice === "ignore" });
    delete choices.value[key]; notice.value = t("宠物确认已保存，后续候选会参考这些样本。");
    emit("saved", group.media.id); await load();
  } catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
async function scan() {
  scanning.value = true; stopping.value = false; error.value = ""; notice.value = "";
  let count = 0;
  try {
    for (let n = 0; n < 5 && !stopping.value; n++) {
      const result = await post<{ processed: number[] }>("/pets/analyze-next");
      if (!active) break;
      count += result.processed.length;
      if (!result.processed.length) break;
      notice.value = t("本次已分析 {n} 份影像。", { n: count }); await load();
    }
    if (!count) await load();
  } catch (e) { error.value = (e as Error).message; }
  finally { scanning.value = false; }
}
async function clear(id: number) {
  busy.value = true;
  try { await del(`/pets/media/${id}`); clearing.value = undefined; emit("saved", id); await load(); }
  catch (e) { error.value = (e as Error).message; }
  finally { busy.value = false; }
}
function next() { history.value.push(before.value); before.value = queue.value!.next_cursor; void load(); }
function previous() { before.value = history.value.pop() ?? null; void load(); }
</script>

<template>
  <section class="pet-console" :aria-label="t('狗狗确认')">
    <div class="pet-intro"><div><strong>{{ t("认出家里的狗狗") }}</strong><p>{{ t("只检测真实的狗，排除玩偶与衣服图案。确认后建立宠物参考样本。") }}</p></div><PawPrint :size="24" /></div>
    <p class="muted">{{ t("宠物候选依据毛色、耳形等外观描述，不能保证是同一只狗，请人工确认。") }}</p>
    <div class="pet-tools"><span v-if="queue">{{ t("{n} 条宠物待确认", { n: queue.pending_pets }) }} · {{ t("{n} 份含狗线索的影像待分析", { n: queue.unanalysed_media }) }}</span><button class="button small" :disabled="busy || scanning" @click="load">{{ t("刷新") }}</button><button class="button primary" :disabled="busy || scanning || !queue?.unanalysed_media" @click="scan">{{ t("分析狗狗影像") }}</button><button v-if="scanning" class="button small" @click="stopping = true">{{ t(stopping ? '本份完成后停止' : '停止后续分析') }}</button></div>
    <p v-if="scanning" role="status" class="muted">{{ t("正在分析宠物，每批最多5份，视频采用最多6帧抽样。") }}</p>
    <p v-if="error" role="alert" class="notice">{{ error }}</p><p v-if="notice" role="status" class="notice">{{ notice }}</p>
    <div v-for="group in queue?.items" :key="group.media.id" class="pet-group">
      <header><strong>{{ group.media.title || localDate(group.media.timeline_day || group.media.taken_at_local || undefined) }}</strong><button class="text-button" @click="emit('choose', group.media)">{{ t("查看照片与智能标签") }}<ArrowRight :size="14" /></button></header>
      <article v-for="dog in group.dogs.filter(d => all || (d.child_id === null && !d.ignored))" :key="dog.index" class="pet-card">
        <img class="pet-crop" :src="dog.thumbnail" :alt="t('待确认的狗狗')" />
        <div class="pet-fields"><strong>{{ t(dog.ignored ? '已忽略' : dog.child_id ? '已确认宠物' : '这只狗是谁？') }}</strong><small v-if="dog.frame_seconds !== null">{{ t("视频 {seconds} 秒", { seconds: dog.frame_seconds }) }}</small><p>{{ dog.appearance }}</p>
          <button v-for="candidate in dog.candidates" :key="candidate.child_id" class="pet-candidate" :disabled="busy" @click="choices[`${group.media.id}:${dog.index}`] = String(candidate.child_id)"><img :src="candidate.reference_thumbnail" :alt="t('{name} 的参考样本', { name: candidate.name })" /><span>{{ t("可能是 {name}", { name: candidate.name }) }}<small>{{ t("外观描述相似度 {score}，供人工判断", { score: candidate.similarity.toFixed(2) }) }}</small></span></button>
          <p v-if="!dog.candidates.length && !dog.child_id && !dog.ignored" class="muted">{{ t("暂无足够相似的参考，请为清晰影像选择狗狗档案。") }}</p>
          <label>{{ t("关联宠物") }}<select v-model="choices[`${group.media.id}:${dog.index}`]" :disabled="busy"><option value="">{{ t("待确认") }}</option><option v-for="profile in profiles" :key="profile.id" :value="String(profile.id)">{{ profile.name }}</option><option value="ignore">{{ t("忽略") }}</option></select></label>
          <div class="pet-actions"><button class="button primary small" :disabled="busy || choices[`${group.media.id}:${dog.index}`] === (dog.ignored ? 'ignore' : String(dog.child_id ?? ''))" @click="confirm(group, dog)">{{ t("确认宠物") }}</button><button class="button small" :disabled="busy || dog.ignored" @click="confirm(group, dog, true)">{{ t("忽略") }}</button></div>
        </div>
      </article>
      <button v-if="clearing !== group.media.id" class="text-button pet-clear" :disabled="busy" @click="clearing = group.media.id">{{ t("清除这份影像的宠物分析") }}</button><div v-else class="pet-actions"><button class="button small" :disabled="busy" @click="clear(group.media.id)">{{ t("确认清除") }}</button><button class="button small" @click="clearing = undefined">{{ t("取消") }}</button></div>
    </div>
    <p v-if="queue && !queue.items.length && !busy" class="muted">{{ t("当前没有待确认的狗狗，可分析影像或查看已处理项。") }}</p>
    <div class="pet-actions"><button class="button small" :disabled="busy || !history.length" @click="previous">{{ t("上一页") }}</button><button class="button small" :disabled="busy || !queue?.next_cursor" @click="next">{{ t("下一页") }}</button></div>
  </section>
</template>

<style scoped>
.pet-console { display: grid; gap: 16px; min-width: 0; }
.pet-intro, .pet-group > header { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.pet-console p { margin: 0; line-height: 1.65; font-size: 13px; }
.pet-tools, .pet-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.pet-tools > span { flex: 1 1 100%; font-size: 13px; }
.pet-group { padding-block: 18px; border-top: 1px solid var(--line); min-width: 0; }
.pet-group > header { margin-bottom: 12px; flex-wrap: wrap; }
.pet-card { display: grid; grid-template-columns: 90px minmax(0,1fr); gap: 14px; padding-block: 14px; }
.pet-crop { width: 90px; max-height: 130px; object-fit: contain; border-radius: 8px; background: var(--surface); }
.pet-fields { display: grid; gap: 10px; min-width: 0; }
.pet-fields label { display: grid; gap: 6px; }
.pet-fields select { width: 100%; min-height: 44px; }
.pet-candidate { display: flex; align-items: center; gap: 10px; text-align: start; background: var(--surface); color: var(--text); padding: 10px; border: 1px solid var(--line); border-radius: 8px; }
.pet-candidate img { width: 44px; height: 56px; object-fit: contain; }
.pet-candidate small { display: block; line-height: 1.5; color: var(--muted); }
.pet-group .text-button { display: inline-flex; align-items: center; gap: 6px; min-height: 44px; }
@media(max-width: 380px) { .pet-card { grid-template-columns: 1fr; } .pet-crop { width: 110px; } }
</style>
