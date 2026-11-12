<script setup lang="ts">
import MotionDialog from "../components/MotionDialog.vue";
import { t } from "../lib/i18n";
import DateField from "../components/DateField.vue";
import { ref, computed, onMounted, onBeforeUnmount } from "vue";
import { useRoute } from "vue-router";
import {
  UploadCloud,
  FileImage,
  CheckCircle2,
  ShieldCheck,
  Link2,
  X,
  RefreshCw,
  ArrowRight,
  Film,
  Plus,
  GripVertical,
  Settings2,
  ChevronUp,
  ChevronDown,
  Trash2,
  FolderOpen,
  ClipboardPaste,
} from "lucide-vue-next";
import { useYearly } from "../stores/yearly";
import { api, post, notify, bytes } from "../lib/api";
import { inspectFile, type Inspected } from "../lib/metadata";
import { directUpload } from "../lib/upload";
import { iosLivePhotoBridge, pickIOSLivePhoto } from "../lib/ios-live-photo";
import ChildPicker from "../components/ChildPicker.vue";
const yearly = useYearly(),
  route = useRoute(),
  queue = ref<any[]>([]),
  duplicateNames = ref<string[]>([]),
  kids = ref<number[]>([]),
  parsing = ref(false),
  busy = ref(false),
  hashProgress = ref(0),
  parsingName = ref(""),
  resumable = ref<any[]>([]),
  dragging = ref(false),
  metadataItem = ref<any>(null),
  resumeTarget = ref<any>(null),
  resumeInput = ref<HTMLInputElement>();
const importMessage = ref(""),
  importErrors = ref<string[]>([]),
  readingIndex = ref(0),
  readingTotal = ref(0);
const nativePicker = !!iosLivePhotoBridge();
const nativeImport = new AbortController();
let nextItemId = 0;
const batchName = ref(""),
  targetFolder = ref<any>(null),
  archiveDate = ref(
    typeof route.query.date === "string" ? route.query.date : "",
  ),
  editingItem = ref<any>(null),
  draggedId = ref(""),
  customOrder = ref(false),
  dateReview = ref<any[] | null>(null);
function fileDay(item: any): string | null {
  if (item.time_unknown) return null;
  return (
    (
      item.corrected_taken_at_local || item.original.original_taken_at_local
    )?.slice(0, 10) || null
  );
}
const dateGroups = computed(() => {
  const groups = new Map<string, any[]>();
  for (const item of dateReview.value || []) {
    const day = fileDay(item);
    if (item.tasks || !day || day === archiveDate.value) continue;
    if (!groups.has(day)) groups.set(day, []);
    groups.get(day)!.push(item);
  }
  return [...groups].sort(([a], [b]) => a.localeCompare(b));
});
function confirmDates(move: boolean) {
  const targets = dateReview.value!;
  dateReview.value = null;
  void uploadAll(targets, move);
}
const selectedItems = computed(() =>
  queue.value.filter((item) => item.selected),
);
const pendingSelected = computed(() =>
  selectedItems.value.filter((item) => item.status !== "complete"),
);
const totalBytes = computed(() =>
  queue.value.reduce(
    (sum, item) => sum + item.original.file.size + (item.live?.file.size || 0),
    0,
  ),
);
const completeCount = computed(
  () => queue.value.filter((item) => item.status === "complete").length,
);
function selectAll(checked: boolean) {
  queue.value.forEach((item) => {
    item.selected = checked;
  });
}
function moveItem(item: any, offset: number) {
  const index = queue.value.indexOf(item);
  const target = index + offset;
  if (target < 0 || target >= queue.value.length) return;
  customOrder.value = true;
  queue.value.splice(index, 1);
  queue.value.splice(target, 0, item);
}
function dropItem(target: any) {
  const source = queue.value.find((item) => item.id === draggedId.value);
  if (!source || source === target || busy.value || parsing.value) return;
  customOrder.value = true;
  const index = queue.value.indexOf(target);
  queue.value.splice(queue.value.indexOf(source), 1);
  queue.value.splice(index, 0, source);
  draggedId.value = "";
}
const accepted =
  "image/*,video/*,.jpg,.jpeg,.png,.heic,.heif,.webp,.dng,.cr2,.cr3,.nef,.arw,.orf,.rw2,.raf,.mp4,.mov";
