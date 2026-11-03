<script setup lang="ts">
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
      <h1>照顾好这个小小的家。</h1>
      <p>一起记录，也一起守护每一份回忆。</p>
    </div>
  </div>
  <div class="settings-layout">
    <section class="panel">
      <div class="section-heading">
        <h2><ShieldCheck :size="20" />家庭空间</h2>
        <span class="secure-badge">私密</span>
      </div>
      <div class="setting-row">
        <span>当前账户</span><b>{{ yearly.user?.username }}</b>
      </div>
      <div class="setting-row">
        <span>家庭角色</span
        ><b>{{
          yearly.isAdmin ? "管理员" : yearly.canEdit ? "家庭成员" : "只读访客"
        }}</b>
      </div>
      <div class="setting-row"><span>公开注册</span><b>已关闭</b></div>
      <div class="setting-row">
        <span>原文件存储</span><b>{{ bytes(yearly.stats.bytes) }}</b>
      </div>
      <p class="muted">
        家庭空间内共享内容。成员可编辑影像和日记，访客只读，管理员负责账户、孩子删除与备份导出。
      </p>
      <RouterLink to="/children" class="setting-link"
        ><Baby :size="17" />孩子档案<ArrowUpRight :size="16" /></RouterLink
      ><RouterLink to="/trash" class="setting-link"
        ><Trash2 :size="17" />回收站<ArrowUpRight :size="16" /></RouterLink
      ><RouterLink v-if="yearly.isAdmin" to="/backup" class="setting-link"
        ><Archive :size="17" />备份与迁移<ArrowUpRight :size="16"
      /></RouterLink>
    </section>
    <section class="panel">
      <h2><KeyRound :size="20" />账户密码</h2>
      <p class="muted">修改后会注销此账户的所有登录会话。</p>
      <form @submit.prevent="changePassword">
        <label
          >当前密码<input
            v-model="password.old_password"
            type="password"
            autocomplete="current-password"
            required /></label
        ><label
          >新密码<input
            v-model="password.new_password"
            type="password"
            autocomplete="new-password"
            minlength="12"
            maxlength="256"
            required
            placeholder="至少 12 个字符" /></label
        ><button class="button" :disabled="busy">更新密码并重新登录</button>
      </form>
    </section>
    <section v-if="yearly.isAdmin" class="panel wide">
      <div class="section-heading">
        <h2>一起记录的人</h2>
        <button class="button small" @click="addOpen = true">
          <UserPlus :size="15" />添加家庭成员
        </button>
      </div>
      <div v-for="m in members" :key="m.id" class="member-row">
        <span class="avatar">{{ m.username.slice(0, 1).toUpperCase() }}</span
        ><span
          ><b>{{ m.username }}</b
          ><small
            >{{
              m.role === "admin"
                ? "管理员"
                : m.role === "member"
                  ? "可编辑成员"
                  : "只读访客"
            }}
            · {{ m.active ? "启用" : "已停用" }}</small
          ></span
        ><ElPopconfirm
          v-if="m.id !== yearly.user?.id && m.active"
          title="停用此账户并注销其登录会话？"
          @confirm="disable(m.id)"
          ><template #reference
            ><button class="text-button danger">停用</button></template
          ></ElPopconfirm
        >
      </div>
    </section>
    <section v-if="config" class="panel wide">
      <div class="section-heading">
        <h2>存储与系统</h2>
        <span class="chip" :class="{ warning: !config.storage_configured }">{{
          config.storage_configured ? "OSS 已配置" : "OSS 待配置"
        }}</span>
      </div>
      <div class="setting-row">
        <span>私有 Bucket</span><code>{{ config.bucket || "未配置" }}</code>
      </div>
      <div class="setting-row">
        <span>地域</span><code>{{ config.region }}</code>
      </div>
      <div class="setting-row">
        <span>自定义域名</span
        ><code>{{ config.custom_domain || "使用地域 Endpoint" }}</code>
      </div>
      <div class="setting-row">
        <span>单文件上限</span><b>{{ bytes(config.max_file_size) }}</b>
      </div>
      <div class="setting-row">
        <span>分片大小</span><b>{{ bytes(config.part_size) }}</b>
      </div>
      <p class="muted">
        敏感配置由所选环境的 .env.test / .env.production
        管理。保存后重启服务生效。预览独立保存，原文件始终无损保留。
      </p>
    </section>
  </div>
  <ElDialog v-model="addOpen" title="邀请一个家人" width="500px"
    ><form @submit.prevent="add">
      <label
        >用户名<input
          v-model="member.username"
          required
          minlength="2"
          maxlength="80"
          autocomplete="off" /></label
      ><label
        >初始密码<input
          v-model="member.password"
          type="password"
          required
          minlength="12"
          maxlength="256"
          autocomplete="new-password" /></label
      ><label
        >家庭权限<select v-model="member.role">
          <option value="member">成员 · 浏览与编辑</option>
          <option value="viewer">访客 · 仅浏览</option>
          <option value="admin">管理员 · 完整管理</option>
        </select></label
      >
      <div class="dialog-actions">
        <button class="button primary" :disabled="busy">创建账户</button>
      </div>
    </form></ElDialog
  >
</template>
