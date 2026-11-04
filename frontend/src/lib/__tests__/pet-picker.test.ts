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

it("finds family relationships and selects a pet category without losing file associations", async () => {
  const pinia = createPinia();
  setActivePinia(pinia);
  useYearly().children = [
    { id: 1, name: "林先生", profile_type: "person", relationship: "爸爸" },
    { id: 2, name: "团子", profile_type: "pet", species: "猫" },
    { id: 3, name: "豆豆", profile_type: "pet", species: "狗" },
    { id: 4, name: "花花", profile_type: "pet", species: "猫" },
  ];
  const selected = ref<number[]>([1]);
  const host = document.createElement("div");
  const app = createApp({
    render: () =>
      h(ChildPicker, {
        modelValue: selected.value,
        "onUpdate:modelValue": (v: number[]) => {
          selected.value = v;
        },
      }),
  }).use(pinia);
  app.mount(host);
  try {
    const search = host.querySelector("input")!;
    search.value = "爸爸";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    await nextTick();
    expect(host.querySelectorAll(".child-pill")).toHaveLength(1);
    expect(host.querySelector(".child-pill")!.textContent).toContain("林先生");
    search.value = "";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    const category = host.querySelector("select")!;
    category.value = "species:猫";
    category.dispatchEvent(new Event("change", { bubbles: true }));
    await nextTick();
    expect(host.querySelectorAll(".child-pill")).toHaveLength(2);
    const select = [...host.querySelectorAll("button")].find((b) =>
      b.textContent?.includes("选中这些档案"),
    )!;
    select.click();
    await nextTick();
    expect(selected.value).toEqual([1, 2, 4]);
    expect(host.textContent).toContain("已选 3 个档案");
    search.value = "不存在";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    await nextTick();
    expect(select.disabled).toBe(true);
    expect(selected.value).toEqual([1, 2, 4]);
  } finally {
    app.unmount();
  }
});
