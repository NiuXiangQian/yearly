<script setup lang="ts">
import { t, ageLabel } from "../lib/i18n";
import AuditHistory from "./AuditHistory.vue";
import DateField from "./DateField.vue";
import { computed, ref, watch } from "vue";
import {
  Download,
  MapPin,
  Camera,
  ShieldCheck,
  ImageOff,
} from "lucide-vue-next";
import { api, post, put, del, notify, bytes, localDate } from "../lib/api";
import type { MediaResource } from "../lib/media-resource";
import { useYearly } from "../stores/yearly";
import ChildPicker from "./ChildPicker.vue";
import MediaViewer from "./MediaViewer.vue";
const historyOpen = ref(false);
const props = defineProps<{ id: number | null }>(),
  emit = defineEmits(["close", "saved"]);
const yearly = useYearly(),
  media = ref<any>(),
  form = ref<any>({}),
  busy = ref(false);
const editable = computed(() => yearly.canEdit && media.value?.can_edit !== false);
const downloadStates = ref<Record<number, MediaResource>>({});
const restoringFile = ref<number | null>(null);
watch(
  () => props.id,
  async (id, _, onCleanup) => {
    let active = true;
    onCleanup(() => {
      active = false;
    });
    media.value = null;
    downloadStates.value = {};
    if (!id) return;
    try {
      const value = await api(`/media/${id}`);
      if (!active) return;
      media.value = value;
      form.value = {
        ...media.value,
        corrected_taken_at_local:
          media.value.corrected_taken_at_local?.slice(0, 16) || null,
      };
    } catch (e) {
      if (active) notify(e);
    }
  },
  { immediate: true },
);
async function save() {
  busy.value = true;
  try {
    await put(`/media/${props.id}`, {
      time_unknown: form.value.time_unknown,
      title: form.value.title,
      share_allowed: form.value.share_allowed,
      batch_name: form.value.batch_name,
      timeline_date: form.value.timeline_date || null,
      remark: form.value.remark,
      location_name: form.value.location_name,
      tags: form.value.tags,
      latitude: form.value.latitude === "" ? null : form.value.latitude,
      longitude: form.value.longitude === "" ? null : form.value.longitude,
      corrected_taken_at_local: form.value.corrected_taken_at_local || null,
      corrected_offset_minutes:
        form.value.corrected_offset_minutes === ""
          ? null
          : form.value.corrected_offset_minutes,
      child_ids: form.value.child_ids,
    });
    emit("saved");
    emit("close");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function download(file: any) {
  try {
    const result = await api<MediaResource>(
      `/media/${props.id}/files/${file.id}/url?download=true`,
    );
    downloadStates.value[file.id] = result;
    if (!result.url) return;
    const a = document.createElement("a");
    a.href = result.url;
    a.rel = "noreferrer";
    a.click();
  } catch (e) {
    notify(e);
  }
}
async function restoreOriginal(file: any) {
  restoringFile.value = file.id;
  try {
    const result = await post<{ status: MediaResource["status"]; message: string }>(
      `/media/${props.id}/files/${file.id}/restore`,
    );
    downloadStates.value[file.id] = { ...result, url: null };
  } catch (e) {
    notify(e);
  } finally {
    restoringFile.value = null;
  }
}
async function trash() {
  try {
    await del(`/media/${props.id}`);
    emit("saved");
    emit("close");
  } catch (e) {
    notify(e);
  }
}
</script>
<template>
  <ElDialog
    append-to-body
    :model-value="!!id"
    width="1080px"
    class="detail-dialog"
    destroy-on-close
    @close="emit('close')"
    ><div v-if="media" class="detail-layout">
      <div class="detail-viewer">
        <MediaViewer :key="media.id" :media="media" />
      </div>
      <div class="detail-info">
        <span class="eyebrow">A MOMENT TO KEEP</span>
        <p v-if="!editable" class="notice">{{ t("已锁定，只能编辑自己添加的内容。") }}</p>
        <p class="muted">{{ t("上传人") }} · {{ media.owner_name || t("历史记录") }}<br />{{ t("修改人") }} · {{ media.updated_by_name || t("暂无记录") }}</p>
        <h2>{{ media.title || media.batch_name || t("珍藏的瞬间") }}</h2>
        <p class="muted">
          {{ localDate(media.taken_at_local) }} ·
          {{
            media.time_source === "file_modified"
              ? t("文件修改时间 · 低可信度")
              : media.time_source
          }}
        </p>
        <div class="age-labels">
          <span v-for="c in media.children" :key="c.id"
            >{{ c.name
            }}<template v-if="c.age"> · {{ ageLabel(c.age) }}</template></span
          >
        </div>
        <details @toggle="historyOpen = ($event.target as HTMLDetailsElement).open"><summary>{{ t("修改日志") }}</summary><AuditHistory v-if="historyOpen" resource-type="media" :resource-id="media.id" /></details>
        <form @submit.prevent="save">
          <label class="checkbox-label"
            ><input
              v-model="form.share_allowed"
              type="checkbox"
              :disabled="!editable"
            />{{ t("允许分享") }}</label
          >
          <p class="muted">
            {{ t("关闭后，此文件不会出现在任何分享链接中。") }}
          </p>
          <div class="form-row">
            <label>
              {{ t("批次名称") }}
              <input
                v-model="form.batch_name"
                :disabled="!editable"
                maxlength="255" /></label
            ><label>
              {{ t("归档日期") }}
              <DateField
                v-model="form.timeline_date"
                type="date"
                :disabled="!editable"
            /></label>
          </div>
          <label>
            {{ t("标题") }}
            <input
              v-model="form.title"
              :disabled="!editable"
              maxlength="255"
              :placeholder="t('给这个瞬间起个名字')" /></label
          ><label>
            {{ t("时光小记") }}
            <textarea
              v-model="form.remark"
              :disabled="!editable"
              rows="3"
              :placeholder="t('记下照片之外的故事…')"
            />
          </label>
          <div class="field-group">
            <span> {{ t("里面都有谁（可多选）") }} </span
            ><ChildPicker
              v-model="form.child_ids"
              :disabled="!editable"
            />
          </div>
          <div class="form-row">
            <label>
              {{ t("修正拍摄当地时间") }}
              <DateField
                type="datetime"
                v-model="form.corrected_taken_at_local"
                :disabled="!editable" /></label
            ><label>
              {{ t("时区偏移（分钟）") }}
              <input
                type="number"
                v-model="form.corrected_offset_minutes"
                :disabled="!editable"
                min="-840"
                max="840"
                :placeholder="t('未知留空')"
            /></label>
          </div>
          <small class="muted">
            {{ t("清空修正时间可恢复原始时间，不会修改文件。") }} </small
          ><label class="checkbox-label"
            ><input
              type="checkbox"
              v-model="form.time_unknown"
              :disabled="!editable"
            />
            {{ t("明确标记拍摄时间未知") }} </label
          ><label>
            {{ t("地点名称") }}
            <input v-model="form.location_name" :disabled="!editable"
          /></label>
          <div class="form-row">
            <label>
              {{ t("纬度") }}
              <input
                v-model.number="form.latitude"
                type="number"
                step="any"
                min="-90"
                max="90"
                :disabled="!editable" /></label
            ><label>
              {{ t("经度") }}
              <input
                v-model.number="form.longitude"
                type="number"
                step="any"
                min="-180"
                max="180"
                :disabled="!editable"
            /></label>
          </div>
          <label>
            {{ t("自定义标签") }}
            <ElSelect
              v-model="form.tags"
              multiple
              filterable
              allow-create
              default-first-option
              :disabled="!editable"
              :placeholder="t('输入标签并回车')" /></label
          ><button
            v-if="editable"
            class="button primary"
            :disabled="busy"
          >
            {{ t("保存这份回忆") }}
          </button>
        </form>
        <details>
          <summary>{{ t("原文件与完整元数据") }}</summary>
          <div v-for="f in media.files" :key="f.id" class="file-record">
            <b>{{ f.original_filename }}</b
            ><small>{{ f.file_role }} · {{ bytes(f.file_size) }}</small
            ><code>SHA-256 {{ f.sha256 }}</code
            ><button class="button small" @click="download(f)">
              <Download :size="14" /> {{ t("下载") }}
              {{ f.file_role === "preview" ? t("预览") : t("原件") }}
            </button>
            <p v-if="downloadStates[f.id]?.status === 'archived' || downloadStates[f.id]?.status === 'restoring'" class="notice" role="status">
              {{ t(downloadStates[f.id]?.message || "原件正在解冻") }}
              <button v-if="downloadStates[f.id]?.status === 'archived'" class="button small" :disabled="restoringFile === f.id" @click="restoreOriginal(f)">
                {{ t("申请解冻原件 · 通常48小时") }}
              </button>
            </p>
          </div>
          <pre>{{ JSON.stringify(media.metadata, null, 2) }}</pre>
        </details>
        <div v-if="editable" class="detail-danger">
          <ElPopconfirm
            :title="t('移入回收站？原件会继续保留。')"
            @confirm="trash"
            ><template #reference
              ><button class="text-button danger">
                {{ t("移入回收站") }}
              </button></template
            ></ElPopconfirm
          >
        </div>
      </div>
    </div>
    <div v-else class="loading-panel">{{ t("正在翻开回忆…") }}</div></ElDialog
  >
</template>
