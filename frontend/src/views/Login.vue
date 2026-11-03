<script setup lang="ts">
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
        <h1>日子慢慢过，<br />成长好好记。</h1>
        <p>
          从第一次微笑，到每一个平凡的今天。<br />把一家人的时光，珍藏在一起。
        </p>
        <EmptyState title="" description="" compact />
      </div>
      <span class="story-footer">yearly · 每年都有新故事</span>
    </section>
    <section class="login-form">
      <div>
        <span class="eyebrow">WELCOME HOME</span
        ><span
          v-if="environment"
          class="environment-badge login-environment"
          :class="{ testing: environment === 'test' }"
          >{{ environment === "test" ? "测试环境" : "正式环境" }}</span
        >
        <h2>欢迎回家</h2>
        <p class="muted">登录，翻开属于你们的成长故事。</p>
        <form @submit.prevent="login">
          <label
            >用户名<input
              v-model="form.username"
              autocomplete="username"
              required
              placeholder="输入家庭账户" /></label
          ><label
            >密码<input
              v-model="form.password"
              type="password"
              autocomplete="current-password"
              required
              placeholder="输入密码" /></label
          ><label
            >图形验证码
            <div class="captcha-row">
              <input
                v-model="form.captcha"
                required
                maxlength="5"
                autocomplete="off"
                placeholder="输入验证码"
              /><button type="button" title="换一张验证码" @click="refresh">
                <img v-if="image" :src="image" alt="图形验证码，点击更换" />
              </button></div></label
          ><button class="button primary login-submit" :disabled="busy">
            {{ busy ? "正在登录…" : "进入我的家庭" }}<ArrowRight :size="17" />
          </button>
        </form>
        <div class="login-safety">
          <ShieldCheck :size="17" />私人家庭空间，仅受邀成员可见
        </div>
        <p class="login-help">
          首次使用请通过服务器管理命令创建管理员。<br />账户由家庭管理员邀请，公开注册已关闭。
        </p>
      </div>
    </section>
  </div>
</template>
