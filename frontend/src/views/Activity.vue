<script setup lang="ts">
import { ref } from "vue";
import { useRoute } from "vue-router";
import AuditHistory from "../components/AuditHistory.vue";
import { useYearly } from "../stores/yearly";
import { t } from "../lib/i18n";
const yearly = useYearly(),
  route = useRoute();
const resource = ref(String(route.query.type || ""));
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">CHANGE HISTORY</span>
      <h1>{{ t("修改日志") }}</h1>
      <p>
        {{
          yearly.isAdmin
            ? t("查看所有账户对文件、文件夹和设置的修改记录。")
            : t("查看自己内容的修改记录及当前账户的操作记录。")
        }}
      </p>
    </div>
  </div>
  <section class="panel">
    <label
      >{{ t("内容类型")
      }}<select v-model="resource">
        <option value="">{{ t("全部类型") }}</option>
        <option value="media">{{ t("文件") }}</option>
        <option value="timeline_folder">{{ t("文件夹") }}</option>
        <option value="child">{{ t("档案") }}</option>
        <option value="timeline_event">{{ t("日记") }}</option>
        <option value="timeline_share">{{ t("分享") }}</option>
        <option value="timeline_day">{{ t("日期设置") }}</option>
        <option v-if="yearly.isAdmin" value="sys_user">{{ t("账户") }}</option>
      </select></label
    ><AuditHistory :resource-type="resource || undefined" />
  </section>
</template>
