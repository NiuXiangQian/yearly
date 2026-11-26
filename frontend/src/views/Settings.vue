<script setup lang="ts">
import PageHeading from "../components/PageHeading.vue";
import LanguageSwitch from "../components/LanguageSwitch.vue";
import { t } from "../lib/i18n";
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import {
  ShieldCheck,
  KeyRound,
  Archive,
  Trash2,
  Users,
  ArrowUpRight,
  ScanFace,
  LogOut,
} from "lucide-vue-next";
import { api, post, notify, bytes } from "../lib/api";
import { useYearly } from "../stores/yearly";
import { accountName } from "../lib/accounts";
const yearly = useYearly(),
  router = useRouter(),
  config = ref<any>(),
  password = ref({ old_password: "", new_password: "" }),
  busy = ref(false),
  passwordError = ref(""),
  logoutError = ref(""),
  loggingOut = ref(false);
async function load() {
  if (!yearly.isAdmin) return;
  try {
    config.value = await api("/settings");
  } catch (e) {
    notify(e);
  }
}
onMounted(load);
async function changePassword() {
  if (busy.value) return;
  passwordError.value = "";
  busy.value = true;
  try {
    await post("/auth/password", password.value);
    yearly.user = null;
    router.push("/login");
  } catch (e) {
    passwordError.value = e instanceof Error ? e.message : t("操作失败");
  } finally {
    busy.value = false;
  }
}
async function logout() {
  if (loggingOut.value) return;
  logoutError.value = "";
  loggingOut.value = true;
  try {
    await yearly.logout();
    await router.push("/login");
  } catch (error) {
    logoutError.value = error instanceof Error ? error.message : t("操作失败");
  } finally {
    loggingOut.value = false;
  }
}
</script>
<template>
  <PageHeading :title="t('家庭与设置')" />
  <div class="settings-layout">
    <section class="panel">
      <div class="section-heading">
        <h2><ShieldCheck :size="20" /> {{ t("家庭空间") }}</h2>
        <span class="secure-badge"> {{ t("私密") }} </span>
      </div>
      <div class="setting-row">
        <span>{{ t("界面语言") }}</span
        ><LanguageSwitch />
      </div>
      <div class="setting-row">
        <span> {{ t("当前账户") }} </span><b>{{ accountName(yearly.user) }}</b>
      </div>
      <div class="setting-row">
        <span> {{ t("家庭角色") }} </span
        ><b>{{
          yearly.isAdmin
            ? t("管理员")
            : yearly.canEdit
              ? t("普通账户")
              : t("只读访客")
        }}</b>
      </div>
      <div class="setting-row">
        <span> {{ t("公开注册") }} </span><b> {{ t("已关闭") }} </b>
      </div>
      <div class="setting-row">
        <span> {{ t("原文件存储") }} </span
        ><b>{{ bytes(yearly.stats.bytes) }}</b>
      </div>
    </section>
    <section class="panel settings-links">
      <h2>{{ t("管理与记录") }}</h2>
      <RouterLink v-if="yearly.isAdmin" to="/face-review" class="setting-link"
        ><ScanFace :size="17" aria-hidden="true" />{{ t("相册整理") }}<ArrowUpRight :size="16" aria-hidden="true" /></RouterLink>
      <RouterLink v-if="yearly.isAdmin" to="/accounts" class="setting-link"
        ><Users :size="17" />{{ t("账户管理")
        }}<ArrowUpRight :size="16" /></RouterLink
      ><RouterLink to="/activity" class="setting-link"
        ><Archive :size="17" />{{ t("修改日志")
        }}<ArrowUpRight :size="16" /></RouterLink
      ><RouterLink to="/children" class="setting-link"
        ><Users :size="17" /> {{ t("人物与宠物") }}
        <ArrowUpRight :size="16" /></RouterLink
      ><RouterLink to="/trash" class="setting-link"
        ><Trash2 :size="17" /> {{ t("回收站") }}
        <ArrowUpRight :size="16" /></RouterLink
      ><RouterLink v-if="yearly.isAdmin" to="/backup" class="setting-link"
        ><Archive :size="17" /> {{ t("备份与迁移") }} <ArrowUpRight :size="16"
      /></RouterLink>
    </section>
    <section class="panel">
      <h2><KeyRound :size="20" /> {{ t("账户密码") }}</h2>
      <p class="muted">{{ t("修改后会注销此账户的所有登录会话。") }}</p>
      <form @submit.prevent="changePassword" @keydown.enter="$event.isComposing && $event.preventDefault()">
        <label>
          {{ t("当前密码") }}
          <input
            v-model="password.old_password"
            type="password"
            autocomplete="current-password"
            required /></label
        ><label>
          {{ t("新密码") }}
          <input
            v-model="password.new_password"
            type="password"
            autocomplete="new-password"
            minlength="12"
            maxlength="256"
            required
            :placeholder="t('至少 12 个字符')" /></label>
        <p v-if="passwordError" class="notice" role="alert">{{ passwordError }}</p>
        <button type="submit" class="button" :disabled="busy">
          {{ t("更新密码并重新登录") }}
        </button>
      </form>
    </section>
    <section v-if="config" class="panel wide">
      <div class="section-heading">
        <h2>{{ t("存储与系统") }}</h2>
        <span class="chip" :class="{ warning: !config.storage_configured }">{{
          config.storage_configured ? t("OSS 已配置") : t("OSS 待配置")
        }}</span>
      </div>
      <div class="setting-row">
        <span> {{ t("私有 Bucket") }} </span
        ><code>{{ config.bucket || t("未配置") }}</code>
      </div>
      <div class="setting-row">
        <span> {{ t("地域") }} </span><code>{{ config.region }}</code>
      </div>
      <div class="setting-row">
        <span> {{ t("自定义域名") }} </span
        ><code>{{ config.custom_domain || t("使用地域 Endpoint") }}</code>
      </div>
      <div class="setting-row">
        <span> {{ t("单文件上限") }} </span
        ><b>{{ bytes(config.max_file_size) }}</b>
      </div>
      <div class="setting-row">
        <span> {{ t("分片大小") }} </span><b>{{ bytes(config.part_size) }}</b>
      </div>
      <p class="muted">
        {{
          t(
            "敏感配置由所选环境的 .env.test / .env.production 管理。保存后重启服务生效。预览独立保存，原文件始终无损保留。",
          )
        }}
      </p>
    </section>
    <section class="panel settings-signout">
      <p v-if="logoutError" class="notice" role="alert">{{ logoutError }}</p>
      <button type="button" class="button danger" :disabled="loggingOut" @click="logout">
        <LogOut :size="17" aria-hidden="true" /> {{ t("退出登录") }}
      </button>
    </section>
  </div>
</template>
