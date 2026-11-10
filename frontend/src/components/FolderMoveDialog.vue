<script setup lang="ts">
import { t } from "../lib/i18n";
import { ref, watch } from "vue";
import { api, post, notify } from "../lib/api";
const props = defineProps<{
  open: boolean;
  day: string;
  ids: number[];
  currentFolder?: number;
}>();
const emit = defineEmits(["close", "saved"]);
const folders = ref<any[]>([]),
  target = ref(""),
  busy = ref(false),
  loading = ref(false);
watch(
  () => props.open,
  async (open) => {
    if (!open) return;
    target.value = "";
    folders.value = [];
    loading.value = true;
    try {
      folders.value = await api(`/folders?day=${props.day}`);
    } catch (e) {
      notify(e);
    } finally {
      loading.value = false;
    }
  },
);
async function save() {
  busy.value = true;
  try {
    await post("/folders/move-media", {
      media_ids: props.ids,
      folder_id: target.value ? Number(target.value) : null,
    });
    emit("saved");
    emit("close");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <ElDialog
    append-to-body
    :model-value="open"
    :title="t('移动到文件夹')"
    width="440px"
    @close="emit('close')"
  >
    <p class="muted">
      {{ day }} {{ t("· 已选") }} {{ ids.length }} {{ t("份影像") }}
    </p>
    <label>
      {{ t("目标位置") }}
      <select v-model="target" :disabled="loading || busy">
        <option value="">{{ t("当天时间线（文件夹外）") }}</option>
        <option
          v-for="folder in folders.filter((f) => f.id !== currentFolder)"
          :key="folder.id"
          :value="String(folder.id)"
          :disabled="folder.can_edit === false"
        >
          {{ folder.name }} {{ folder.can_edit === false ? t("已锁定") : "" }}
        </option>
      </select></label
    >
    <p v-if="!loading && !folders.length" class="muted">
      {{ t("这一天还没有文件夹，可先在日期栏新建。") }}
    </p>
    <div class="dialog-actions">
      <button
        class="button primary"
        :disabled="loading || busy || !ids.length"
        @click="save"
      >
        {{ busy ? t("正在移动…") : t("移动所选影像") }}
      </button>
    </div>
  </ElDialog>
</template>
