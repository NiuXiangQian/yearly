<script setup lang="ts">
import { ref, watch } from "vue";
import { api } from "../lib/api";
const props = defineProps<{ child: any }>(),
  url = ref(""),
  failed = ref(false);
watch(
  () => props.child.avatar_media_id,
  async (id) => {
    url.value = "";
    failed.value = false;
    if (!id) return;
    try {
      const media = await api("/media/" + id);
      const file =
        media.files.find((f: any) => f.file_role === "preview") ||
        media.files.find((f: any) => f.file_role === "original");
      if (file)
        url.value = (await api(`/media/${id}/files/${file.id}/url`)).url;
    } catch {
      failed.value = true;
    }
  },
  { immediate: true },
);
</script>
<template>
  <span class="child-avatar" :style="{ '--child-color': child.theme_color }"
    ><img
      v-if="url && !failed"
      :src="url"
      :alt="child.nickname || child.name"
      @error="failed = true"
    /><template v-else>{{
      (child.nickname || child.name).slice(0, 1)
    }}</template></span
  >
</template>
