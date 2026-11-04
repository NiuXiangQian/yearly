<script setup lang="ts">
import LanguageSwitch from "../components/LanguageSwitch.vue";
import { t } from "../lib/i18n";
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import { Leaf, ShieldCheck, ArrowRight } from "lucide-vue-next";
import { api, post, notify, setCSRF } from "../lib/api";
import { useYearly } from "../stores/yearly";
import EmptyState from "../components/EmptyState.vue";
const form = ref({ username: "", password: "", captcha: "", captcha_id: "" }),
  image = ref(""),
  environment = ref(""),
  busy = ref(false);
const yearly = useYearly(),
  router = useRouter();
async function refresh() {
  try {
    const c = await api("/auth/captcha");
    image.value = c.image;
    environment.value = c.environment;
    form.value.captcha_id = c.id;
    form.value.captcha = "";
  } catch (e) {
    notify(e);
  }
}
onMounted(refresh);
async function login() {
  busy.value = true;
  try {
    yearly.user = await post("/auth/login", form.value);
    setCSRF(yearly.user.csrf_token);
    router.push("/");
  } catch (e) {
    notify(e);
    await refresh();
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <div class="login-page">
    <section class="login-story">
      <div class="brand">
        <span class="brand-symbol"><Leaf /></span
        ><span>yearly<small>YEARLY</small></span>
      </div>
      <div class="login-copy">
        <span class="eyebrow">THE LITTLE DAYS, FOREVER.</span>
        <h1>
          {{ t("日子慢慢过，") }} <br />
          {{ t("成长好好记。") }}
        </h1>
        <p>
          {{ t("从第一次微笑，到每一个平凡的今天。") }} <br />
          {{ t("把一家人的时光，珍藏在一起。") }}
        </p>
        <EmptyState title="" description="" compact />
      </div>
      <span class="story-footer"> {{ t("yearly · 每年都有新故事") }} </span>
    </section>
    <section class="login-form">
      <div class="login-language"><LanguageSwitch /></div>
      <div>
        <span class="eyebrow">WELCOME HOME</span
        ><span
          v-if="environment"
          class="environment-badge login-environment"
          :class="{ testing: environment === 'test' }"
          >{{ environment === "test" ? t("测试环境") : t("正式环境") }}</span
        >
        <h2>{{ t("欢迎回家") }}</h2>
        <p class="muted">{{ t("登录，翻开属于你们的成长故事。") }}</p>
        <form @submit.prevent="login">
          <label>
            {{ t("用户名") }}
            <input
              v-model="form.username"
              autocomplete="username"
              required
              :placeholder="t('输入家庭账户')" /></label
          ><label>
            {{ t("密码") }}
            <input
              v-model="form.password"
              type="password"
              autocomplete="current-password"
              required
              :placeholder="t('输入密码')" /></label
          ><label>
            {{ t("图形验证码") }}
            <div class="captcha-row">
              <input
                v-model="form.captcha"
                required
                maxlength="5"
                autocomplete="off"
                :placeholder="t('输入验证码')"
              /><button
                type="button"
                :title="t('换一张验证码')"
                @click="refresh"
              >
                <img
                  v-if="image"
                  :src="image"
                  :alt="t('图形验证码，点击更换')"
                />
              </button></div></label
          ><button class="button primary login-submit" :disabled="busy">
            {{ busy ? t("正在登录…") : t("进入我的家庭")
            }}<ArrowRight :size="17" />
          </button>
        </form>
        <div class="login-safety">
          <ShieldCheck :size="17" /> {{ t("私人家庭空间，仅受邀成员可见") }}
        </div>
        <p class="login-help">
          {{ t("首次使用请通过服务器管理命令创建管理员。") }} <br />
          {{ t("账户由家庭管理员邀请，公开注册已关闭。") }}
        </p>
      </div>
    </section>
  </div>
</template>
