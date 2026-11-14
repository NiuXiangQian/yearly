// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";
import { createApp, nextTick } from "vue";
import AISearch from "../../components/AISearch.vue";
import { api, post } from "../api";
vi.mock("../api", () => ({ api: vi.fn(), post: vi.fn(), localDate: (v: string) => v }));
vi.mock("../../components/MotionDialog.vue", () => ({default: {template:'<div role="dialog"><slot /></div>'}}));
vi.mock("../../components/MediaDetail.vue", () => ({default: {props:["id"],template:'<div :data-detail="id"></div>'}}));
vi.mock("../../components/MediaCard.vue", () => ({default: {props:["media"],emits:["open"],template:'<button class="test-media" @click="$emit(\'open\')">{{media.title}}</button>'}}));
let app: ReturnType<typeof createApp>;
afterEach(() => { app?.unmount(); document.body.innerHTML = ""; vi.resetAllMocks(); });
async function mount(enabled=true, indexed=3, onLocate = vi.fn()) {
  vi.mocked(api).mockResolvedValue({enabled,indexed,total:5,failed:0});
  const host=document.createElement("div"); document.body.append(host);
  app=createApp(AISearch,{filters:{child_ids:[7],media_type:"video"},onLocate}); app.mount(host);
  await vi.waitFor(()=>expect(host.textContent).toContain(`${indexed} / 5`));
  const input=host.querySelector("input")!;
  input.value="小狗跑步";input.dispatchEvent(new Event("input",{bubbles:true}));await nextTick();
  return {host,input,form:host.querySelector("form")!,button:host.querySelector('button[type="submit"]') as HTMLButtonElement};
}
it("submits explicit scope only once, honors IME composition, and opens a matching item",async()=>{
  const {host,input,form}=await mount();
  vi.mocked(post).mockResolvedValue({search_id:"test",page:1,page_size:20,total:1,items:[{id:42,title:"草地上的小狗",search_description:"小狗在草地奔跑"}],filters:{start:"2025-06-01",end:"2025-08-31"}});
  input.dispatchEvent(new CompositionEvent("compositionstart",{bubbles:true}));
  form.dispatchEvent(new Event("submit",{cancelable:true}));await nextTick();expect(post).not.toHaveBeenCalled();
  input.dispatchEvent(new CompositionEvent("compositionend",{bubbles:true}));
  form.dispatchEvent(new Event("submit",{cancelable:true}));form.dispatchEvent(new Event("submit",{cancelable:true}));
  await vi.waitFor(()=>expect(host.textContent).toContain("草地上的小狗"));
  expect(post).toHaveBeenCalledTimes(1);
  expect(post).toHaveBeenCalledWith("/ai-search",{query:"小狗跑步",child_ids:[7],media_type:"video",request_id:expect.any(String)});
  (host.querySelector('.test-media') as HTMLButtonElement).click();await nextTick();
  expect(host.querySelector('[data-detail="42"]')).not.toBeNull();
  expect(host.textContent).toContain("2025-06-01");
});
it("locates the selected result without replacing its preview action",async()=>{
  const onLocate=vi.fn();
  const {host,form}=await mount(true,3,onLocate);
  const item={id:42,title:"草地上的小狗",timeline_day:"2024-03-31",folder_id:90};
  vi.mocked(post).mockResolvedValue({search_id:"test",page:1,page_size:20,total:1,items:[item]});
  form.dispatchEvent(new Event("submit",{cancelable:true}));
  await vi.waitFor(()=>expect(host.querySelector('.ai-search-locate')).not.toBeNull());
  (host.querySelector('.ai-search-locate') as HTMLButtonElement).click();
  expect(onLocate).toHaveBeenCalledWith(item);
  expect(host.querySelector('[data-detail="42"]')).toBeNull();
});
it("retains input and shows a recoverable failure instead of stale results",async()=>{
  const {host,input,form}=await mount();
  vi.mocked(post).mockRejectedValue(new Error("本月智能搜索预算已用完，下月可继续使用"));
  form.dispatchEvent(new Event("submit",{cancelable:true}));
  await vi.waitFor(()=>expect(host.querySelector('[role="alert"]')?.textContent).toContain("预算已用完"));
  expect(input.value).toBe("小狗跑步");
  expect(host.textContent).not.toContain("0 项相关回忆");
  vi.mocked(post).mockResolvedValue({search_id:"test",page:1,page_size:20,total:0,items:[],filters:null});
  form.dispatchEvent(new Event("submit",{cancelable:true}));
  await vi.waitFor(()=>expect(host.textContent).toContain("没有找到相关影像"));
});
it("does not call the provider while no images have been analyzed",async()=>{
  const {host,button,form}=await mount(true,0);
  expect(button.disabled).toBe(true);expect(host.textContent).toContain("等待后台建立索引");
  form.dispatchEvent(new Event("submit",{cancelable:true}));expect(post).not.toHaveBeenCalled();
});

