import { createApp } from "vue";
import { createPinia } from "pinia";
import { createRouter, createWebHistory } from "vue-router";
import App from "./App.vue";
import { useYearly } from "./stores/yearly";
import "element-plus/es/components/date-picker/style/css";
import "./style.css";
import { setLocale } from "./lib/i18n";
setLocale(localStorage.getItem("yearly-language") === "en" ? "en" : "zh-CN");
const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    {
      path: "/share/:token",
      component: () => import("./views/SharedTimeline.vue"),
      meta: { public: true },
    },
    { path: "/login", component: () => import("./views/Login.vue") },
    { path: "/", component: () => import("./views/Timeline.vue") },
    { path: "/children", component: () => import("./views/Children.vue") },
    { path: "/upload", component: () => import("./views/Upload.vue") },
    { path: "/events", component: () => import("./views/Events.vue") },
    { path: "/settings", component: () => import("./views/Settings.vue") },
    { path: "/backup", component: () => import("./views/Backup.vue") },
    {
      path: "/trash",
      component: () => import("./views/Timeline.vue"),
      meta: { trash: true },
    },
    { path: "/:pathMatch(.*)*", redirect: "/" },
  ],
});
const app = createApp(App).use(createPinia());
router.beforeEach(async (to) => {
  if (to.meta.public) return;
  const yearly = useYearly();
  if (!yearly.user && !(await yearly.session()) && to.path !== "/login")
    return "/login";
  if (yearly.user && to.path === "/login") return "/";
});
app.use(router).mount("#app");
