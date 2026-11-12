<script setup lang="ts">
import MotionDialog from "../components/MotionDialog.vue";
import { onMounted, ref } from "vue";
import { useRouter } from "vue-router";
import { UserPlus, Pencil, ShieldCheck, Users } from "lucide-vue-next";
import { api, post, put } from "../lib/api";
import { accountName } from "../lib/accounts";
import { t } from "../lib/i18n";
import { useYearly } from "../stores/yearly";
const yearly = useYearly(),
  router = useRouter();
const users = ref<any[]>([]),
  loading = ref(false),
  error = ref("");
const open = ref(false),
  busy = ref(false),
  formError = ref("");
const editing = ref<number | null>(null);
const form = ref({ username: "", nickname: "", password: "", role: "member", active: true });
async function load() {
  loading.value = true;
  error.value = "";
  try {
    users.value = await api("/users");
  } catch (e) {
    error.value = (e as Error).message;
  } finally {
    loading.value = false;
  }
}
function edit(user?: any) {
  editing.value = user?.id || null;
  form.value = {
    username: user?.username || "",
    nickname: user?.nickname || "",
    password: "",
    role: user?.role || "member",
    active: user?.active ?? true,
  };
  formError.value = "";
  open.value = true;
}
async function save() {
  if (busy.value) return;
  busy.value = true;
  formError.value = "";
  try {
    if (editing.value) {
      const result = await put(`/users/${editing.value}`, {
        ...form.value,
        password: form.value.password || null,
      });
      if (result.reauthenticate) {
        yearly.user = null;
        await router.push("/login");
        return;
      }
      if (editing.value === yearly.user?.id) yearly.user = { ...yearly.user, nickname: form.value.nickname.trim() };
    } else await post("/users", form.value);
    open.value = false;
    await load();
  } catch (e) {
    formError.value = (e as Error).message;
  } finally {
    busy.value = false;
  }
}
onMounted(load);
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">ACCOUNTS & ACCESS</span>
      <h1>{{ t("账户管理") }}</h1>
    </div>
    <button class="button primary" @click="edit()">
      <UserPlus :size="18" />{{ t("创建账户") }}
    </button>
  </div>
  <section class="panel account-policy">
    <ShieldCheck :size="22" />
    <div>
      <h2>{{ t("每份内容都有归属") }}</h2>
      <p class="muted">
        {{
          t(
            "普通账户仅编辑自己的内容；管理员可管理全部内容与账户。",
          )
        }}
      </p>
    </div>
  </section>
  <p v-if="error" role="alert" class="notice">
    {{ error }}
    <button class="text-button" @click="load">{{ t("重试") }}</button>
  </p>
  <p v-if="loading" role="status">{{ t("正在加载…") }}</p>
  <section v-else class="panel">
    <div class="section-heading">
      <h2>
        <Users :size="19" />{{ t("家庭账户") }}
        <small>{{ users.length }}</small>
      </h2>
      <RouterLink class="text-button" to="/activity">{{
        t("查看修改日志")
      }}</RouterLink>
    </div>
    <div v-for="user in users" :key="user.id" class="member-row account-row">
      <span class="avatar">{{ accountName(user).slice(0, 1).toUpperCase() }}</span>
      <div class="account-identity">
        <b>{{ accountName(user) }}</b><small v-if="accountName(user) !== user.username">{{ user.username }}</small
        ><small
          >{{
            user.role === "admin"
              ? t("管理员")
              : user.role === "viewer"
                ? t("只读访客")
                : t("普通账户")
          }}
          · {{ user.active ? t("启用") : t("已停用")
          }}<template v-if="user.id === yearly.user?.id">
            · {{ t("当前账户") }}</template
          ></small
        >
      </div>
      <button class="button small" @click="edit(user)">
        <Pencil :size="14" />{{ t("编辑账户") }}
      </button>
    </div>
    <p v-if="!users.length" class="muted">{{ t("暂无账户") }}</p>
  </section>
  <MotionDialog
    v-model="open"
    :title="editing ? t('编辑账户') : t('创建账户')"
    width="500px"
    :close-on-click-modal="false"
    :close-on-press-escape="!busy"
    :show-close="!busy"
  >
    <form
      @submit.prevent="save"
      @keydown.enter="$event.isComposing && $event.preventDefault()"
    >
      <label>{{ t("昵称") }}<input v-model.trim="form.nickname" maxlength="80" autocomplete="nickname" :disabled="busy" /></label>
      <p class="muted">{{ t("优先显示昵称，留空则显示用户名。昵称不会更改登录用户名。") }}</p>
      <label
        >{{ t("用户名")
        }}<input
          v-model="form.username"
          required
          minlength="2"
          maxlength="80"
          autocomplete="off"
          :disabled="busy"
      /></label>
      <label
        >{{ editing ? t("重置密码") : t("初始密码")
        }}<input
          v-model="form.password"
          type="password"
          :required="!editing"
          minlength="12"
          maxlength="256"
          autocomplete="new-password"
          :placeholder="editing ? t('留空保留当前密码') : t('至少 12 个字符')"
          :disabled="busy"
      /></label>
      <label
        >{{ t("账户角色")
        }}<select
          v-model="form.role"
          :disabled="busy || editing === yearly.user?.id"
        >
          <option value="member">{{ t("普通账户") }}</option>
          <option value="admin">{{ t("管理员") }}</option>
          <option v-if="form.role === 'viewer'" value="viewer">
            {{ t("只读访客") }}
          </option>
        </select></label
      >
      <label v-if="editing" class="checkbox-label"
        ><input
          v-model="form.active"
          type="checkbox"
          :disabled="busy || editing === yearly.user?.id"
        />{{ t("启用账户") }}</label
      >
      <p class="muted">
        {{ t("修改用户名、角色或密码，以及停用账户后，该账户需要重新登录。角色变更会撤销该账户已有分享。") }}
      </p>
      <p v-if="formError" role="alert" class="notice">{{ formError }}</p>
      <div class="dialog-actions">
        <button
          type="button"
          class="button"
          :disabled="busy"
          @click="open = false"
        >
          {{ t("取消") }}</button
        ><button class="button primary" :disabled="busy">
          {{ busy ? t("正在保存…") : t("保存账户") }}
        </button>
      </div>
    </form>
  </MotionDialog>
</template>
<style scoped>
.account-policy {
  display: flex;
  gap: 16px;
  align-items: flex-start;
  margin-bottom: 24px;
}
.account-policy h2 {
  margin-top: 0;
}
.account-policy p {
  margin-bottom: 0;
}
.account-identity {
  min-width: 0;
  flex: 1;
  overflow-wrap: anywhere;
}
.account-identity small {
  display: block;
  margin-top: 6px;
  color: var(--muted);
}
.account-row {
  gap: 12px;
  flex-wrap: wrap;
}
@media (max-width: 480px) {
  .section-heading {
    flex-wrap: wrap;
    gap: 12px;
  }
  .account-row {
    display: grid;
    grid-template-columns: 36px minmax(0, 1fr);
  }
  .account-row .avatar {
    width: 36px;
    height: 36px;
  }
  .account-row > button {
    grid-column: 2;
    justify-self: start;
  }
}
</style>
