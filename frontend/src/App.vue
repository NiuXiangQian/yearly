<script setup lang="ts">
import { computed, onMounted, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import {
  Images,
  BookHeart,
  Baby,
  Upload,
  Settings,
  ShieldCheck,
  Leaf,
  ArrowUpRight,
  Archive,
  LogOut,
  Sun,
  Moon,
  Heart,
} from "lucide-vue-next";
import { useYearly } from "./stores/yearly";
import { notify, bytes } from "./lib/api";
const route = useRoute(),
  router = useRouter(),
  yearly = useYearly();
const nav = [
  { path: "/", label: "成长时间线", icon: Images },
  { path: "/events", label: "成长日记", icon: BookHeart },
  { path: "/children", label: "孩子档案", icon: Baby },
];
const titles: Record<string, string> = {
  "/": "成长时间线",
  "/events": "成长日记",
  "/children": "孩子档案",
  "/upload": "珍藏新回忆",
  "/settings": "我的家庭",
  "/backup": "备份与导出",
  "/trash": "回收站",
};
const title = computed(() => titles[route.path] || "yearly");
watch(
  () => yearly.user,
  (user) => {
    if (user) yearly.load().catch(notify);
  },
  { immediate: true },
);
onMounted(() => {
  document.documentElement.dataset.theme =
    localStorage.getItem("yearly-theme") || "light";
});
function theme() {
  const next =
    document.documentElement.dataset.theme === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  localStorage.setItem("yearly-theme", next);
}
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
  <RouterView v-if="route.path === '/login'" />
  <div v-else class="shell">
    <aside class="sidebar">
      <RouterLink to="/" class="brand"
        ><span class="brand-symbol"><Leaf :size="23" /></span
        ><span>yearly<small>YEARLY</small></span></RouterLink
      >
      <div class="yearly-label">
        <span class="tiny-dot"></span> 我们的家庭影像档案
      </div>
      <div class="nav-caption">一起长大的日子</div>
      <nav>
        <RouterLink
          v-for="item in nav"
          :key="item.path"
          :to="item.path"
          :class="{ active: route.path === item.path }"
          ><component :is="item.icon" :size="19" /><span>{{ item.label }}</span
          ><span v-if="item.path === '/events'" class="nav-count">{{
            yearly.stats.events
          }}</span></RouterLink
        >
      </nav>
      <RouterLink v-if="yearly.canEdit" to="/upload" class="sidebar-upload"
        ><Upload :size="18" /> 上传照片与视频 <ArrowUpRight :size="15"
      /></RouterLink>
      <div class="sidebar-bottom">
        <div class="safekeep">
          <ShieldCheck :size="20" />
          <div>只属于我们的回忆<small>私密空间 · 原件珍藏</small></div>
          <Heart class="faint" :size="28" />
        </div>
        <nav>
          <RouterLink to="/backup"><Archive :size="18" />备份与导出</RouterLink
          ><RouterLink to="/settings"
            ><Settings :size="18" />家庭与设置</RouterLink
          >
        </nav>
        <div class="storage-line">
          <span>已珍藏 {{ bytes(yearly.stats.bytes) }}</span
          ><span>{{ yearly.stats.media }} 份回忆</span>
        </div>
        <button class="profile" @click="router.push('/settings')">
          <span class="avatar">{{
            yearly.user?.username?.slice(0, 1).toUpperCase()
          }}</span
          ><span
            >{{ yearly.user?.username
            }}<small>{{
              yearly.isAdmin
                ? "家庭管理员"
                : yearly.canEdit
                  ? "家庭成员"
                  : "只读访客"
            }}</small></span
          ><Settings :size="16" />
        </button>
      </div>
    </aside>
    <div class="workspace">
      <header class="topbar">
        <div>
          <span class="breadcrumb">我的家庭</span><span class="divider">/</span
          >{{ title }}
        </div>
        <div class="header-actions">
          <span
            v-if="yearly.user?.environment"
            class="environment-badge"
            :class="{ testing: yearly.user?.environment === 'test' }"
            >{{
              yearly.user?.environment === "test" ? "测试环境" : "正式环境"
            }}</span
          >
          <span class="private-label"
            ><ShieldCheck :size="14" /> 家庭私密可见</span
          ><button class="icon-button" aria-label="切换深浅主题" @click="theme">
            <Sun :size="18" /></button
          ><button class="icon-button" aria-label="退出登录" @click="logout">
            <LogOut :size="17" />
          </button>
        </div>
      </header>
      <main><RouterView /></main>
      <footer class="page-footer">
        <Leaf :size="13" /> yearly · 记录每一年的成长<span
          >每一份原件，都值得好好保存</span
        >
      </footer>
    </div>
    <nav class="mobile-nav">
      <RouterLink to="/"><Images :size="21" />时间线</RouterLink
      ><RouterLink to="/events"><BookHeart :size="21" />日记</RouterLink
      ><RouterLink v-if="yearly.canEdit" to="/upload"
        ><Upload :size="21" />上传</RouterLink
      ><RouterLink to="/settings"><Settings :size="21" />我的</RouterLink>
    </nav>
  </div>
</template>
