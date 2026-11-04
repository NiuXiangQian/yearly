<script setup lang="ts">
import { t } from "../lib/i18n";
import DateField from "./DateField.vue";
import { ref, watch } from "vue";
import { ArrowUp, ArrowDown, X, Image, BookHeart } from "lucide-vue-next";
import { api, post, put, del, notify } from "../lib/api";
import { useYearly } from "../stores/yearly";
import ChildPicker from "./ChildPicker.vue";
import MediaDetail from "./MediaDetail.vue";
const props = defineProps<{
    open: boolean;
    eventId?: number | null;
    mediaIds?: number[];
    initialDate?: string;
  }>(),
  emit = defineEmits(["close", "saved"]);
const mediaOptions = ref<any[]>([]),
  candidate = ref<number | null>(null);
async function searchMedia(q: string) {
  try {
    mediaOptions.value = (
      await api("/media?" + new URLSearchParams({ q, page_size: "30" }))
    ).items;
  } catch (e) {
    notify(e);
  }
}
function addMedia(id: number) {
  if (!form.value.media_ids.includes(id)) form.value.media_ids.push(id);
  const item = mediaOptions.value.find((m) => m.id === id);
  if (item && !media.value.some((m) => m.id === id)) media.value.push(item);
  if (!form.value.cover_media_id) form.value.cover_media_id = id;
  candidate.value = null;
}
const yearly = useYearly(),
  form = ref<any>({}),
  media = ref<any[]>([]),
  busy = ref(false),
  previewId = ref<number | null>(null);
