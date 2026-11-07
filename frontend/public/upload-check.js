const status = document.querySelector("#status");
const detail = document.querySelector("#detail");
const readButton = document.querySelector("#read");
const log = document.querySelector("#log");
const inputs = [...document.querySelectorAll('input[type="file"]')];
const started = performance.now();
let selected = [];
let active = "";

function record(message) {
  log.value += `${((performance.now() - started) / 1000).toFixed(1)}s ${message}\n`;
  log.scrollTop = log.scrollHeight;
}

record(`版本 20261107-1 · ${navigator.userAgent}`);
for (const input of inputs) {
  input.addEventListener("click", () => {
    input.value = "";
    active = input.dataset.name;
    selected = [];
    readButton.disabled = true;
    status.textContent = "尚未收到系统交付的文件";
    detail.textContent = "选取窗口里的下载或转换过程由系统处理，此页无法获取其进度。";
    record(`${active}：打开选取入口`);
  });
  input.addEventListener("change", () => {
    selected = [...input.files];
    const size = selected.reduce((sum, file) => sum + file.size, 0);
    readButton.disabled = selected.length === 0;
    status.textContent = selected.length ? `已收到 ${selected.length} 个文件` : "系统返回了空的文件列表";
    detail.textContent = selected.length
      ? `共 ${(size / 1024 / 1024).toFixed(2)} MB。相册已完成交付，可继续检查读取。`
      : "尚未进入网页的照片处理流程。";
    record(`${active}：change，${selected.length} 个文件，${size} 字节`);
  });
  input.addEventListener("cancel", () => {
    status.textContent = "系统未交付文件";
    detail.textContent = "如果你主动返回，这是正常取消；如果点的是完成，则系统没有完成文件交付。";
    record(`${active}：cancel，未交付文件`);
  });
}

readButton.addEventListener("click", async () => {
  readButton.disabled = true;
  inputs.forEach((input) => { input.disabled = true; });
  status.textContent = "正在检查文件读取…";
  detail.textContent = "每个文件只读取开头最多 64 KB，不解析、不转换，也不上传。";
  record(`开始读取 ${selected.length} 个文件`);
  const waiting = setTimeout(() => {
    status.textContent = "文件已交付，但读取仍未返回";
    detail.textContent = "已等待 10 秒。可把此结果反馈给维护者，刷新页面后可重新检查。";
    record("读取等待超过 10 秒");
  }, 10000);
  try {
    for (let index = 0; index < selected.length; index++) {
      const file = selected[index];
      const data = await file.slice(0, 65536).arrayBuffer();
      record(`第 ${index + 1} 个文件：读取 ${data.byteLength} 字节，类型 ${file.type || "未提供"}`);
    }
    status.textContent = `文件读取正常（${selected.length} 个）`;
    detail.textContent = "系统选取和基础读取都已完成。若上传页仍卡住，应继续检查网页的照片处理流程。";
  } catch (error) {
    status.textContent = "已收到文件，但读取失败";
    detail.textContent = "系统已交付文件信息，但没有成功读出内容。";
    record(`读取错误：${error.name}`);
  } finally {
    clearTimeout(waiting);
    inputs.forEach((input) => { input.disabled = false; });
    readButton.disabled = false;
  }
});

window.addEventListener("blur", () => record("页面失去焦点"));
window.addEventListener("focus", () => record("页面获得焦点"));
document.addEventListener("visibilitychange", () => record(`页面可见性：${document.visibilityState}`));
