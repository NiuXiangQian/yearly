<script setup lang="ts">
import { t, ageLabel } from "../lib/i18n";
import { ref, watch, onMounted } from "vue";
import { Plus, BookHeart, ArrowUpRight, CalendarDays } from "lucide-vue-next";
import { api, notify, localDate } from "../lib/api";
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
  match = ref("any");
async function load(reset = true) {
  loading.value = true;
  if (reset) page.value = 1;
  try {
    const params = new URLSearchParams({
      page: String(page.value),
      match: match.value,
    });
    yearly.selected.forEach((id) => params.append("child_id", String(id)));
    const data = await api("/events?" + params);
    events.value = reset ? data.items : [...events.value, ...data.items];
    total.value = data.total;
  } catch (e) {
    notify(e);
  } finally {
    loading.value = false;
  }
}
watch([() => yearly.selected, match], () => load(), { deep: true });
onMounted(() => load());
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">THE STORIES BEHIND THE PICTURES</span>
      <h1>{{ t("有些成长，值得多写几句。") }}</h1>
      <p>{{ t("把散落的瞬间串成故事，把一起长大的日子记下来。") }}</p>
    </div>
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
  </div>
  <div class="panel event-filter">
    <ChildPicker v-model="yearly.selected" all /><select
      v-if="yearly.selected.length > 1"
      v-model="match"
      class="compact-select"
    >
      <option value="any">{{ t("任意所选档案") }}</option>
      <option value="all">{{ t("全部人物与宠物") }}</option>
    </select>
  </div>
  <div v-if="events.length" class="events-grid">
    <article
      v-for="(e, i) in events"
      :key="e.id"
      class="event-card"
      @click="
        eventId = e.id;
        open = true;
      "
    >
      <div class="event-cover">
        <EventCover :media-id="e.cover_media_id" />
        <span class="event-number">{{ String(i + 1).padStart(2, "0") }}</span
        ><BookHeart :size="42" stroke-width="1" /><span class="eyebrow"
          >A CHAPTER OF GROWING UP</span
        >
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
        <p>{{ e.content || t("那些藏在照片里的小故事。") }}</p>
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
          <span>{{ e.media_ids.length }} {{ t("份回忆 · 全部事件媒体") }} </span
          ><ArrowUpRight :size="19" />
        </div>
      </div>
    </article>
  </div>
  <EmptyState
    v-else-if="!loading"
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
      @click="
        page++;
        load(false);
      "
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
