import { it, expect } from "vitest";
import { createSSRApp } from "vue";
import { renderToString } from "@vue/server-renderer";
import { createPinia, setActivePinia } from "pinia";
import ChildPicker from "../../components/ChildPicker.vue";
import { useYearly } from "../../stores/yearly";
it("child selection never submits its enclosing edit form", async () => {
  const pinia = createPinia();
  setActivePinia(pinia);
  useYearly().children = [
    { id: 1, name: "哥哥", nickname: "哥哥", theme_color: "#667b5b" },
  ];
  const app = createSSRApp(ChildPicker, { modelValue: [], all: true }).use(
    pinia,
  );
  const html = await renderToString(app);
  const buttons = html.match(/<button\b[^>]*>/g) || [];
  expect(buttons).toHaveLength(2);
  expect(buttons.every((button) => button.includes('type="button"'))).toBe(
    true,
  );
});