watch(
  () => props.open,
  async (open) => {
    if (!open) return;
    busy.value = true;
    try {
      if (props.eventId) {
        const data = await api(`/events/${props.eventId}`);
        form.value = { ...data };
        media.value = data.media;
      } else {
        media.value = await Promise.all(
          (props.mediaIds || []).map((id) => api(`/media/${id}`)),
        );
        const dates = media.value
          .map((m) => m.taken_at_local)
          .filter(Boolean)
          .sort();
        form.value = {
          title: "",
          share_allowed: true,
          content: "",
          child_ids: [...yearly.selected],
          media_ids: [...(props.mediaIds || [])],
          cover_media_id: props.mediaIds?.[0] || null,
          start_at: props.initialDate || dates[0] || null,
          end_at: dates.at(-1) || props.initialDate || null,
        };
      }
      form.value.start_at = form.value.start_at?.slice(0, 16) || null;
      form.value.end_at = form.value.end_at?.slice(0, 16) || null;
    } catch (e) {
      notify(e);
    } finally {
      busy.value = false;
    }
  },
);
async function save() {
  busy.value = true;
  try {
    const data = {
      title: form.value.title,
      share_allowed: form.value.share_allowed,
      content: form.value.content,
      start_at: form.value.start_at || null,
      end_at: form.value.end_at || null,
      cover_media_id: form.value.cover_media_id,
      media_ids: form.value.media_ids,
      child_ids: form.value.child_ids,
    };
    props.eventId
      ? await put(`/events/${props.eventId}`, data)
      : await post("/events", data);
    await yearly.load();
    emit("saved");
    emit("close");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
function move(i: number, delta: number) {
  const ids = form.value.media_ids;
  [ids[i], ids[i + delta]] = [ids[i + delta], ids[i]];
}
function remove(id: number) {
  form.value.media_ids = form.value.media_ids.filter((n: number) => n !== id);
  if (form.value.cover_media_id === id)
    form.value.cover_media_id = form.value.media_ids[0] || null;
}
async function trash() {
  try {
    await del(`/events/${props.eventId}`);
    await yearly.load();
    emit("saved");
    emit("close");
  } catch (e) {
    notify(e);
  }
}
</script>
<template>
  <ElDialog
    :model-value="open"
    :title="eventId ? t('成长日记') : t('写一篇成长日记')"
    width="760px"
    @close="emit('close')"
    ><form v-if="form.child_ids" @submit.prevent="save" class="event-form">
      <span class="eyebrow">LITTLE MOMENTS, BIG MEMORIES</span
      ><label>
        {{ t("日记标题") }}
        <input
          v-model="form.title"
          required
          maxlength="255"
          :disabled="!yearly.canEdit"
          :placeholder="t('第一次、一起、又长大了一点…')" /></label
      ><label>
        {{ t("我们的故事") }}
        <textarea
          v-model="form.content"
          rows="5"
          :disabled="!yearly.canEdit"
          :placeholder="
            t('把照片之外的心情也记下来。没有照片，也能写下难忘的一天。')
          "
        />
      </label>
      <div class="form-row">
        <label>
          {{ t("开始时间") }}
          <DateField
            type="datetime"
            v-model="form.start_at"
            :disabled="!yearly.canEdit" /></label
        ><label>
          {{ t("结束时间") }}
          <DateField
            type="datetime"
            v-model="form.end_at"
            :disabled="!yearly.canEdit"
        /></label>
      </div>
      <label class="checkbox-label"
        ><input
          v-model="form.share_allowed"
          type="checkbox"
          :disabled="!yearly.canEdit"
        />{{ t("允许分享") }}</label
      >
      <p class="muted">{{ t("关闭后，此日记不会出现在任何分享链接中。") }}</p>
      <div class="field-group">
        <span> {{ t("一起经历的孩子与宠物") }} </span
        ><ChildPicker v-model="form.child_ids" :disabled="!yearly.canEdit" />
      </div>
      <div class="section-heading">
        <h3>
          {{ t("这篇日记里的回忆") }} <small>{{ form.media_ids.length }}</small>
        </h3>
        <span class="muted"> {{ t("显示全部事件媒体 · 独立保存关联") }} </span>
      </div>
      <p v-if="!form.media_ids.length" class="muted">
        {{ t("一篇纯文字日记。也可以在时间线多选照片后创建日记。") }}
      </p>
      <div v-for="(id, i) in form.media_ids" :key="id" class="event-media-row">
        <Image :size="18" /><button
          class="text-button"
          type="button"
          @click="previewId = id"
        >
          {{
            media.find((m) => m.id === id)?.title || t("影像 #") + id
          }}</button
        ><span v-if="yearly.canEdit" class="event-order"
          ><button
            type="button"
            class="icon-button"
            :disabled="i === 0"
            :aria-label="t('向前排序')"
            @click="move(Number(i), -1)"
          >
            <ArrowUp :size="16" /></button
          ><button
            type="button"
            class="icon-button"
            :disabled="i === form.media_ids.length - 1"
            :aria-label="t('向后排序')"
            @click="move(Number(i), 1)"
          >
            <ArrowDown :size="16" /></button
          ><button
            type="button"
            class="icon-button"
            :aria-label="t('解除媒体关联')"
            @click="remove(id)"
          >
            <X :size="16" /></button
        ></span>
      </div>
      <label v-if="yearly.canEdit">
        {{ t("添加已有影像") }}
        <ElSelect
          v-model="candidate"
          filterable
          remote
          :remote-method="searchMedia"
          :placeholder="t('搜索影像标题并添加')"
          @visible-change="(v: boolean) => v && searchMedia('')"
          @change="addMedia"
          ><ElOption
            v-for="m in mediaOptions"
            :key="m.id"
            :value="m.id"
            :label="m.title || t('影像 #') + m.id" /></ElSelect></label
      ><label v-if="form.media_ids.length">
        {{ t("日记封面") }}
        <select v-model="form.cover_media_id" :disabled="!yearly.canEdit">
          <option :value="null">{{ t("无封面") }}</option>
          <option v-for="id in form.media_ids" :key="id" :value="id">
            {{ media.find((m) => m.id === id)?.title || t("影像 #") + id }}
          </option>
        </select></label
      >
      <div class="dialog-actions">
        <ElPopconfirm
          v-if="eventId && yearly.canEdit"
          :title="t('删除这篇日记？关联原件会继续保留。')"
          @confirm="trash"
          ><template #reference
            ><button type="button" class="text-button danger">
              {{ t("删除日记") }}
            </button></template
          ></ElPopconfirm
        ><button type="button" class="button" @click="emit('close')">
          {{ yearly.canEdit ? t("取消") : t("关闭") }}</button
        ><button v-if="yearly.canEdit" class="button primary" :disabled="busy">
          <BookHeart :size="16" />{{
            busy ? t("正在保存…") : t("珍藏这篇日记")
          }}
        </button>
      </div>
    </form>
    <MediaDetail :id="previewId" @close="previewId = null"
  /></ElDialog>
</template>
