// @vitest-environment happy-dom
import { expect, it } from "vitest";
import { createApp, h, nextTick, ref } from "vue";
import { createPinia, setActivePinia } from "pinia";
import ChildPicker from "../../components/ChildPicker.vue";
import { useYearly } from "../../stores/yearly";

it("keeps children and pets selected together and can unlink only the pet", async () => {
  const pinia = createPinia();
  setActivePinia(pinia);
  useYearly().children = [
    { id: 1, name: "小禾", profile_type: "child" },
    { id: 2, name: "团子", profile_type: "pet" },
  ];
  const selected = ref<number[]>([]);
  const host = document.createElement("div");
  const app = createApp({
    render: () =>
      h(ChildPicker, {
        modelValue: selected.value,
        "onUpdate:modelValue": (value: number[]) => {
          selected.value = value;
        },
        all: true,
      }),
  }).use(pinia);
  app.mount(host);
  try {
    const buttons = host.querySelectorAll("button");
    expect(buttons[2].textContent).toContain("宠物");
    buttons[1].click();
    await nextTick();
    buttons[2].click();
    await nextTick();
    expect(selected.value).toEqual([1, 2]);
    expect(host.querySelectorAll(".selected")).toHaveLength(2);
    buttons[2].click();
    await nextTick();
    expect(selected.value).toEqual([1]);
    buttons[0].click();
    await nextTick();
    expect(selected.value).toEqual([]);
  } finally {
    app.unmount();
  }
});
