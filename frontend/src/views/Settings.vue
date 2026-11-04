<script setup lang="ts">
import LanguageSwitch from "../components/LanguageSwitch.vue";
import { t } from "../lib/i18n";
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import {
  ShieldCheck,
  UserPlus,
  KeyRound,
  Archive,
  Settings,
  Trash2,
  Baby,
  ArrowUpRight,
} from "lucide-vue-next";
import { api, post, del, notify, bytes } from "../lib/api";
import { useYearly } from "../stores/yearly";
const yearly = useYearly(),
  router = useRouter(),
  members = ref<any[]>([]),
  config = ref<any>(),
  password = ref({ old_password: "", new_password: "" }),
  member = ref({ username: "", password: "", role: "member" }),
  addOpen = ref(false),
  busy = ref(false);
async function load() {
  if (!yearly.isAdmin) return;
  try {
    [members.value, config.value] = await Promise.all([
      api("/users"),
      api("/settings"),
    ]);
  } catch (e) {
    notify(e);
  }
}
onMounted(load);
async function add() {
  busy.value = true;
  try {
    await post("/users", member.value);
    member.value = { username: "", password: "", role: "member" };
    addOpen.value = false;
    await load();
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
async function disable(id: number) {
  try {
    await del("/users/" + id);
    await load();
  } catch (e) {
    notify(e);
  }
}
async function changePassword() {
  busy.value = true;
  try {
    await post("/auth/password", password.value);
    yearly.user = null;
    router.push("/login");
  } catch (e) {
    notify(e);
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">A SAFE PLACE FOR OUR FAMILY</span>
      <h1>{{ t("照顾好这个小小的家。") }}</h1>
      <p>{{ t("一起记录，也一起守护每一份回忆。") }}</p>
    </div>
  </div>
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
        <span> {{ t("当前账户") }} </span><b>{{ yearly.user?.username }}</b>
      </div>
      <div class="setting-row">
        <span> {{ t("家庭角色") }} </span
        ><b>{{
          yearly.isAdmin
            ? t("管理员")
            : yearly.canEdit
              ? t("家庭成员")
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
      <p class="muted">
        {{
          t(
            "家庭空间内共享内容。成员可编辑影像和日记，访客只读，管理员负责账户、档案删除与备份导出。",
          )
        }}
      </p>
      <RouterLink to="/children" class="setting-link"
        ><Baby :size="17" /> {{ t("孩子与宠物") }}
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
      <form @submit.prevent="changePassword">
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
            :placeholder="t('至少 12 个字符')" /></label
        ><button class="button" :disabled="busy">
          {{ t("更新密码并重新登录") }}
        </button>
      </form>
    </section>
    <section v-if="yearly.isAdmin" class="panel wide">
      <div class="section-heading">
        <h2>{{ t("一起记录的人") }}</h2>
        <button class="button small" @click="addOpen = true">
          <UserPlus :size="15" /> {{ t("添加家庭成员") }}
        </button>
      </div>
      <div v-for="m in members" :key="m.id" class="member-row">
        <span class="avatar">{{ m.username.slice(0, 1).toUpperCase() }}</span
        ><span
          ><b>{{ m.username }}</b
          ><small
            >{{
              m.role === "admin"
                ? t("管理员")
                : m.role === "member"
                  ? t("可编辑成员")
                  : t("只读访客")
            }}
            · {{ m.active ? t("启用") : t("已停用") }}</small
          ></span
        ><ElPopconfirm
          v-if="m.id !== yearly.user?.id && m.active"
          :title="t('停用此账户并注销其登录会话？')"
          @confirm="disable(m.id)"
          ><template #reference
            ><button class="text-button danger">
              {{ t("停用") }}
            </button></template
          ></ElPopconfirm
        >
      </div>
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
  </div>
  <ElDialog v-model="addOpen" :title="t('邀请一个家人')" width="500px"
    ><form @submit.prevent="add">
      <label>
        {{ t("用户名") }}
        <input
          v-model="member.username"
          required
          minlength="2"
          maxlength="80"
          autocomplete="off" /></label
      ><label>
        {{ t("初始密码") }}
        <input
          v-model="member.password"
          type="password"
          required
          minlength="12"
          maxlength="256"
          autocomplete="new-password" /></label
      ><label>
        {{ t("家庭权限") }}
        <select v-model="member.role">
          <option value="member">{{ t("成员 · 浏览与编辑") }}</option>
          <option value="viewer">{{ t("访客 · 仅浏览") }}</option>
          <option value="admin">{{ t("管理员 · 完整管理") }}</option>
        </select></label
      >
      <div class="dialog-actions">
        <button class="button primary" :disabled="busy">
          {{ t("创建账户") }}
        </button>
      </div>
    </form></ElDialog
  >
</template>