onMounted(async () => {
  try {
    await yearly.load();
    if (typeof route.query.folder === "string") {
      targetFolder.value = await api(`/folders/${route.query.folder}`);
      archiveDate.value = targetFolder.value.timeline_day;
    }
    const preference = localStorage.getItem("yearly-upload-children");
    const saved = JSON.parse(preference || "[]");
    const initialKids = yearly.selected?.length
      ? yearly.selected
      : preference !== null
        ? saved
        : yearly.children.length === 1
          ? [yearly.children[0].id]
          : [];
    kids.value = initialKids.filter((id: number) =>
      yearly.children.some((c) => c.id === id),
    );
    await loadTasks();
  } catch (e) {
    notify(e);
  }
});
async function loadTasks() {
  resumable.value = await api("/uploads");
}
function fileSpec(item: Inspected, role = "original") {
  return {
    original_filename: item.file.name,
    mime_type:
      item.file.type ||
      (/\.(mov|mp4)$/i.test(item.file.name)
        ? "video/" + (/\.mov$/i.test(item.file.name) ? "quicktime" : "mp4")
        : "application/octet-stream"),
    file_size: item.file.size,
    ...item.hash,
    file_role: role,
  };
}
function enqueue(original: Inspected, live: Inspected | null, pasted = false) {
  queue.value.push({
    id: String(++nextItemId),
    selected: true,
    original,
    live,
    preview: null,
    pasted,
    child_ids: [...kids.value],
    title: "",
    location_name: "",
    corrected_taken_at_local: null,
    corrected_offset_minutes: null,
    time_unknown:
      (pasted || !!live) &&
      (original.time_source === "file_modified" ||
        original.time_source === "unknown"),
    status: "ready",
    progress: 0,
    error: "",
    tasks: null,
    previewUrl: original.video ? "" : URL.createObjectURL(original.file),
  });
  return queue.value[queue.value.length - 1];
}
async function importIOSLivePhoto() {
  if (!yearly.canEdit || parsing.value || busy.value || dateReview.value) return;
  parsing.value = true;
  parsingName.value = t("正在从 iPhone 相册读取实况照片…");
  readingIndex.value = readingTotal.value = 0;
  hashProgress.value = 0;
  importMessage.value = "";
  importErrors.value = [];
  let item;
  try {
    const files = await pickIOSLivePhoto(nativeImport.signal);
    if (!files) return;
    nativeImport.signal.throwIfAborted();
    readingTotal.value = 2;
    readingIndex.value = 1;
    parsingName.value = files.original.name;
    const original = await inspectFile(
      files.original,
      (n) => (hashProgress.value = n),
      { hasFileModified: false },
    );
    nativeImport.signal.throwIfAborted();
    readingIndex.value = 2;
    hashProgress.value = 0;
    parsingName.value = files.video.name;
    const video = await inspectFile(
      files.video,
      (n) => (hashProgress.value = n),
      { hasFileModified: false },
    );
    nativeImport.signal.throwIfAborted();
    if (original.video || !video.video) throw new Error("Invalid Live Photo pair");
    // PhotoKit selected both resources from the same asset, even if EXIF has no pair ID.
    item = queue.value.find(
      (q) =>
        q.original.hash.sha256 === original.hash.sha256 &&
        q.live?.hash.sha256 === video.hash.sha256,
    ) || enqueue(original, video);
  } catch (error) {
    if (!nativeImport.signal.aborted) {
      importMessage.value = t(
        error instanceof Error && error.message === "tooLarge"
          ? "实况照片超过原生导入的 128 MiB 限制。请从文件导入原片。"
          : "无法读取完整的实况照片。请确认原片可用后重试。",
      );
    }
    return;
  } finally {
    parsing.value = false;
    parsingName.value = "";
  }
  if (item.status !== "complete") await uploadAll([item]);
}
async function addFiles(
  files: FileList | File[] | null,
  source?: HTMLInputElement,
  pasted = false,
) {
  if (parsing.value || busy.value) return;
  const selected = Array.from(files || []);
  if (!selected.length) {
    importMessage.value = t(
      "没有收到文件。相册未能完成时，可以在下方粘贴照片，或从文件导入原片。",
    );
    return;
  }
  parsing.value = true;
  importMessage.value = "";
  importErrors.value = [];
  readingIndex.value = 0;
  readingTotal.value = selected.length;
  try {
    for (const file of selected) {
      readingIndex.value++;
      parsingName.value = file.name;
      hashProgress.value = 0;
      let inspected: Inspected;
      try {
        inspected = await inspectFile(file, (n) => (hashProgress.value = n));
      } catch {
        importErrors.value.push(file.name);
        continue;
      }
      if (
        queue.value.some(
          (q) => q.original.hash.sha256 === inspected.hash.sha256,
        )
      )
        continue;
      enqueue(inspected, null, pasted);
    }
    // Pair only an explicit shared metadata identifier, never a coincidental filename.
    for (const item of [...queue.value]) {
      if (
        item.status !== "ready" || item.tasks || item.original.video ||
        !item.original.pairId || item.live
      ) continue;
      const movie = queue.value.find(
        (q) =>
          q.original.video &&
          /\.mov$/i.test(q.original.file.name) &&
          q.original.pairId === item.original.pairId &&
          q.status === "ready" &&
          !q.tasks,
      );
      if (movie) {
        item.live = movie.original;
        remove(movie);
      }
    }
  } finally {
    parsing.value = false;
    parsingName.value = "";
    if (source) source.value = "";
  }
}
function pastePhotos(event: ClipboardEvent) {
  if (parsing.value || busy.value) return;
  const files = Array.from(event.clipboardData?.files || []).filter((file) =>
    file.type.startsWith("image/"),
  );
  if (!files.length) {
    importMessage.value = t(
      "没有收到可粘贴的照片。请在“照片”App 的分享菜单中选择“拷贝照片”，再回到这里粘贴。",
    );
    return;
  }
  void addFiles(files, undefined, true);
}
function remove(item: any) {
  if (item.previewUrl) URL.revokeObjectURL(item.previewUrl);
  queue.value = queue.value.filter((q) => q.id !== item.id);
}
function pair(item: any, id: string) {
  const movie = queue.value.find((q) => q.id === id);
  if (!movie) return;
  item.live = movie.original;
  remove(movie);
}
function unpair(item: any) {
  const inspected = item.live;
  item.live = null;
  queue.value.push({
    id: String(++nextItemId),
    selected: true,
    original: inspected,
    live: null,
    preview: null,
    child_ids: [...item.child_ids],
    title: "",
    location_name: "",
    corrected_taken_at_local: null,
    corrected_offset_minutes: null,
    time_unknown: false,
    status: "ready",
    progress: 0,
    error: "",
    tasks: null,
    previewUrl: "",
  });
}
async function addPreview(item: any, e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0];
  if (!file) return;
  try {
    item.preview = await inspectFile(file);
  } catch (error) {
    notify(error);
  }
}
function applyKids() {
  localStorage.setItem("yearly-upload-children", JSON.stringify(kids.value));
  for (const item of selectedItems.value)
    if (!item.tasks) item.child_ids = [...kids.value];
}
async function uploadAll(targets = pendingSelected.value, moveDates?: boolean) {
  if (!yearly.canEdit || busy.value || !targets.length) return;
  if (route.query.folder && !targetFolder.value) {
    notify(new Error(t("文件夹尚未加载或已删除，请返回时间线重新选择")));
    return;
  }
  if (
    moveDates === undefined &&
    archiveDate.value &&
    targets.some(
      (item) =>
        !item.tasks && fileDay(item) && fileDay(item) !== archiveDate.value,
    )
  ) {
    dateReview.value = [...targets];
    return;
  }
  busy.value = true;
  duplicateNames.value = [];
  localStorage.setItem("yearly-upload-children", JSON.stringify(kids.value));
  try {
    for (const item of targets) {
      if (item.status === "complete") continue;
      item.status = "uploading";
      item.error = "";
      try {
        if (!item.tasks) {
          const o = item.original;
          const data = await post("/uploads", {
            folder_id:
              targetFolder.value &&
              !(
                moveDates &&
                fileDay(item) &&
                fileDay(item) !== targetFolder.value.timeline_day
              )
                ? targetFolder.value.id
                : null,
            batch_name: batchName.value.trim(),
            timeline_date:
              moveDates && fileDay(item)
                ? fileDay(item)
                : archiveDate.value || null,
            time_unknown: item.time_unknown,
            media_type: item.live ? "live_photo" : o.video ? "video" : "photo",
            files: [
              fileSpec(o),
              ...(item.live ? [fileSpec(item.live, "live_video")] : []),
              ...(item.preview ? [fileSpec(item.preview, "preview")] : []),
            ],
            metadata: {
              original: o.raw,
              live_video: item.live?.raw,
              preview: item.preview?.raw,
              parse_status: o.raw.parse_status,
              parse_error: o.raw.parse_error,
            },
            child_ids: item.child_ids,
            title: item.title,
            location_name: item.location_name,
            original_taken_at_local: o.original_taken_at_local,
            original_offset_minutes: o.original_offset_minutes,
            time_source: o.time_source,
            time_confidence: o.time_confidence,
            latitude: o.latitude,
            longitude: o.longitude,
            altitude: o.altitude,
            width: o.width,
            height: o.height,
            duration_ms: o.duration_ms,
            device_make: o.device_make,
            device_model: o.device_model,
            corrected_taken_at_local: item.corrected_taken_at_local || null,
            corrected_offset_minutes:
              item.corrected_offset_minutes === ""
                ? null
                : item.corrected_offset_minutes,
          });
          item.tasks = data.tasks;
          item.media_id = data.media_id;
          item.timeline_day = data.timeline_day;
          item.dateMoved =
            !data.duplicate &&
            !!moveDates &&
            !!fileDay(item) &&
            fileDay(item) !== archiveDate.value;
          item.duplicate = !!data.duplicate;
          if (item.duplicate) duplicateNames.value.push(item.original.file.name);
          item.notice = data.notice || "";
        }
        for (let i = 0; i < item.tasks.length; i++) {
          const task = item.tasks[i],
            file =
              task.file_role === "original"
                ? item.original
                : task.file_role === "live_video"
                  ? item.live
                  : item.preview;
          await directUpload(
            task,
            file,
            (n) =>
              (item.progress = Math.round(
                ((i + n / 100) / item.tasks.length) * 100,
              )),
          );
        }
        item.status = "complete";
        item.progress = 100;
      } catch (e) {
        item.status = "failed";
        item.error = e instanceof Error ? e.message : t("上传失败");
      }
    }
    // Only override capture-time order when the user explicitly rearranges the queue.
    const days = new Map<string, number[]>();
    for (const item of queue.value.filter(
      (item) =>
        customOrder.value &&
        item.status === "complete" &&
        item.media_id &&
        !item.duplicate,
    )) {
      const key = item.timeline_day || "unknown";
      if (!days.has(key)) days.set(key, []);
      days.get(key)!.push(item.media_id);
    }
    for (const ids of days.values()) {
      if (ids.length > 1)
        await post("/media/reorder", {
          media_ids: ids.slice(0, -1),
          target_id: ids[ids.length - 1],
          placement: "before",
        });
    }
    await yearly.load();
    await loadTasks();
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function resumeFile(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0],
    task = resumeTarget.value;
  if (!file || !task) return;
  busy.value = true;
  parsingName.value = file.name;
  try {
    const item = await inspectFile(file, (n) => (hashProgress.value = n));
    await directUpload(task, item, (n) => (hashProgress.value = n));
    await yearly.load();
    await loadTasks();
    notifySuccess.value = true;
  } catch (error) {
    notify(error);
  } finally {
    busy.value = false;
    parsingName.value = "";
    if (resumeInput.value) resumeInput.value.value = "";
  }
}
const notifySuccess = ref(false);
onBeforeUnmount(() => {
  nativeImport.abort();
  queue.value.forEach((q) => q.previewUrl && URL.revokeObjectURL(q.previewUrl));
});
</script>
<template>
  <div class="upload-page">
    <div class="page-heading">
      <div>
        <span class="eyebrow">KEEP TODAY FOR TOMORROW</span>
        <h1>{{ t("把一段时光，一起收藏。") }}</h1>
        <p>{{ t("给这批回忆起个名字，选好照片与视频，就可以开始。") }}</p>
      </div>
      <RouterLink to="/" class="button"
        ><ArrowRight :size="16" /> {{ t("返回时间线") }}
      </RouterLink>
    </div>
    <div v-if="!yearly.canEdit" class="notice">
      {{ t("当前账户为只读访客，请联系家庭管理员获得编辑权限。") }}
    </div>
    <template v-else>
      <section class="panel batch-settings">
        <div class="form-row">
          <label>
            {{ t("这批回忆的名字") }}
            <input
              v-model="batchName"
              maxlength="255"
              :placeholder="t('例如：出生第一天、第一次去海边')"
              :disabled="busy"
          /></label>
          <label>
            {{ t("归档到哪一天") }}
            <DateField
              v-model="archiveDate"
              type="date"
              :disabled="busy || !!targetFolder"
            /><small>{{
              archiveDate
                ? t("本批文件将追加到这一天，原始拍摄时间单独保留。")
                : t("留空时，每份文件按自己的拍摄日期归档。")
            }}</small></label
          >
        </div>
        <p v-if="targetFolder" class="muted">
          {{ t("追加到文件夹：") }}{{ targetFolder.name }} ·
          {{ targetFolder.timeline_day }}
        </p>
        <div class="batch-children">
          <span> {{ t("里面都有谁（可多选）") }} </span
          ><ChildPicker
            :model-value="kids"
            :disabled="busy || parsing"
            @update:model-value="
              (ids: number[]) => {
                kids = ids;
                applyKids();
              }
            "
          />
          <small class="muted">{{
            kids.length
              ? t("已自动应用到所选待上传文件")
              : t("未关联人物与宠物：仅出现在全部人物与宠物中")
          }}</small>
        </div>
      </section>
      <div
        class="dropzone compact-dropzone"
        :class="{ dragging }"
        @dragover.prevent="dragging = true"
        @dragleave.prevent="dragging = false"
        @drop.prevent="
          dragging = false;
          addFiles($event.dataTransfer?.files || null);
        "
      >
        <UploadCloud :size="30" />
        <div>
          <h2>
            {{ parsing ? t("正在读取原文件…") : t("拖入这一批照片与视频") }}
          </h2>
          <p>{{ t("支持多选 · HEIC、JPG、RAW、MOV、MP4 与 Live Photo") }}</p>
        </div>
        <div class="picker-actions">
          <button
            v-if="nativePicker"
            type="button"
            class="button primary"
            :disabled="parsing || busy"
            @click="importIOSLivePhoto"
          >
            <Film :size="16" />{{ t("选择实况照片并上传") }}
          </button>
          <label class="button primary file-picker main-picker">
            <Plus :size="16" />{{ queue.length ? t("继续添加") : t("选择文件") }}
            <input
              type="file"
              multiple
              :accept="accepted"
              :aria-label="queue.length ? t('继续添加') : t('选择文件')"
              :disabled="parsing || busy"
              @cancel="addFiles(null)"
              @change="addFiles(($event.target as HTMLInputElement).files, $event.target as HTMLInputElement)"
            />
          </label>
          <label class="button file-picker">
            <FileImage :size="16" />{{ t("单张选择") }}
            <input
              type="file"
              :accept="accepted"
              :aria-label="t('单张选择')"
              :disabled="parsing || busy"
              @cancel="addFiles(null)"
              @change="addFiles(($event.target as HTMLInputElement).files, $event.target as HTMLInputElement)"
            />
          </label>
          <label class="button file-picker">
            <FolderOpen :size="16" />{{ t("从文件导入") }}
            <input
              type="file"
              multiple
              :aria-label="t('从文件导入')"
              :disabled="parsing || busy"
              @cancel="addFiles(null)"
              @change="addFiles(($event.target as HTMLInputElement).files, $event.target as HTMLInputElement)"
            />
          </label>
        </div>
        <div v-if="parsing || parsingName" class="parse-progress">
          <span>
            <template v-if="parsing && readingTotal">{{ readingIndex }} / {{ readingTotal }} · </template>
            {{ parsingName }}
            <template v-if="!parsing || readingTotal"> · {{ hashProgress }}%</template>
          </span>
          <ElProgress v-if="!parsing || readingTotal" :percentage="hashProgress" :show-text="false" />
        </div>
      </div>
      <p class="notice">{{ t("实况照片需同时导入照片和配套 MOV 才能播放；相册选择或粘贴可能只提供静态照片。") }}</p>
      <section class="live-import-guide">
        <h2><Film :size="18" />{{ t("导入实况照片") }}</h2>
        <p>{{ t("Mac：在“照片”App 选中照片 → 文件 → 导出 → 导出未修改的原片，再把导出的照片和 MOV 一起拖入这里。") }}</p>
        <p>{{ t("直接从 Mac“照片”拖到网页通常只有静态副本，不包含动态视频。照片 App 里的 LIVE 标记不代表网页收到了动态原件。") }}</p>
        <small>{{ t("配对成功后，上传列表会显示 LIVE；没有显示时，请先检查是否同时选中了 MOV。") }}</small>
      </section>
      <section class="paste-import">
        <h2><ClipboardPaste :size="18" />{{ t("相册卡住？直接粘贴照片") }}</h2>
        <p id="paste-instructions">{{
          t("在“照片”App 中选择照片 → 分享 → 拷贝照片，再回到下面的框内长按，选择“粘贴”。")
        }}</p>
        <div
          class="paste-target"
          role="textbox"
          :aria-label="t('粘贴照片')"
          aria-describedby="paste-instructions paste-limitations"
          :aria-disabled="parsing || busy"
          :contenteditable="!parsing && !busy"
          :tabindex="parsing || busy ? -1 : 0"
          :data-placeholder="t('长按此处，选择“粘贴”')"
          @paste.prevent="pastePhotos"
          @beforeinput.prevent
          @drop.prevent
        ></div>
        <small id="paste-limitations">{{
          t("粘贴得到的是系统提供的副本，可能缺少拍摄日期或 Live Photo 动态部分；缺少拍摄日期时标为未知。需要相机原件时，请从文件导入。")
        }}</small>
      </section>
      <div v-if="duplicateNames.length" class="duplicate-notice notice" role="alert">
        <strong>{{ t("发现重复文件，已跳过上传") }} · {{ duplicateNames.length }}</strong>
        <p>{{ duplicateNames.slice(0, 5).join("、") }}{{ duplicateNames.length > 5 ? " …" : "" }}</p>
        <span>{{ t("原件不会再次上传，已有照片仍可在时间线查看。其他文件继续上传。") }}</span>
      </div>
      <p v-if="importMessage" class="notice" role="status">{{ importMessage }}</p>
      <div v-if="importErrors.length" class="notice" role="alert">
        <strong>{{ t("以下文件未能读取，其余文件已继续处理：") }}</strong>
        <ul>
          <li v-for="name in importErrors" :key="name">{{ name }}</li>
        </ul>
        <p>{{ t("请先将这些原片下载到“我的 iPhone”，再从文件导入。") }}</p>
      </div>
      <details class="upload-tip">
        <summary>
          <ShieldCheck :size="14" /> {{ t("原件保存与 iPhone 导入提示") }}
        </summary>
        <p>
          {{
            t(
              "文件将按所选原始字节直接上传。iPhone 相册可能提供转换或编辑版本，如需相机原件，请先导出“未修改的原片”到文件 App，再从这里导入。Live Photo 可在文件详情中配对。",
            )
          }}
        </p>
      </details>
      <section v-if="queue.length" class="panel upload-queue">
        <div class="queue-heading">
          <div>
            <h2>{{ batchName || t("本批回忆") }}</h2>
            <span
              >{{ queue.length }} {{ t("份回忆 ·") }} {{ bytes(totalBytes)
              }}<template v-if="completeCount">
                {{ t("· 已完成") }} {{ completeCount }}</template
              ></span
            >
          </div>
          <button
            class="button primary"
            :disabled="busy || parsing || !pendingSelected.length"
            @click="uploadAll()"
          >
            <UploadCloud :size="16" />{{
              busy
                ? t("正在上传…")
                : t("上传所选 {p0} 项", { p0: pendingSelected.length })
            }}
          </button>
        </div>
        <div class="queue-tools">
          <label class="checkbox-label"
            ><input
              type="checkbox"
              :checked="selectedItems.length === queue.length"
              :indeterminate="
                selectedItems.length > 0 && selectedItems.length < queue.length
              "
              :disabled="busy || parsing"
              @change="selectAll(($event.target as HTMLInputElement).checked)"
            />
            {{ t("全选") }}
          </label>
          <span> {{ t("已选") }} {{ selectedItems.length }} {{ t("项") }} </span
          ><span class="queue-sort-hint">
            {{ t("拖动手柄或使用箭头调整顺序") }}
          </span>
          <button
            class="text-button"
            :disabled="busy || parsing || !selectedItems.length"
            @click="[...selectedItems].forEach(remove)"
          >
            <Trash2 :size="14" /> {{ t("移除所选") }}
          </button>
        </div>
        <div class="queue-list">
          <article
            v-for="(item, index) in queue"
            :key="item.id"
            class="upload-file-row"
            :class="{
              selected: item.selected,
              'is-dragging': draggedId === item.id,
            }"
            @dragover.prevent
            @drop.prevent="dropItem(item)"
          >
            <button
              class="icon-button drag-handle"
              :draggable="!busy && !parsing"
              :disabled="busy || parsing"
              :aria-label="t('拖动文件排序')"
              @dragstart="
                draggedId = item.id;
                $event.dataTransfer?.setData('text/plain', item.id);
              "
              @dragend="draggedId = ''"
            >
              <GripVertical :size="17" />
            </button>
            <input
              class="row-checkbox"
              type="checkbox"
              v-model="item.selected"
              :aria-label="t('选择 {p0}', { p0: item.original.file.name })"
              :disabled="busy || parsing"
            />
            <div class="file-thumb">
              <img
                v-if="item.previewUrl"
                :src="item.previewUrl"
                alt=""
                @error="
                  ($event.target as HTMLImageElement).style.display = 'none'
                "
              /><Film v-if="item.original.video" :size="22" /><FileImage
                v-else
                :size="22"
              />
            </div>
            <div class="file-summary numeric">
              <h3>
                {{ item.title || item.original.file.name }}
              </h3>
              <p v-if="item.live || (!item.original.video && item.original.pairId) || item.pasted" class="file-badges">
                <span v-if="item.live" class="chip">LIVE</span>
                <span v-else-if="!item.original.video && item.original.pairId" class="chip">{{ t("LIVE · 缺少动态文件") }}</span>
                <span v-if="item.pasted" class="chip">{{ t("粘贴副本") }}</span>
              </p>
              <p>
                {{ bytes(item.original.file.size) }} ·
                {{
                  fileDay(item) || t("拍摄日期未知")
                }}<span v-if="!item.time_unknown && item.original.time_confidence === 'low'">
                  {{ t("· 日期待确认") }}
                </span>
              </p>
              <p v-if="item.status === 'failed'" class="file-error">
                {{ t(item.error) }}
              </p>
              <p v-if="!item.original.video && item.original.pairId && !item.live" class="muted">
                {{ t("仅收到实况照片的静态部分，上传后无法播放。请同时导入配套 MOV 原件。") }}
              </p>
              <p v-if="item.notice" class="muted">{{ t(item.notice) }}</p>
              <p v-if="item.dateMoved" class="success-text">
                {{ t("已归档到") }} {{ item.timeline_day }}
              </p>
              <p class="muted">
                {{
                  item.child_ids.length
                    ? t("关联：") +
                      yearly.children
                        .filter((c) => item.child_ids.includes(c.id))
                        .map((c) => c.nickname || c.name)
                        .join("、")
                    : t("家庭时光 · 未关联人物与宠物")
                }}
              </p>
            </div>
            <div class="file-state numeric">
              <span v-if="item.status === 'ready'"> {{ t("待上传") }} </span
              ><span v-else-if="item.status === 'complete'" class="success-text"
                ><CheckCircle2 :size="15" />{{
                  item.duplicate ? t("已存在") : t("已完成")
                }}</span
              ><button
                v-else-if="item.status === 'failed'"
                class="text-button"
                :disabled="busy"
                @click="uploadAll([item])"
              >
                <RefreshCw :size="13" /> {{ t("重试") }}</button
              ><span v-else>{{ item.progress }}%</span
              ><ElProgress
                v-if="item.status === 'uploading'"
                :percentage="item.progress"
                :show-text="false"
              />
            </div>
            <div class="file-actions">
              <div class="file-order">
                <button
                  class="icon-button"
                  :disabled="busy || parsing || index === 0"
                  :aria-label="t('上移文件')"
                  @click="moveItem(item, -1)"
                >
                  <ChevronUp :size="15" /></button
                ><button
                  class="icon-button"
                  :disabled="busy || parsing || index === queue.length - 1"
                  :aria-label="t('下移文件')"
                  @click="moveItem(item, 1)"
                >
                  <ChevronDown :size="15" />
                </button>
              </div>
              <button class="button small" @click="editingItem = item">
                <Settings2 :size="14" /> {{ t("详情") }}</button
              ><button
                class="icon-button"
                :disabled="busy || parsing"
                :aria-label="t('移除文件')"
                @click="remove(item)"
              >
                <X :size="15" />
              </button>
            </div>
          </article>
        </div>
        <p v-if="completeCount === queue.length" class="queue-done">
          <CheckCircle2 :size="16" /> {{ t("这一批回忆已珍藏。") }}
          <RouterLink to="/"> {{ t("去时间线查看 →") }} </RouterLink>
        </p>
      </section>
      <details v-if="resumable.length" class="panel resume-panel">
        <summary>
          {{ t("接着上传 ·") }} {{ resumable.length }} {{ t("个未完成文件") }}
        </summary>
        <p class="muted">
          {{
            t("重新选择对应原件后，会校验文件并继续上传已完成分片之后的内容。")
          }}
        </p>
        <div v-for="task in resumable" :key="task.id" class="resume-row">
          <span
            >{{ task.filename
            }}<small
              >{{ bytes(task.file_size) }} · {{ task.file_role }}</small
            ></span
          ><label class="button small file-picker">
            <RefreshCw :size="14" /> {{ t("选择原件继续") }}
            <input
              type="file"
              :accept="accepted"
              :aria-label="t('选择原件继续')"
              :disabled="busy || parsing"
              @change="
                resumeTarget = task;
                resumeInput = $event.target as HTMLInputElement;
                resumeFile($event);
              "
            />
          </label>
        </div>
        <p v-if="notifySuccess" class="success-text">
          {{ t("本次文件已恢复上传。") }}
        </p>
      </details>
    </template>
    <MotionDialog
      :model-value="!!dateReview"
      :title="t('文件日期与追加日期不同')"
      width="560px"
      class="date-review-dialog"
      @close="dateReview = null"
    >
      <p class="date-review-intro">
        {{ t("当前追加到") }} <b>{{ archiveDate }}</b>
        {{ t("。以下文件的日期不同，是否放到各自日期的时间线位置？") }}
      </p>
      <div class="date-review-groups">
        <details v-for="[day, files] in dateGroups" :key="day" open>
          <summary>
            <b>{{ day }}</b
            ><span>{{ files.length }} {{ t("项") }} </span>
          </summary>
          <div v-for="item in files" :key="item.id" class="date-review-file">
            <span>{{ item.original.file.name }}</span>
            <small>{{
              item.corrected_taken_at_local
                ? t("手动修正日期")
                : item.original.time_source === "file_modified"
                  ? t("文件修改日期 · 待确认")
                  : t("拍摄 / 创建日期")
            }}</small>
          </div>
        </details>
      </div>
      <p class="muted date-review-note">
        <template v-if="targetFolder">
          {{ t("移到其他日期的文件会放在对应日期的文件夹外。") }}
        </template>
        {{
          t(
            "日期相同或未知的文件仍保留在当前日期。只调整时间线归档位置，原始文件和拍摄时间不会改变；重复文件保留已有归档位置。",
          )
        }}
      </p>
      <template #footer>
        <div class="date-review-actions">
          <button class="text-button" @click="dateReview = null">
            {{ t("取消，继续检查") }}
          </button>
          <button class="button" @click="confirmDates(false)">
            {{ t("保留在") }} {{ archiveDate }}
          </button>
          <button class="button primary" @click="confirmDates(true)">
            {{ t("移到文件对应日期") }}
          </button>
        </div>
      </template>
    </MotionDialog>
    <MotionDialog
      :model-value="!!editingItem"
      :title="t('文件详情')"
      width="680px"
      @close="editingItem = null"
    >
      <template v-if="editingItem">
        <h3>{{ editingItem.original.file.name }}</h3>
        <p class="muted file-detail-summary">
          {{ bytes(editingItem.original.file.size) }} ·
          {{ editingItem.original.device_model || t("设备信息未知") }} ·
          {{
            editingItem.original.original_taken_at_local?.replace("T", " ") ||
            t("拍摄时间未知")
          }}
        </p>
        <fieldset :disabled="busy || !!editingItem.tasks">
          <div class="form-row">
            <label>
              {{ t("标题") }}
              <input
                v-model="editingItem.title"
                maxlength="255"
                :placeholder="t('给这份回忆起个名字')" /></label
            ><label>
              {{ t("地点名称") }}
              <input
                v-model="editingItem.location_name"
                maxlength="255"
                :placeholder="t('留空或手动填写')"
            /></label>
          </div>
          <div class="form-row">
            <label>
              {{ t("修正拍摄当地时间") }}
              <DateField
                type="datetime"
                v-model="editingItem.corrected_taken_at_local" /></label
            ><label>
              {{ t("修正时区偏移（分钟）") }}
              <input
                type="number"
                v-model.number="editingItem.corrected_offset_minutes"
                min="-840"
                max="840"
                :placeholder="t('未知留空')"
            /></label>
          </div>
          <label class="checkbox-label"
            ><input type="checkbox" v-model="editingItem.time_unknown" />
            {{ t("明确标记拍摄时间未知（保留原始解析结果）") }}
          </label>
          <div class="field-group">
            <span>{{ t("里面都有谁（可多选）") }}</span
            ><ChildPicker v-model="editingItem.child_ids" />
          </div>
          <div
            v-if="!editingItem.original.video && !editingItem.live"
            class="pair-row"
          >
            <Link2 :size="15" /><select
              :aria-label="t('手动配对 Live Photo')"
              @change="
                pair(editingItem, ($event.target as HTMLSelectElement).value)
              "
            >
              <option value="">
                {{ t("手动配对 Live Photo 的 MOV 原件") }}
              </option>
              <option
                v-for="movie in queue.filter(
                  (q) =>
                    q.original.video &&
                    /\.mov$/i.test(q.original.file.name) &&
                    !q.tasks,
                )"
                :key="movie.id"
                :value="movie.id"
              >
                {{ movie.original.file.name }}
              </option>
            </select>
          </div>
          <div v-if="editingItem.live" class="pair-row">
            <Link2 :size="15" /> {{ t("已配对") }}
            {{ editingItem.live.file.name
            }}<button class="text-button" @click="unpair(editingItem)">
              {{ t("解除配对") }}
            </button>
          </div>
          <label class="preview-input">
            {{ t("兼容预览（可选，作为独立文件保存）") }}
            <input
              type="file"
              accept=".jpg,.jpeg,.png,.webp,.mp4"
              @change="addPreview(editingItem, $event)"
            /><small v-if="editingItem.preview">{{
              editingItem.preview.file.name
            }}</small></label
          >
        </fieldset>
        <div class="dialog-actions">
          <button class="text-button" @click="metadataItem = editingItem">
            {{ t("查看完整元数据与校验值") }}</button
          ><button class="button primary" @click="editingItem = null">
            {{ t("完成") }}
          </button>
        </div>
      </template>
    </MotionDialog>
    <MotionDialog
      :model-value="!!metadataItem"
      :title="t('原文件元数据')"
      width="740px"
      @close="metadataItem = null"
      ><template v-if="metadataItem"
        ><code class="hash-display"
          >SHA-256 {{ metadataItem.original.hash.sha256 }}<br />CRC64
          {{ metadataItem.original.hash.crc64 }}</code
        >
        <pre>{{ JSON.stringify(metadataItem.original.raw, null, 2) }}</pre>
      </template></MotionDialog
    >
  </div>
