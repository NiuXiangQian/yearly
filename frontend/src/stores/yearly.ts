import { defineStore } from "pinia";
import { ref, computed } from "vue";
import { api, post, setCSRF } from "../lib/api";
export const useYearly = defineStore("yearly", () => {
  const user = ref<any>(null),
    children = ref<any[]>([]),
    selected = ref<number[]>([]);
  const stats = ref({ media: 0, children: 0, events: 0, bytes: 0 });
  const canEdit = computed(() =>
    ["admin", "member"].includes(user.value?.role),
  );
  const isAdmin = computed(() => user.value?.role === "admin");
  async function session() {
    try {
      user.value = await api("/auth/me");
      setCSRF(user.value.csrf_token);
      return true;
    } catch {
      return false;
    }
  }
  async function load() {
    [children.value, stats.value] = await Promise.all([
      api("/children"),
      api("/stats"),
    ]);
  }
  async function logout() {
    await post("/auth/logout");
    user.value = null;
    setCSRF("");
  }
  return {
    user,
    children,
    selected,
    stats,
    canEdit,
    isAdmin,
    session,
    load,
    logout,
  };
});
