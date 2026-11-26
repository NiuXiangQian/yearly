<script setup lang="ts">
import PageHeading from "../components/PageHeading.vue";
import { t, ageLabel } from "../lib/i18n";
import { ref, watch, onMounted } from "vue";
import { Plus, BookHeart, ArrowUpRight, CalendarDays } from "lucide-vue-next";
import { api, localDate } from "../lib/api";
import { useYearly } from "../stores/yearly";
import ChildPicker from "../components/ChildPicker.vue";
import EmptyState from "../components/EmptyState.vue";
import EventEditor from "../components/EventEditor.vue";
import EventCover from "../components/EventCover.vue";
const yearly = useYearly(),
  events = ref<any[]>([]),
  total = ref(0),
  page = ref(1),
  open = ref(false),
  eventId = ref<number | null>(null),
  loading = ref(false),
  error = ref(""),
  failedMore = ref(false),
  match = ref("any");
async function load(reset = true) {
  loading.value = true;
  error.value = "";
  failedMore.value = false;
  const targetPage = reset ? 1 : page.value + 1;
  try {
    const params = new URLSearchParams({
      page: String(targetPage),
      match: match.value,
    });
    yearly.selected.forEach((id) => params.append("child_id", String(id)));
    const data = await api("/events?" + params);
    events.value = reset ? data.items : [...events.value, ...data.items];
    total.value = data.total;
    page.value = targetPage;
  } catch (e) {
    error.value = e instanceof Error ? e.message : t("加载失败");
    failedMore.value = !reset;
  } finally {
    loading.value = false;
  }
}
watch([() => yearly.selected, match], () => load(), { deep: true });
onMounted(() => load());
</script>
<template>
  <PageHeading :title="t('成长日记')">
    <button
      v-if="yearly.canEdit"
      class="button primary"
      @click="
        eventId = null;
        open = true;
      "
    >
      <Plus :size="17" /> {{ t("写成长日记") }}
    </button>
  </PageHeading>
  <div class="panel event-filter">
    <ChildPicker v-model="yearly.selected" all /><select
      v-if="yearly.selected.length > 1"
      v-model="match"
      class="compact-select"
      :aria-label="t('档案匹配方式')"
    >
      <option value="any">{{ t("任意所选档案") }}</option>
      <option value="all">{{ t("全部人物与宠物") }}</option>
    </select>
  </div>
  <p v-if="error" class="notice" role="alert">
    {{ error }} <button type="button" class="text-button" @click="load(!failedMore)">{{ t("重试") }}</button>
  </p>
  <p v-if="loading" class="muted" role="status">{{ t("正在加载…") }}</p>
  <div v-if="events.length" class="events-grid">
    <article v-for="e in events" :key="e.id" class="event-card">
      <div v-if="e.cover_media_id" class="event-cover">
        <EventCover :media-id="e.cover_media_id" />
      </div>
      <div class="event-card-body">
        <span class="event-date"
          ><CalendarDays :size="13" />{{ localDate(e.start_at)
          }}<template
            v-if="
              e.end_at && e.end_at.slice(0, 10) !== e.start_at?.slice(0, 10)
            "
          >
            — {{ localDate(e.end_at) }}</template
          ></span
        >
        <h2>{{ e.title }}</h2>
        <p v-if="e.content">{{ e.content }}</p>
        <div class="age-labels">
          <span v-for="c in e.children" :key="c.id"
            >{{ c.nickname || c.name
            }}<template v-if="c.age_start">
              · {{ ageLabel(c.age_start)
              }}<template v-if="c.age_end && c.age_end !== c.age_start">
                ～ {{ ageLabel(c.age_end) }}</template
              ></template
            ></span
          >
        </div>
        <div class="event-card-footer">
          <span>{{ e.media_ids.length }} {{ t("份回忆 · 全部事件媒体") }}</span>
          <button
            type="button"
            class="icon-button event-card-open"
            :aria-label="e.title"
            @click="(eventId = e.id), (open = true)"
          ><ArrowUpRight :size="19" aria-hidden="true" /></button>
        </div>
      </div>
    </article>
  </div>
  <EmptyState
    v-else-if="!loading && !error"
    :title="t('让照片连成故事')"
    :description="
      t('在时间线选中一组照片，或从一段文字开始，记录一家人的共同成长。')
    "
    ><button
      v-if="yearly.canEdit"
      class="button primary"
      @click="
        eventId = null;
        open = true;
      "
    >
      <BookHeart :size="16" /> {{ t("写下第一篇日记") }}
    </button></EmptyState
  >
  <div class="load-more">
    <button
      v-if="events.length < total"
      class="button"
      :disabled="loading"
      @click="load(false)"
    >
      {{ t("加载更多日记") }}
    </button>
  </div>
  <EventEditor
    :open="open"
    :event-id="eventId"
    @close="open = false"
    @saved="load()"
  />
</template>