</template>
<style scoped>
.live-import-guide {
  margin: 18px 0;
  padding: 16px 18px;
  border-left: 3px solid var(--sage);
  background: var(--surface);
  border-radius: 8px;
}
.live-import-guide h2 {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 15px;
}
.live-import-guide p,
.live-import-guide small {
  display: block;
  margin-top: 8px;
  font-size: 13px;
  line-height: 1.7;
  color: var(--muted);
}
.date-review-intro {
  line-height: 1.8;
  margin: 0 0 16px;
}
.date-review-groups {
  max-height: 280px;
  overflow: auto;
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 4px 14px;
}
.date-review-groups details + details {
  border-top: 1px solid var(--line);
}
.date-review-groups summary {
  display: flex;
  justify-content: space-between;
  padding: 12px 0;
  cursor: pointer;
}
.date-review-groups summary span,
.date-review-file small {
  color: var(--muted);
  font-size: 12px;
}
.date-review-file {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  padding: 6px 0;
  font-size: 12px;
}
.date-review-file > span {
  overflow-wrap: anywhere;
  min-width: 0;
}
.date-review-file small {
  flex-shrink: 0;
}
.date-review-note {
  font-size: 12px;
  line-height: 1.8;
  margin: 14px 0 0;
}
.date-review-actions {
  display: flex;
  justify-content: flex-end;
  flex-wrap: wrap;
  gap: 10px;
}
.batch-settings {
  padding: 22px;
  margin-bottom: 18px;
}
.batch-settings small {
  font-size: 12px;
  color: var(--muted);
  font-weight: 400;
}
.batch-children {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 12px;
  font-size: 12px;
}
.compact-dropzone {
  flex-direction: row;
  flex-wrap: wrap;
  gap: 20px;
  padding: 24px;
  text-align: left;
  color: var(--sage);
}
.compact-dropzone > div:not(.parse-progress):not(.picker-actions) {
  flex: 1;
}
.compact-dropzone h2 {
  font-size: 18px;
}
.compact-dropzone p {
  margin: 6px 0 0;
}
.file-picker {
  position: relative;
  overflow: hidden;
  flex-direction: row;
}
.picker-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
.picker-actions .file-picker {
  margin: 0;
}
.paste-import {
  margin-top: 16px;
  padding: 18px;
  border: 1px solid var(--line);
  border-radius: 14px;
  color: var(--muted);
  font-size: 13px;
  line-height: 1.8;
}
.paste-import h2 {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0;
  font-size: 16px;
  color: var(--text);
}
.paste-import p {
  margin: 8px 0 12px;
}
.paste-target {
  min-height: 56px;
  padding: 14px;
  margin-bottom: 10px;
  border: 1px dashed var(--sage);
  border-radius: 10px;
  color: var(--text);
  font-size: 16px;
  cursor: text;
  user-select: text;
  -webkit-user-select: text;
}
.paste-target:empty::before {
  content: attr(data-placeholder);
  color: var(--muted);
  pointer-events: none;
}
.paste-target:focus {
  outline: 2px solid var(--sage);
  outline-offset: 2px;
}
.paste-target[aria-disabled="true"] {
  opacity: 0.5;
}
.file-picker input[type="file"] {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  opacity: 0;
  cursor: pointer;
}
.file-picker:focus-within {
  outline: 2px solid var(--sage);
  outline-offset: 4px;
}
.file-picker:has(input:disabled) {
  opacity: 0.5;
  cursor: not-allowed;
}
.compact-dropzone .parse-progress {
  flex-basis: 100%;
  max-width: none;
  margin: 0;
}
.upload-tip {
  margin: 14px 0 24px;
  font-size: 12px;
  color: var(--muted);
}
.upload-tip summary {
  display: flex;
  align-items: center;
  gap: 7px;
  cursor: pointer;
}
.upload-tip p {
  margin: 10px 0;
  line-height: 1.8;
}
.upload-queue {
  padding: 0;
  overflow: hidden;
}
.queue-heading {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  padding: 20px;
}
.queue-heading h2 {
  font-size: 19px;
  margin-bottom: 5px;
}
.queue-heading span,
.queue-tools {
  font-size: 12px;
  color: var(--muted);
}
.queue-tools {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 10px 20px;
  background: var(--bg);
  border-block: 1px solid var(--line);
}
.queue-tools .checkbox-label {
  margin: 0;
}
.queue-tools > button {
  margin-left: auto;
  display: flex;
  gap: 5px;
  align-items: center;
}
.queue-list {
  max-height: 560px;
  overflow: auto;
}
.upload-file-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 16px;
  min-height: 76px;
  border-bottom: 1px solid var(--line);
}
.upload-file-row:last-child {
  border-bottom: 0;
}
.upload-file-row.selected {
  background: color-mix(in srgb, var(--sage-light) 30%, var(--surface));
}
.upload-file-row.is-dragging {
  opacity: 0.45;
}
.drag-handle {
  cursor: grab;
  color: var(--muted);
}
.row-checkbox {
  width: 16px;
  height: 16px;
  flex-shrink: 0;
  accent-color: var(--sage);
}
.file-thumb {
  width: 48px;
  height: 48px;
  position: relative;
  flex-shrink: 0;
  display: grid;
  place-items: center;
  background: var(--sage-light);
  border-radius: 7px;
  overflow: hidden;
  color: var(--sage);
}
.file-thumb img {
  position: absolute;
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.file-summary {
  flex: 1;
  min-width: 0;
}
.file-summary h3 {
  font-size: 14px;
  font-weight: var(--weight-medium);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.file-summary p {
  font-size: 12px;
  margin-top: 5px;
  color: var(--muted);
}
.file-summary .file-error {
  color: #b25448;
  white-space: normal;
}
.file-badges {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
}
.file-badges .chip {
  min-height: 0;
}
.file-state {
  width: 72px;
  font-size: 12px;
  color: var(--muted);
}
.file-state .success-text {
  display: flex;
  align-items: center;
  gap: 4px;
}
.file-actions,
.file-order {
  display: flex;
  align-items: center;
  gap: 3px;
}
.file-order {
  flex-direction: column;
}
.file-order .icon-button {
  height: 24px;
  width: 24px;
}
.queue-done {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 16px 20px;
  font-size: 12px;
  color: var(--sage);
  border-top: 1px solid var(--line);
}
.queue-done a {
  margin-left: auto;
}
.resume-panel {
  padding: 18px 22px;
}
.resume-panel summary {
  cursor: pointer;
  font-size: 13px;
}
.file-detail-summary {
  margin: 10px 0 20px;
  font-size: 12px;
}
@media (max-width: 700px) {
  .batch-settings {
    padding: 16px;
  }
  .batch-settings .form-row {
    grid-template-columns: 1fr;
  }
  .compact-dropzone {
    gap: 12px;
    padding: 20px 16px;
  }
  .picker-actions {
    width: 100%;
  }
  .picker-actions .file-picker {
    flex: 1;
    justify-content: center;
  }
  .picker-actions .main-picker {
    flex-basis: 100%;
  }
  .queue-heading {
    align-items: flex-start;
    padding: 16px;
  }
  .queue-heading h2 {
    font-size: 16px;
  }
  .queue-heading > button {
    padding: 10px;
    white-space: nowrap;
  }
  .queue-tools {
    padding: 10px 14px;
    gap: 12px;
  }
  .queue-sort-hint,
  .drag-handle,
  .file-thumb {
    display: none;
  }
  .upload-file-row {
    gap: 8px;
    padding: 10px;
  }
  .file-state {
    width: 48px;
    font-size: 12px;
  }
  .file-actions > .icon-button {
    display: none;
  }
  .file-actions .button {
    padding: 7px;
    font-size: 12px;
  }
  .file-actions .button svg {
    display: none;
  }
  .file-order .icon-button {
    width: 44px;
    height: 44px;
  }
}
</style>
