<script setup lang="ts">
import LanguageSwitch from "../components/LanguageSwitch.vue";
import { t } from "../lib/i18n";
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import { Leaf, ShieldCheck, ArrowRight } from "lucide-vue-next";
import { api, post, setCSRF } from "../lib/api";
import { useYearly } from "../stores/yearly";
const albumCover = `${import.meta.env.BASE_URL}family-album-cover.webp`;
const form = ref({ username: "", password: "", captcha: "", captcha_id: "" }),
  image = ref(""),
  environment = ref(""),
  error = ref(""),
  captchaError = ref(""),
  refreshing = ref(false),
  busy = ref(false);
const yearly = useYearly(),
  router = useRouter();
async function refresh() {
  if (refreshing.value) return;
  refreshing.value = true;
  captchaError.value = "";
  image.value = "";
  form.value.captcha_id = "";
  form.value.captcha = "";
  try {
    const c = await api("/auth/captcha");
    image.value = c.image;
    environment.value = c.environment;
    form.value.captcha_id = c.id;
  } catch (e) {
    captchaError.value = e instanceof Error ? e.message : t("加载失败");
  } finally {
    refreshing.value = false;
  }
}
onMounted(refresh);
async function login() {
  if (busy.value || refreshing.value || !form.value.captcha_id) return;
  error.value = "";
  busy.value = true;
  try {
    yearly.user = await post("/auth/login", form.value);
    setCSRF(yearly.user.csrf_token);
    router.push("/");
  } catch (e) {
    error.value = e instanceof Error ? e.message : t("操作失败");
    await refresh();
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <div class="login-page">
    <div class="login-stage">
      <LanguageSwitch />
    </div>
    <section class="login-story">
      <div class="brand">
        <span class="brand-symbol"><Leaf /></span
        ><span>yearly</span>
      </div>
      <div class="login-copy">
        <p class="login-headline">
          {{ t("日子慢慢过，") }} <br />
          {{ t("成长好好记。") }}
        </p>
        <p>
          {{ t("从第一次微笑，到每一个平凡的今天。") }} <br />
          {{ t("把一家人的时光，珍藏在一起。") }}
        </p>
      </div>
      <img class="login-cover" :src="albumCover" alt="" width="1400" height="1050" />
    </section>
    <section class="login-form">
      <div>
        <span
          v-if="environment"
          class="environment-badge login-environment"
          :class="{ testing: environment === 'test' }"
          >{{ environment === "test" ? t("测试环境") : t("正式环境") }}</span
        >
        <h1>{{ t("欢迎回家") }}</h1>
        <p class="muted">{{ t("登录，翻开属于你们的成长故事。") }}</p>
        <form @submit.prevent="login" @keydown.enter="$event.isComposing && $event.preventDefault()">
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
          ><div class="login-captcha">
            <label for="login-captcha">{{ t("图形验证码") }}</label>
            <div class="captcha-row">
              <input
                id="login-captcha"
                v-model="form.captcha"
                :disabled="busy || refreshing"
                :aria-describedby="captchaError ? 'login-captcha-error' : undefined"
                required
                maxlength="5"
                autocomplete="off"
                :placeholder="t('输入验证码')"
              /><button
                type="button"
                :title="t('换一张验证码')"
                :aria-label="t('换一张验证码')"
                :disabled="busy || refreshing"
                @click="refresh"
              >
                <img
                  v-if="image"
                  :src="image"
                  :alt="t('图形验证码，点击更换')"
                />
                <span v-else>{{ refreshing ? t("正在加载…") : t("重试") }}</span>
              </button>
            </div>
            <p v-if="captchaError" id="login-captcha-error" class="notice" role="alert">{{ captchaError }}</p>
          </div>
          <p v-if="error" class="notice" role="alert">{{ error }}</p>
          <button type="submit" class="button primary login-submit" :disabled="busy || refreshing || !form.captcha_id">
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
