<script setup lang="ts">
import { ref, watch } from "vue";
import { api } from "../lib/api";
import { t, locale } from "../lib/i18n";
const props = defineProps<{
  resourceType?: string;
  resourceId?: string | number;
}>();
const rows = ref<any[]>([]),
  total = ref(0),
  page = ref(1),
  loading = ref(false),
  error = ref("");
const resources: Record<string, string> = {
  media: "文件",
  timeline_folder: "文件夹",
  child: "档案",
  timeline_event: "日记",
  timeline_day: "日期设置",
  timeline_share: "分享",
  sys_user: "账户",
};
const fields: Record<string, string> = {
  title: "标题",
  name: "名称",
  username: "用户名",
  nickname: "昵称",
  role: "账户角色",
  active: "启用账户",
  password: "密码",
  status: "状态",
  share_allowed: "允许分享",
  child_ids: "人物与宠物",
  media_ids: "关联影像",
  folder_id: "文件夹",
  timeline_date: "归档日期",
  batch_name: "批次名称",
  remark: "备注",
  content: "日记内容",
  sort_order: "顺序",
  owner_id: "创建人",
  created_by: "创建人",
  location_name: "地点",
  revoked: "撤销分享",
  expires_at: "有效期",
};
function value(data: any) {
  if (data === null || data === undefined || data === "") return t("空");
  if (typeof data === "boolean") return data ? t("是") : t("否");
  if (typeof data === "object") return JSON.stringify(data);
  return String(data);
}
function time(date: string) {
  return new Date(date + "Z").toLocaleString(locale.value);
}
async function load() {
  loading.value = true;
  error.value = "";
  try {
    const params = new URLSearchParams({ page: String(page.value) });
    if (props.resourceType) params.set("resource_type", props.resourceType);
    if (props.resourceId != null)
      params.set("resource_id", String(props.resourceId));
    const result = await api("/audit-logs?" + params);
    rows.value = result.items;
    total.value = result.total;
  } catch (e) {
    error.value = (e as Error).message;
  } finally {
    loading.value = false;
  }
}
watch(
  () => [props.resourceType, props.resourceId],
  () => {
    page.value = 1;
    load();
  },
  { immediate: true },
);
</script>
<template>
  <section class="audit-history">
    <p v-if="error" role="alert" class="notice">
      {{ error }}
      <button class="text-button" @click="load">{{ t("重试") }}</button>
    </p>
    <p v-if="loading" role="status" class="muted">{{ t("正在加载…") }}</p>
    <template v-else>
      <p v-if="!rows.length" class="muted">
        {{ t("暂无修改日志。历史操作从本次升级后开始记录。") }}
      </p>
      <article v-for="row in rows" :key="row.id" class="audit-entry">
        <div class="audit-heading">
          <b>{{ row.actor_name }}</b
          ><span
            >{{
              t(
                row.action === "create"
                  ? "创建"
                  : row.action === "delete"
                    ? "删除"
                    : "修改",
              )
            }}{{
              " " + t(resources[row.resource_type] || row.resource_type)
            }}
            #{{ row.resource_id }}</span
          ><time>{{ time(row.created_at) }}</time>
        </div>
        <details>
          <summary>
            {{ t("查看字段变化") }} · {{ Object.keys(row.changes).length }}
          </summary>
          <dl>
            <template v-for="(change, field) in row.changes" :key="field"
              ><dt>{{ t(fields[String(field)] || String(field)) }}</dt>
              <dd v-if="field === 'password'">{{ t("已更新密码") }}</dd>
              <dd v-else>
                <span class="muted">{{ value(change.before) }}</span
                ><span aria-hidden="true"> → </span>{{ value(change.after) }}
              </dd></template
            >
          </dl>
        </details>
      </article>
      <div v-if="total > 20" class="audit-pages">
        <button
          class="button small"
          :disabled="page === 1"
          @click="
            page--;
            load();
          "
        >
          {{ t("上一页") }}</button
        ><span>{{ page }} / {{ Math.ceil(total / 20) }}</span
        ><button
          class="button small"
          :disabled="page * 20 >= total"
          @click="
            page++;
            load();
          "
        >
          {{ t("下一页") }}
        </button>
      </div>
    </template>
  </section>
</template>
<style scoped>
.audit-entry {
  padding: 16px 0;
  border-bottom: 1px solid var(--line);
}
.audit-heading {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 8px;
  font-size: 13px;
}
.audit-heading time {
  margin-left: auto;
  color: var(--muted);
  font-size: 12px;
}
summary {
  cursor: pointer;
  font-size: 12px;
  margin-top: 10px;
  color: var(--muted);
}
dl {
  margin-bottom: 0;
  font-size: 12px;
}
dt {
  font-weight: 600;
  margin-top: 10px;
}
dd {
  margin: 4px 0 0;
  overflow-wrap: anywhere;
  white-space: pre-wrap;
  max-height: 200px;
  overflow: auto;
}
.audit-pages {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 14px;
  padding-top: 20px;
}
</style>
