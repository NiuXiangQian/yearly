<script setup lang="ts">
import { ref, watch } from "vue";
import { heicPreview } from "../lib/heic";

const props = defineProps<{ src: string; file?: any; alt?: string }>();
const emit = defineEmits(["load", "error"]);
const displayUrl = ref("");

watch(
  () => [props.src, props.file] as const,
  async ([source, file], _, onCleanup) => {
    let active = true;
    let objectUrl = "";
    onCleanup(() => {
      active = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    });
    displayUrl.value = "";
    if (!source) return;
    if (
      !/^image\/hei[cf](?:-sequence)?$/i.test(file?.mime_type || "") &&
      !/\.hei[cf]$/i.test(file?.original_filename || "")
    ) {
      displayUrl.value = source;
      return;
    }
    try {
      const blob = await heicPreview(source, file?.sha256 || source);
      if (!active) return;
      objectUrl = URL.createObjectURL(blob);
      displayUrl.value = objectUrl;
    } catch {
      if (active) emit("error");
    }
  },
  { immediate: true },
);
</script>

<template>
  <img
    v-if="displayUrl"
    :src="displayUrl"
    :alt="alt"
    @load="emit('load')"
    @error="emit('error')"
  />
</template>