it("displays server progress while preserving a pending search",async()=>{
  const {host,form}=await mount();
  let finish!: (value: unknown)=>void;
  vi.mocked(post).mockImplementation(()=>new Promise(resolve=>{finish=resolve}));
  vi.mocked(api).mockResolvedValue({stage:"ranking"});
  form.dispatchEvent(new Event("submit",{cancelable:true}));
  await vi.waitFor(()=>expect(host.textContent).toContain("正在核对画面"),{timeout:2000});
  expect(host.textContent).toContain("已等待");
  finish({search_id:"test",page:1,page_size:20,total:0,items:[]});
  await vi.waitFor(()=>expect(host.textContent).toContain("没有找到相关影像"));
});

it("pages through the submitted search, keeps the current page on error, and resets for a new search", async () => {
  const {host, input, form} = await mount();
  const page = (n: number) => ({search_id:"original", page:n, page_size:20, total:41,
    items:Array.from({length:n === 3 ? 1 : 20}, (_, i) => ({id:(n-1)*20+i+1, title:`result-${(n-1)*20+i+1}`}))});
  vi.mocked(post).mockResolvedValue(page(1));
  form.dispatchEvent(new Event("submit"));
  const nav = () => Array.from(host.querySelectorAll<HTMLButtonElement>("nav button"));
  await vi.waitFor(() => expect(nav()[0].disabled).toBe(true));
  input.value = "新的查询"; input.dispatchEvent(new Event("input"));
  vi.mocked(api).mockRejectedValueOnce(new Error("网络错误")).mockResolvedValueOnce(page(2)).mockResolvedValueOnce(page(3)).mockResolvedValueOnce(page(2));
  nav()[1].click();
  await vi.waitFor(() => expect(host.textContent).toContain("网络错误"));
  expect(host.querySelector(".test-media")?.textContent).toBe("result-1");
  nav()[1].click();
  await vi.waitFor(() => expect(host.querySelector(".test-media")?.textContent).toBe("result-21"));
  expect(api).toHaveBeenLastCalledWith("/ai-search/results/original?page=2");
  nav()[1].click();
  await vi.waitFor(() => expect(nav()[1].disabled).toBe(true));
  await vi.waitFor(() => expect(host.querySelector(".test-media")?.textContent).toBe("result-41"));
  expect(host.querySelectorAll(".test-media")).toHaveLength(1);
  nav()[0].click();
  await vi.waitFor(() => expect(host.textContent).toContain("第 2 / 3 页"));
  expect(post).toHaveBeenCalledTimes(1);
  form.dispatchEvent(new Event("submit"));
  await vi.waitFor(() => expect(host.textContent).toContain("第 1 / 3 页"));
  expect(post).toHaveBeenLastCalledWith("/ai-search",expect.objectContaining({query:"新的查询"}));
});
