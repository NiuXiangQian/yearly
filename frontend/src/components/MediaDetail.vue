<script setup lang="ts">
import { ref, watch } from "vue";
import {
  Download,
  MapPin,
  Camera,
  ShieldCheck,
  ImageOff,
} from "lucide-vue-next";
import { api, put, del, notify, bytes, localDate } from "../lib/api";
import { useYearly } from "../stores/yearly";
import ChildPicker from "./ChildPicker.vue";
import MediaViewer from "./MediaViewer.vue";
const props = defineProps<{ id: number | null }>(),
  emit = defineEmits(["close", "saved"]);
const yearly = useYearly(),
  media = ref<any>(),
  form = ref<any>({}),
  busy = ref(false);
watch(
  () => props.id,
  async (id, _, onCleanup) => {
    let active = true;
    onCleanup(() => {
      active = false;
    });
    media.value = null;
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
    const { url } = await api(
      `/media/${props.id}/files/${file.id}/url?download=true`,
    );
    const a = document.createElement("a");
    a.href = url;
    a.rel = "noreferrer";
    a.click();
  } catch (e) {
    notify(e);
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
        <h2>{{ media.title || media.batch_name || "珍藏的瞬间" }}</h2>
        <p class="muted">
          {{ localDate(media.taken_at_local) }} ·
          {{
            media.time_source === "file_modified"
              ? "文件修改时间 · 低可信度"
              : media.time_source
          }}
        </p>
        <div class="age-labels">
          <span v-for="c in media.children" :key="c.id"
            >{{ c.name }} · {{ c.age || "年龄未知" }}</span
          >
        </div>
        <form @submit.prevent="save">
          <div class="form-row">
            <label
              >批次名称<input
                v-model="form.batch_name"
                :disabled="!yearly.canEdit"
                maxlength="255" /></label
            ><label
              >归档日期<input
                v-model="form.timeline_date"
                type="date"
                :disabled="!yearly.canEdit"
            /></label>
          </div>
          <label
            >标题<input
              v-model="form.title"
              :disabled="!yearly.canEdit"
              maxlength="255"
              placeholder="给这个瞬间起个名字" /></label
          ><label
            >时光小记<textarea
              v-model="form.remark"
              :disabled="!yearly.canEdit"
              rows="3"
              placeholder="记下照片之外的故事…"
            />
          </label>
          <div class="field-group">
            <span>关联孩子</span
            ><ChildPicker
              v-model="form.child_ids"
              :disabled="!yearly.canEdit"
            />
          </div>
          <div class="form-row">
            <label
              >修正拍摄当地时间<input
                type="datetime-local"
                v-model="form.corrected_taken_at_local"
                :disabled="!yearly.canEdit" /></label
            ><label
              >时区偏移（分钟）<input
                type="number"
                v-model="form.corrected_offset_minutes"
                :disabled="!yearly.canEdit"
                min="-840"
                max="840"
                placeholder="未知留空"
            /></label>
          </div>
          <small class="muted">清空修正时间可恢复原始时间，不会修改文件。</small
          ><label class="checkbox-label"
            ><input
              type="checkbox"
              v-model="form.time_unknown"
              :disabled="!yearly.canEdit"
            />明确标记拍摄时间未知</label
          ><label
            >地点名称<input
              v-model="form.location_name"
              :disabled="!yearly.canEdit"
          /></label>
          <div class="form-row">
            <label
              >纬度<input
                v-model.number="form.latitude"
                type="number"
                step="any"
                min="-90"
                max="90"
                :disabled="!yearly.canEdit" /></label
            ><label
              >经度<input
                v-model.number="form.longitude"
                type="number"
                step="any"
                min="-180"
                max="180"
                :disabled="!yearly.canEdit"
            /></label>
          </div>
          <label
            >自定义标签<ElSelect
              v-model="form.tags"
              multiple
              filterable
              allow-create
              default-first-option
              :disabled="!yearly.canEdit"
              placeholder="输入标签并回车" /></label
          ><button
            v-if="yearly.canEdit"
            class="button primary"
            :disabled="busy"
          >
            保存这份回忆
          </button>
        </form>
        <details>
          <summary>原文件与完整元数据</summary>
          <div v-for="f in media.files" :key="f.id" class="file-record">
            <b>{{ f.original_filename }}</b
            ><small>{{ f.file_role }} · {{ bytes(f.file_size) }}</small
            ><code>SHA-256 {{ f.sha256 }}</code
            ><button class="button small" @click="download(f)">
              <Download :size="14" /> 下载{{
                f.file_role === "preview" ? "预览" : "原件"
              }}
            </button>
          </div>
          <pre>{{ JSON.stringify(media.metadata, null, 2) }}</pre>
        </details>
        <div v-if="yearly.canEdit" class="detail-danger">
          <ElPopconfirm title="移入回收站？原件会继续保留。" @confirm="trash"
            ><template #reference
              ><button class="text-button danger">移入回收站</button></template
            ></ElPopconfirm
          >
        </div>
      </div>
    </div>
    <div v-else class="loading-panel">正在翻开回忆…</div></ElDialog
  >
</template>
