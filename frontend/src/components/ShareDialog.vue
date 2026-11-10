<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { ElMessage } from "element-plus";
import { Link, X } from "lucide-vue-next";
import { api, post, del, notify, sitePath } from "../lib/api";
import { t, locale } from "../lib/i18n";
import DateField from "./DateField.vue";
const props = defineProps<{ open: boolean; initialDate?: string }>();
const emit = defineEmits(["close"]);
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
  activeLinkID = ref<number>();
function showLink(id: number, token: string) {
  link.value = location.origin + sitePath(`/share/${token}`);
  activeLinkID.value = id;
}
const valid = computed(
  () =>
    start.value &&
    end.value &&
    start.value <= end.value &&
    Number.isInteger(hours.value) &&
    hours.value >= 1 &&
    hours.value <= 168,
);
watch(
  () => props.open,
  async (open) => {
    if (!open) {
      link.value = "";
      activeLinkID.value = undefined;
      return;
    }
    startMode.value = props.initialDate ? "custom" : "earliest";
    start.value = props.initialDate || "";
    end.value = props.initialDate || dateString(new Date());
    try {
      const [links, bounds] = await Promise.all([
        api("/shares"),
        api("/shares/bounds"),
      ]);
      history.value = links;
      earliest.value = bounds.earliest || "";
      chooseStart();
    } catch (e) {
      notify(e);
    }
  },
);
async function create() {
  if (!valid.value || busy.value) return;
  busy.value = true;
  try {
    const data = await post("/shares", {
      start_date: start.value,
      end_date: end.value,
      hours: hours.value,
    });
    showLink(data.id, data.token);
    history.value.unshift(data);
    ElMessage.success(t("分享链接已创建"));
  } catch (e) {
    notify(e);
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
  <ElDialog
    :model-value="open"
    :title="t('分享时间线')"
    width="620px"
    class="share-dialog"
    @close="emit('close')"
  >
    <p class="muted">{{ t("选择时间线范围，自动分享其中允许分享的内容。") }}</p>
    <form @submit.prevent="create">
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
      <p v-if="start && end && start > end" role="alert">
        {{ t("结束日期不能早于开始日期") }}
      </p>
      <div class="share-help">
        <p>
          {{
            t(
              "是否允许分享，请在文件、文件夹或当天时间线中设置。关闭后，已有和新建的分享都会隐藏对应内容。",
            )
          }}
        </p>
        <p>
          {{
            t(
              "范围包含全部孩子的内容，并随时间线更新；仅展示允许分享的影像与日记。",
            )
          }}
        </p>
      </div>
      <div class="dialog-actions">
        <button class="button primary" :disabled="busy || !valid">
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
          <b>{{ item.title || t("成长时间线") }}</b
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
  </ElDialog>
</template>
<style scoped>
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
