<script setup lang="ts">
import { ref } from "vue";
import { Film, FileImage, FolderOpen, Plus, UploadCloud } from "lucide-vue-next";
import { t } from "../lib/i18n";

defineProps<{
  accept: string;
  hasFiles: boolean;
  nativePicker: boolean;
  busy: boolean;
  parsing: boolean;
  progress: number;
  filename: string;
  index: number;
  total: number;
}>();
const emit = defineEmits<{
  files: [files: FileList | null, input?: HTMLInputElement];
  livePhoto: [];
}>();
const dragging = ref(false);
const pickers = [
  { icon: Plus, mode: "photos", multiple: true, label: "选择文件" },
  { icon: FileImage, mode: "single", multiple: false, label: "单张选择" },
  { icon: FolderOpen, mode: "files", multiple: true, label: "从文件导入" },
] as const;

function selected(event: Event) {
  const input = event.target as HTMLInputElement;
  emit("files", input.files, input);
}
</script>

<template>
  <section
    class="dropzone upload-intake"
    :class="{ dragging }"
    :aria-busy="parsing"
    aria-labelledby="upload-intake-heading"
    @dragover.prevent="dragging = !parsing && !busy"
    @dragleave.prevent="dragging = false"
    @drop.prevent="
      dragging = false;
      emit('files', $event.dataTransfer?.files || null);
    "
  >
    <div class="intake-intro">
      <span class="intake-icon"><UploadCloud :size="25" aria-hidden="true" /></span>
      <div>
        <h2 id="upload-intake-heading">{{ t("选取原片") }}</h2>
        <p>{{ t("支持多选 · HEIC、JPG、RAW、MOV、MP4 与 Live Photo") }}</p>
      </div>
    </div>
    <div class="picker-actions">
      <button v-if="nativePicker" type="button" class="button primary" :disabled="parsing || busy" @click="emit('livePhoto')">
        <Film :size="16" aria-hidden="true" /> {{ t("选择实况照片并上传") }}
      </button>
      <label
        v-for="picker in pickers"
        :key="picker.mode"
        class="button file-picker"
        :class="{ primary: picker.mode === 'photos' && !nativePicker, 'main-picker': picker.mode === 'photos' }"
      >
        <component :is="picker.icon" :size="16" aria-hidden="true" />
        {{ t(picker.mode === "photos" && hasFiles ? "继续添加" : picker.label) }}
        <input
          type="file"
          :multiple="picker.multiple"
          :accept="picker.mode === 'files' ? undefined : accept"
          :aria-label="t(picker.mode === 'photos' && hasFiles ? '继续添加' : picker.label)"
          :disabled="parsing || busy"
          @cancel="emit('files', null)"
          @change="selected"
        />
      </label>
    </div>
    <div v-if="parsing || filename" class="parse-progress" role="status">
      <span>
        {{ parsing ? t("正在读取原文件…") : filename }}
        <template v-if="parsing && total"> {{ index }} / {{ total }} · {{ filename }}</template>
        <template v-if="!parsing || total"> · {{ progress }}%</template>
      </span>
      <ElProgress v-if="!parsing || total" :percentage="progress" :show-text="false" />
    </div>
  </section>
</template>

<style scoped>
.upload-intake {
  display: grid;
  grid-template-columns: minmax(180px, 1fr) auto;
  gap: 14px 24px;
  padding: 24px;
  text-align: start;
  background: var(--surface-soft);
}
.upload-intake.dragging {
  background: var(--sage-light);
}
.intake-intro {
  display: flex;
  align-items: center;
  gap: 14px;
  min-width: 0;
}
.intake-icon {
  display: grid;
  flex: 0 0 46px;
  height: 46px;
  place-items: center;
  border-radius: 9px;
  color: var(--sage);
  background: var(--surface);
}
.intake-intro p {
  margin-top: 3px;
  color: var(--muted);
  font-size: 13px;
}
.picker-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.file-picker {
  position: relative;
  min-height: 44px;
  margin: 0;
  flex-direction: row;
}
.file-picker input {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  padding: 0;
  opacity: 0;
  cursor: pointer;
}
.file-picker:focus-within {
  outline: 2px solid var(--sage);
  outline-offset: 3px;
}
.file-picker:has(input:disabled) {
  opacity: 0.5;
  pointer-events: none;
}
.parse-progress {
  grid-column: 1 / -1;
  max-width: none;
  margin: 0;
}
.parse-progress span {
  overflow-wrap: anywhere;
}
@media (max-width: 940px) {
  .upload-intake {
    grid-template-columns: minmax(0, 1fr);
  }
}
@media (max-width: 700px) {
  .upload-intake {
    padding: 16px;
  }
  .picker-actions .file-picker {
    flex: 1 1 auto;
    white-space: normal;
  }
  .picker-actions .main-picker {
    flex-basis: 100%;
  }
}
</style>
