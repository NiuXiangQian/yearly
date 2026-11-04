<script setup lang="ts">
import { t } from "../lib/i18n";
import { ref, watch } from "vue";
import { api } from "../lib/api";
import { mediaResource } from "../lib/media-resource";
const props = defineProps<{ mediaId: number | null }>();
const url = ref(""),
  failed = ref(false);
watch(
  () => props.mediaId,
  async (id) => {
    url.value = "";
    failed.value = false;
    if (!id) return;
    try {
      const media = await api(`/media/${id}`);
      const file =
        media.files.find((f: any) => f.file_role === "preview") ||
        media.files.find((f: any) => f.file_role === "original");
      if (file)
        url.value = (await mediaResource(id, file.id, "thumbnail")).url || "";
    } catch {
      failed.value = true;
    }
  },
  { immediate: true },
);
</script>
<template>
  <img
    v-if="url && !failed"
    class="event-cover-image"
    :src="url"
    :alt="t('成长日记自定义封面')"
    loading="lazy"
    @error="failed = true"
  />
</template>
