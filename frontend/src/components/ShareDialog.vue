<script setup lang="ts">
import MotionDialog from "./MotionDialog.vue";
import { computed, ref, watch } from "vue";
import { ElMessage } from "element-plus";
import { Link, X } from "lucide-vue-next";
import { api, post, del, notify, sitePath } from "../lib/api";
import { t, locale } from "../lib/i18n";
import DateField from "./DateField.vue";
const props = defineProps<{ open: boolean; initialDate?: string }>();
const emit = defineEmits(["close"]);
const profiles = ref<{ id: number; name: string; nickname: string; profile_type: string; relationship?: string }[]>([]);
const profileIDs = ref<number[]>([]);
const allProfiles = ref(false);
const profilesLoaded = ref(false);
const loadError = ref("");
let loadGeneration = 0;
const startMode = ref("earliest"),
  earliest = ref("");
function dateString(date: Date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
function chooseStart() {
  if (startMode.value === "custom") return;
  if (startMode.value === "earliest") {
    start.value = earliest.value;
    return;
  }
  const today = new Date();
  const months = startMode.value === "year" ? 12 : 6;
  const date = new Date(today.getFullYear(), today.getMonth() - months, 1);
  date.setDate(
    Math.min(
      today.getDate(),
      new Date(date.getFullYear(), date.getMonth() + 1, 0).getDate(),
    ),
  );
  start.value = dateString(date);
}
const start = ref(""),
  end = ref(""),
  hours = ref(24);
const busy = ref(false),
  history = ref<any[]>([]),
  link = ref(""),
  activeLinkID = ref<number>(),
  creatingError = ref("");
function showLink(id: number, token: string) {
  link.value = location.origin + sitePath(`/share/${token}`);
  activeLinkID.value = id;
}
const valid = computed(
  () =>
    profilesLoaded.value &&
    (allProfiles.value || profileIDs.value.length > 0) &&
    start.value &&
    end.value &&
    start.value <= end.value &&
    Number.isInteger(hours.value) &&
    hours.value >= 1 &&
    hours.value <= 168,
);
watch(
  () => props.open,
  (open) => {
    if (!open) {
      loadGeneration++;
      link.value = "";
      activeLinkID.value = undefined;
      return;
    }
    creatingError.value = "";
    startMode.value = props.initialDate ? "custom" : "earliest";
    earliest.value = "";
    start.value = props.initialDate || "";
    end.value = props.initialDate || dateString(new Date());
    void load();
  },
  { immediate: true },
);
async function load() {
  const generation = ++loadGeneration;
  profilesLoaded.value = false;
  loadError.value = "";
  try {
    const [links, bounds, people] = await Promise.all([
      api("/shares"),
      api("/shares/bounds"),
      api<typeof profiles.value>("/children"),
    ]);
    if (generation !== loadGeneration) return;
    profiles.value = people;
    profileIDs.value = people.filter(profile =>
      profile.profile_type === "child" ||
      (profile.profile_type === "person" && profile.relationship === "孩子"),
    ).map(profile => profile.id);
    allProfiles.value = profileIDs.value.length === 0;
    profilesLoaded.value = true;
    history.value = links;
    earliest.value = bounds.earliest || "";
    chooseStart();
  } catch (e) {
    if (generation === loadGeneration) loadError.value = e instanceof Error ? e.message : t("操作失败");
  }
}
async function create() {
  if (!valid.value || busy.value) return;
  busy.value = true;
  creatingError.value = "";
  const selected = [...profileIDs.value];
  try {
    const data = await post("/shares", {
      start_date: start.value,
      end_date: end.value,
      hours: hours.value,
      profile_ids: selected,
    });
    if (!Array.isArray(data.profile_ids) || data.profile_ids.length !== selected.length ||
        !selected.every(id => data.profile_ids.includes(id))) {
      await del(`/shares/${data.id}`);
      throw new Error(t("服务端返回的分享范围有误，分享已撤销。"));
    }
    showLink(data.id, data.token);
    history.value.unshift(data);
    ElMessage.success(t("分享链接已创建"));
  } catch (e) {
    creatingError.value = e instanceof Error ? e.message : t("操作失败");
  } finally {
    busy.value = false;
  }
}
async function copy() {
  try {
    await navigator.clipboard.writeText(link.value);
    ElMessage.success(t("链接已复制"));
  } catch {
    ElMessage.info(t("请选中链接手动复制"));
  }
}
async function revoke(item: any) {
  try {
    await del(`/shares/${item.id}`);
    item.revoked = true;
    if (activeLinkID.value === item.id) link.value = "";
  } catch (e) {
    notify(e);
  }
}
async function viewRecord(item: any) {
  busy.value = true;
  try {
    const data = await api(`/shares/${item.id}/link`);
    showLink(item.id, data.token);
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function copyRecord(item: any) {
  busy.value = true;
  try {
    const data = await post(`/shares/${item.id}/copy`, { hours: hours.value });
    history.value.unshift(data);
    showLink(data.id, data.token);
    ElMessage.success(t("分享链接已创建"));
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <MotionDialog
    :model-value="open"
    :title="t('分享时间线')"
    width="620px"
    class="share-dialog"
    :close-on-click-modal="false"
    :close-on-press-escape="!busy"
    :show-close="!busy"
    @close="emit('close')"
  >
    <p class="muted">{{ t("选择时间线范围，自动分享其中允许分享的内容。") }}</p>
    <form @submit.prevent="create" @keydown.enter="$event.isComposing && $event.preventDefault()">
      <fieldset class="share-form-section" :disabled="busy">
        <legend>{{ t("分享范围") }}</legend>
      <fieldset v-if="profilesLoaded" class="share-profiles">
        <legend>{{ t("分享人物") }}</legend>
        <label class="checkbox-label">
          <input type="radio" :checked="allProfiles" @change="allProfiles = true; profileIDs = []" />
          {{ t("全部内容") }}
        </label>
        <label v-for="profile in profiles" :key="profile.id" class="checkbox-label">
          <input type="checkbox" :value="profile.id" v-model="profileIDs" @change="allProfiles = false" />
          {{ profile.nickname || profile.name }}
        </label>
        <p v-if="!allProfiles" class="muted">{{ t(profileIDs.length ? "包含关联任一所选人物的内容。" : "请选择至少一位人物，或选择全部内容。") }}</p>
      </fieldset>
      <template v-else-if="loadError">
        <p role="alert">{{ loadError }}</p>
        <button type="button" class="text-button" @click="load">{{ t("重新加载人物") }}</button>
      </template>
      <p v-else role="status">{{ t("正在加载人物…") }}</p>
      <label
        >{{ t("开始时间")
        }}<select
          v-model="startMode"
          @change="chooseStart"
          :aria-label="t('开始时间快捷选择')"
        >
          <option value="earliest">{{ t("最早") }}</option>
          <option value="year">{{ t("一年前") }}</option>
          <option value="halfYear">{{ t("六个月前") }}</option>
          <option value="custom">{{ t("自选日期") }}</option>
        </select></label
      >
      <p v-if="startMode === 'earliest' && !earliest" class="muted">
        {{ t("暂无有日期且允许分享的内容，可选择自选日期。") }}
      </p>
      <div class="share-fields">
        <label
          >{{ t("开始日期")
          }}<DateField
            v-model="start"
            required
            :disabled="startMode !== 'custom'"
        /></label>
        <label
          >{{ t("结束日期（含当天）")
          }}<DateField v-model="end" required /><button
            type="button"
            class="text-button"
            @click="end = dateString(new Date())"
          >
            {{ t("今天") }}
          </button></label
        >
      </div>
      <p v-if="start && end && start > end" role="alert">
        {{ t("结束日期不能早于开始日期") }}
      </p>
      </fieldset>
      <fieldset class="share-form-section" :disabled="busy">
        <legend>{{ t("链接有效期") }}</legend>
      <label
        >{{ t("有效时长（小时）")
        }}<input
          v-model.number="hours"
          type="number"
          min="1"
          max="168"
          step="1"
          required
        /><small>{{ t("1 小时至 7 天") }}</small></label
      >
      </fieldset>
      <div class="share-help">
        <p>
          {{
            t(
              "是否允许分享，请在文件、文件夹或当天时间线中设置。关闭后，仅管理员可见，已有和新建的分享也会隐藏对应内容。",
            )
          }}
        </p>
      </div>
      <p v-if="creatingError" role="alert" class="notice">{{ creatingError }}</p>
      <div class="dialog-actions">
        <button type="submit" class="button primary" :disabled="busy || !valid">
          <Link :size="16" />{{ busy ? t("正在创建…") : t("创建分享链接") }}
        </button>
      </div>
    </form>
    <div v-if="link" class="created-share" role="status">
      <label
        >{{ t("分享链接")
        }}<input
          :value="link"
          readonly
          @focus="($event.target as HTMLInputElement).select()"
      /></label>
      <div class="share-link-actions">
        <button class="button primary" @click="copy">{{ t("复制链接") }}</button
        ><a class="button" :href="link" target="_blank" rel="noreferrer">{{
          t("预览分享")
        }}</a>
      </div>
    </div>
    <details v-if="history.length" class="share-history">
      <summary>{{ t("管理最近的分享") }} · {{ history.length }}</summary>
      <div v-for="item in history" :key="item.id" class="history-row">
        <div>
          <b>{{ item.card_title || item.title || t("成长时间线") }}</b
          ><small>{{ item.scope === "selection" ? t("指定影像分享") + " · " + item.selected_count : item.start_date + " — " + item.end_date }}</small
          ><small
            >{{ t("到期时间") }}:
            {{ new Date(item.expires_at).toLocaleString(locale) }}</small
          >
          <small class="share-counts">{{ t("访问 {count} 次", { count: item.visit_count ?? 0 }) }} · {{ t("访客 {count} 人", { count: item.visitor_count ?? 0 }) }}</small>
        </div>
        <div class="share-link-actions">
          <span v-if="item.revoked || item.expired" class="muted">{{ item.revoked ? t("已撤销") : t("已过期") }}</span>
          <template v-else>
            <template v-if="item.id === activeLinkID && link">
              <a class="text-button" :href="link" target="_blank" rel="noreferrer">{{ t("预览分享") }}</a>
              <button class="text-button" @click="copy">{{ t("复制链接") }}</button>
            </template>
            <button v-else-if="item.link_available" class="text-button" :disabled="busy" @click="viewRecord(item)">{{ t("查看链接") }}</button>
            <button class="text-button" :disabled="busy" @click="revoke(item)"><X :size="14" />{{ t("撤销分享") }}</button>
          </template>
          <button v-if="item.can_copy && (!item.link_available || item.revoked || item.expired)" class="text-button"
            :disabled="busy || !Number.isInteger(hours) || hours < 1 || hours > 168"
            @click="copyRecord(item)">{{ t("按原范围创建新链接") }}</button>
        </div>
      </div>
      <p class="muted share-footnote">{{ t("访客按浏览器客户端去重，清除 Cookie 或更换浏览器会计为新访客。统计从功能启用后开始，预览也计入访问。") }}</p>
    </details>
    <p class="muted share-footnote">
      {{
        t(
          "持有链接的人均可阅读，请只发给信任的人。撤销后停止新的访问，已签发的预览地址最多再有效 60 秒，已保存的内容无法收回。",
        )
      }}
    </p>
  </MotionDialog>
</template>
<style scoped>
.share-form-section {
  margin-top: 16px;
  padding: 0 12px 2px;
  border: 1px solid var(--line);
  border-radius: 8px;
}
.share-form-section > legend {
  padding-inline: 5px;
  font-weight: var(--weight-heading);
}
.share-form-section label {
  margin-block: 10px;
}
.share-profiles {
  border: 0;
  padding: 0;
  margin: 10px 0;
  min-width: 0;
}
.share-profiles legend {
  padding: 0;
}
.share-profiles .checkbox-label {
  margin: 0;
  min-height: 44px;
  color: var(--text);
  font-size: 14px;
}

.share-fields {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}
.share-help {
  background: var(--sage-light);
  border-radius: 10px;
  padding: 14px;
  margin: 16px 0;
  line-height: 1.7;
}
.share-help p {
  margin: 5px 0;
  font-size: 12px;
}
.created-share {
  padding: 16px;
  border: 1px solid var(--sage);
  border-radius: 10px;
}
.share-link-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 10px;
}
.share-history {
  margin-top: 24px;
}
.share-history summary {
  cursor: pointer;
}
.history-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid var(--line);
}
.history-row > div:first-child {
  min-width: 0;
  overflow-wrap: anywhere;
}
.history-row small {
  display: block;
  margin-top: 5px;
  color: var(--muted);
}
.share-counts {
  font-variant-numeric: tabular-nums;
}
.share-footnote {
  font-size: 11px;
  line-height: 1.8;
  margin-top: 20px;
}
@media (max-width: 600px) {
  .share-fields {
    grid-template-columns: 1fr;
  }
}
</style>
