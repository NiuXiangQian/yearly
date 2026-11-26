<script setup lang="ts">
import { t, elementLocale } from "./lib/i18n";
import MotionNav from "./components/MotionNav.vue";
import LanguageSwitch from "./components/LanguageSwitch.vue";
import { ElConfigProvider } from "element-plus";
import { computed, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import {
  Images,
  BookHeart,
  Users,
  Upload,
  Settings,
  Leaf,
  Archive,
  History,
  LogOut,
  Sun,
  Moon,
  ScanFace,
} from "lucide-vue-next";
import { useYearly } from "./stores/yearly";
import { notify, bytes } from "./lib/api";
import { accountName } from "./lib/accounts";
const route = useRoute(),
  router = useRouter(),
  yearly = useYearly();
const nav = computed(() => [
  { path: "/", label: t("成长时间线"), icon: Images },
  { path: "/events", label: t("成长日记"), icon: BookHeart },
  { path: "/children", label: t("人物与宠物"), icon: Users },
  ...(yearly.isAdmin ? [{ path: "/face-review", label: t("相册整理"), icon: ScanFace }] : []),
]);
const titles = computed<Record<string, string>>(() => ({
  "/": t("成长时间线"),
  "/events": t("成长日记"),
  "/children": t("人物与宠物"),
  "/upload": t("珍藏新回忆"),
  "/settings": t("我的家庭"),
  "/accounts": t("账户管理"),
  "/activity": t("修改日志"),
  "/backup": t("备份与导出"),
  "/trash": t("回收站"),
  "/face-review": t("相册整理"),
}));
const mobileItems = computed(() => [
  { path: "/", label: t("时间线"), icon: Images },
  { path: "/events", label: t("日记"), icon: BookHeart },
  ...(yearly.canEdit ? [{ path: "/upload", label: t("上传"), icon: Upload }] : []),
  { path: "/children", label: t("家人"), icon: Users },
  { path: "/settings", label: t("我的"), icon: Settings },
]);
const title = computed(() => titles.value[route.path] || "yearly");
const theme = ref(localStorage.getItem("yearly-theme") === "dark" ? "dark" : "light");
watch(theme, (value) => {
  document.documentElement.dataset.theme = value;
  localStorage.setItem("yearly-theme", value);
}, { immediate: true });
watch(
  () => yearly.user,
  (user) => {
    if (user && !route.meta.public) yearly.load().catch(notify);
  },
  { immediate: true },
);
async function logout() {
  try {
    await yearly.logout();
    router.push("/login");
  } catch (e) {
    notify(e);
  }
}
</script>
<template>
  <ElConfigProvider :locale="elementLocale">
    <RouterView v-if="route.path === '/login' || route.meta.public" />
    <div v-else class="shell">
      <a href="#yearly-main" class="skip-link">{{ t("跳到主要内容") }}</a>
      <aside class="sidebar">
        <RouterLink to="/" class="brand"
          ><span class="brand-symbol"><Leaf :size="23" /></span
          ><span>yearly</span></RouterLink
        >
        <nav :aria-label="t('我们的家庭影像档案')">
          <RouterLink
            v-for="item in nav"
            :key="item.path"
            :to="item.path"
            ><component :is="item.icon" :size="19" /><span>{{
              item.label
            }}</span
            ><span v-if="item.path === '/events'" class="nav-count">{{
              yearly.stats.events
            }}</span></RouterLink
          >
        </nav>
        <RouterLink v-if="yearly.canEdit" to="/upload" class="button primary sidebar-upload"
          ><Upload :size="18" /> {{ t("上传照片与视频") }}
        </RouterLink>
        <nav class="management-nav" :aria-label="t('家庭与设置')">
          <RouterLink v-if="yearly.isAdmin" to="/accounts"><Users :size="18" />{{ t("账户管理") }}</RouterLink>
          <RouterLink to="/activity"><History :size="18" />{{ t("修改日志") }}</RouterLink>
          <RouterLink v-if="yearly.isAdmin" to="/backup"><Archive :size="18" />{{ t("备份与导出") }}</RouterLink>
          <RouterLink to="/settings"><Settings :size="18" />{{ t("家庭与设置") }}</RouterLink>
        </nav>
        <div class="sidebar-bottom">
          <div class="storage-line">
            <span> {{ t("已珍藏") }} {{ bytes(yearly.stats.bytes) }}</span
            ><span>{{ yearly.stats.media }} {{ t("份回忆") }} </span>
          </div>
          <RouterLink class="profile" to="/settings">
            <span class="avatar">{{
              accountName(yearly.user).slice(0, 1).toUpperCase()
            }}</span
            ><span
              >{{ accountName(yearly.user)
              }}<small>{{
                yearly.isAdmin
                  ? t("家庭管理员")
                  : yearly.canEdit
                    ? t("普通账户")
                    : t("只读访客")
              }}</small></span
            ><Settings :size="16" />
          </RouterLink>
        </div>
      </aside>
      <div class="workspace">
        <header class="topbar">
          <div class="topbar-context">
            <RouterLink to="/" class="mobile-brand" aria-label="yearly"><Leaf :size="19" /></RouterLink>
            <span>{{ title }}</span>
          </div>
          <div class="header-actions">
            <LanguageSwitch />
            <span
              v-if="yearly.user?.environment"
              class="environment-badge"
              :class="{ testing: yearly.user?.environment === 'test' }"
              >{{
                yearly.user?.environment === "test"
                  ? t("测试环境")
                  : t("正式环境")
              }}</span
            >
            <button
              class="icon-button"
              :aria-label="t('切换深浅主题')"
              :aria-pressed="theme === 'dark'"
              @click="theme = theme === 'dark' ? 'light' : 'dark'"
            >
              <Sun v-if="theme === 'dark'" :size="18" /><Moon v-else :size="18" /></button
            ><button
              class="icon-button"
              :aria-label="t('退出登录')"
              @click="logout"
            >
              <LogOut :size="17" />
            </button>
          </div>
        </header>
        <main id="yearly-main" tabindex="-1"><RouterView /></main>
        <footer class="page-footer">
          <Leaf :size="13" /> yearly
        </footer>
      </div>
      <MotionNav :items="mobileItems" />
    </div>
  </ElConfigProvider>
</template>
