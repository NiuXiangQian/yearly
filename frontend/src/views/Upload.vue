<script setup lang="ts">
import { ref, onMounted, onBeforeUnmount } from "vue";
import {
  UploadCloud,
  FileImage,
  CheckCircle2,
  ShieldCheck,
  Link2,
  X,
  RefreshCw,
  Info,
  ArrowRight,
  Film,
} from "lucide-vue-next";
import { useYearly } from "../stores/yearly";
import { api, post, notify, bytes } from "../lib/api";
import { inspectFile, type Inspected } from "../lib/metadata";
import { directUpload } from "../lib/upload";
import ChildPicker from "../components/ChildPicker.vue";
const yearly = useYearly(),
  input = ref<HTMLInputElement>(),
  queue = ref<any[]>([]),
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
const accepted =
  ".jpg,.jpeg,.png,.heic,.heif,.webp,.dng,.cr2,.cr3,.nef,.arw,.orf,.rw2,.raf,.mp4,.mov";
onMounted(async () => {
  try {
    const saved = JSON.parse(
      localStorage.getItem("yearly-upload-children") || "[]",
    );
    kids.value = saved.filter((id: number) =>
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
async function addFiles(files: FileList | File[] | null) {
  if (!files || parsing.value || busy.value) return;
  parsing.value = true;
  try {
    for (const file of Array.from(files)) {
      parsingName.value = file.name;
      hashProgress.value = 0;
      const inspected = await inspectFile(
        file,
        (n) => (hashProgress.value = n),
      );
      if (
        queue.value.some(
          (q) => q.original.hash.sha256 === inspected.hash.sha256,
        )
      )
        continue;
      queue.value.push({
        id: crypto.randomUUID(),
        original: inspected,
        live: null,
        preview: null,
        child_ids: [...kids.value],
        title: "",
        location_name: "",
        corrected_taken_at_local: null,
        corrected_offset_minutes: null,
        time_unknown: false,
        status: "ready",
        progress: 0,
        error: "",
        tasks: null,
        previewUrl: !inspected.video ? URL.createObjectURL(file) : "",
      });
    }
    // Pair only an explicit shared metadata identifier, never a coincidental filename.
    for (const item of [...queue.value]) {
      if (item.original.video || !item.original.pairId || item.live) continue;
      const movie = queue.value.find(
        (q) =>
          q.original.video &&
          q.original.pairId === item.original.pairId &&
          q.status === "ready",
      );
      if (movie) {
        item.live = movie.original;
        remove(movie);
      }
    }
  } catch (e) {
    notify(e);
  } finally {
    parsing.value = false;
    parsingName.value = "";
    if (input.value) input.value.value = "";
  }
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
    id: crypto.randomUUID(),
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
  for (const item of queue.value)
    if (item.status === "ready") item.child_ids = [...kids.value];
}
async function uploadAll() {
  if (!yearly.canEdit) return;
  busy.value = true;
  localStorage.setItem("yearly-upload-children", JSON.stringify(kids.value));
  try {
    for (const item of queue.value) {
      if (item.status === "complete") continue;
      item.status = "uploading";
      item.error = "";
      try {
        if (!item.tasks) {
          const o = item.original;
          const data = await post("/uploads", {
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
        item.error = e instanceof Error ? e.message : "上传失败";
      }
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
  queue.value.forEach((q) => q.previewUrl && URL.revokeObjectURL(q.previewUrl));
});
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">KEEP TODAY FOR TOMORROW</span>
      <h1>把新的回忆，放进时光里。</h1>
      <p>先读懂每份原件，再把它安全地交给岁月。</p>
    </div>
    <span class="secure-badge"
      ><ShieldCheck :size="16" /> 浏览器直传 · 字节级无损</span
    >
  </div>
  <div v-if="!yearly.canEdit" class="notice">
    当前账户为只读访客，请联系家庭管理员获得编辑权限。
  </div>
  <template v-else
    ><div class="upload-settings panel">
      <h3>这次是谁的故事？</h3>
      <p class="muted">可以同时关联多个孩子，也可以留空，作为全家人的回忆。</p>
      <ChildPicker v-model="kids" /><button
        class="text-button"
        @click="applyKids"
      >
        应用到本批待上传文件
      </button>
    </div>
    <div
      class="dropzone"
      :class="{ dragging }"
      @dragover.prevent="dragging = true"
      @dragleave.prevent="dragging = false"
      @drop.prevent="
        dragging = false;
        addFiles($event.dataTransfer?.files || null);
      "
    >
      <div class="upload-symbol"><UploadCloud :size="34" /></div>
      <h2>{{ parsing ? "正在读取原文件…" : "把回忆轻轻放在这里" }}</h2>
      <p>拖入照片与视频，或从设备中选择文件</p>
      <button
        class="button primary"
        :disabled="parsing || busy"
        @click="input?.click()"
      >
        <UploadCloud :size="16" />选择原文件</button
      ><input
        ref="input"
        type="file"
        multiple
        :accept="accepted"
        hidden
        @change="addFiles(($event.target as HTMLInputElement).files)"
      /><small
        >JPG、HEIC、RAW、PNG、WebP、MOV、MP4 · Live Photo 双文件导入</small
      >
      <div v-if="parsing || parsingName" class="parse-progress">
        <span>{{ parsingName }} · {{ hashProgress }}%</span
        ><ElProgress :percentage="hashProgress" :show-text="false" />
      </div>
    </div>
    <div class="notice subtle">
      <Info :size="18" />
      <p>
        iPhone
        相册选择器可能提供转换或编辑版本。需要相机原件时，请先将“未修改的原片”导出到文件
        App，再从这里导入。扩展名与校验值无法证明相机原件身份。
      </p>
    </div>
    <div v-if="queue.length" class="section-heading">
      <h2>
        上传前确认 <small>{{ queue.length }} 份回忆</small>
      </h2>
      <button
        class="button primary"
        :disabled="
          busy || parsing || queue.every((q) => q.status === 'complete')
        "
        @click="uploadAll"
      >
        <UploadCloud :size="16" />{{
          busy ? "正在珍藏…" : "确认元数据并开始上传"
        }}
      </button>
    </div>
    <article v-for="item in queue" :key="item.id" class="upload-item panel">
      <div class="upload-item-preview">
        <img
          v-if="item.previewUrl"
          :src="item.previewUrl"
          alt="本地原件预览"
          @error="($event.target as HTMLImageElement).style.display = 'none'"
        /><Film v-if="item.original.video" :size="30" /><FileImage
          v-else
          :size="30"
        />
      </div>
      <div class="upload-item-body">
        <div class="section-heading">
          <h3>
            {{ item.original.file.name }}
            <span v-if="item.live" class="chip">LIVE</span>
          </h3>
          <button
            class="icon-button"
            :disabled="busy"
            aria-label="移除文件"
            @click="remove(item)"
          >
            <X :size="17" />
          </button>
        </div>
        <p class="muted">
          {{ bytes(item.original.file.size) }} ·
          {{
            item.original.width
              ? `${item.original.width} × ${item.original.height}`
              : "分辨率未知"
          }}
          · {{ item.original.device_model || "设备信息未知" }}
        </p>
        <div class="upload-meta-summary">
          <span>{{
            item.original.original_taken_at_local?.replace("T", " ") ||
            "拍摄时间未知"
          }}</span
          ><span
            class="confidence"
            :class="{ low: item.original.time_confidence === 'low' }"
            >{{
              item.original.time_confidence === "low"
                ? "低可信度 · 文件修改时间"
                : item.original.time_source
            }}</span
          ><button class="text-button" @click="metadataItem = item">
            完整元数据与 SHA-256
          </button>
        </div>
        <fieldset :disabled="busy || !!item.tasks">
          <div class="form-row">
            <label
              >标题<input
                v-model="item.title"
                maxlength="255"
                placeholder="给这份回忆起个名字" /></label
            ><label
              >地点名称<input
                v-model="item.location_name"
                maxlength="255"
                placeholder="留空或手动填写"
            /></label>
          </div>
          <div class="form-row">
            <label
              >修正拍摄当地时间<input
                type="datetime-local"
                v-model="item.corrected_taken_at_local" /></label
            ><label
              >修正时区偏移（分钟）<input
                type="number"
                v-model.number="item.corrected_offset_minutes"
                min="-840"
                max="840"
                placeholder="未知留空"
            /></label>
          </div>
          <label class="checkbox-label"
            ><input
              type="checkbox"
              v-model="item.time_unknown"
            />明确标记拍摄时间未知（保留原始解析结果）</label
          ><ChildPicker v-model="item.child_ids" />
          <div v-if="!item.original.video && !item.live" class="pair-row">
            <Link2 :size="15" /><select
              aria-label="手动配对 Live Photo"
              @change="pair(item, ($event.target as HTMLSelectElement).value)"
            >
              <option value="">手动配对 Live Photo 的 MOV 原件</option>
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
          <div v-if="item.live" class="pair-row">
            <Link2 :size="15" />已配对 {{ item.live.file.name
            }}<button class="text-button" @click="unpair(item)">
              解除配对
            </button>
          </div>
          <label class="preview-input"
            >兼容预览（可选，作为独立文件保存）<input
              type="file"
              accept=".jpg,.jpeg,.png,.webp,.mp4"
              @change="addPreview(item, $event)"
            /><small v-if="item.preview">{{
              item.preview.file.name
            }}</small></label
          >
        </fieldset>
        <div v-if="item.status !== 'ready'" class="upload-progress">
          <ElProgress
            :percentage="item.progress"
            :status="
              item.status === 'complete'
                ? 'success'
                : item.status === 'failed'
                  ? 'exception'
                  : undefined
            "
          /><span>{{
            item.status === "complete"
              ? "原件已通过 OSS 大小与 CRC64 核验"
              : item.status === "failed"
                ? item.error
                : "分片直传中，请保持页面打开"
          }}</span
          ><button
            v-if="item.status === 'failed'"
            class="text-button"
            :disabled="busy"
            @click="uploadAll"
          >
            重试未完成任务
          </button>
        </div>
      </div>
    </article>
    <section v-if="resumable.length" class="panel resume-panel">
      <h3>
        接着珍藏 <small>{{ resumable.length }} 个未完成文件</small>
      </h3>
      <p class="muted">
        重新选择对应原件，系统会校验 SHA-256 并跳过已上传分片。多文件 Live Photo
        需分别恢复两份文件。
      </p>
      <div v-for="task in resumable" :key="task.id" class="resume-row">
        <span
          >{{ task.filename
          }}<small
            >{{ bytes(task.file_size) }} · {{ task.file_role }}</small
          ></span
        ><button
          class="button small"
          :disabled="busy"
          @click="
            resumeTarget = task;
            resumeInput?.click();
          "
        >
          <RefreshCw :size="14" />选择原件继续
        </button>
      </div>
      <input ref="resumeInput" type="file" hidden @change="resumeFile" />
      <p v-if="notifySuccess" class="success-text">本次文件已恢复上传。</p>
    </section></template
  ><ElDialog
    :model-value="!!metadataItem"
    title="原文件元数据"
    width="740px"
    @close="metadataItem = null"
    ><template v-if="metadataItem"
      ><p class="muted">只能展示解析到的字段。缺失值保持未知，不会推测填充。</p>
      <code class="hash-display"
        >SHA-256 {{ metadataItem.original.hash.sha256 }}<br />CRC64
        {{ metadataItem.original.hash.crc64 }}</code
      >
      <pre>{{ JSON.stringify(metadataItem.original.raw, null, 2) }}</pre>
    </template></ElDialog
  >
</template>
