import { t } from "./i18n";
import { api, post } from "./api";
import type { Inspected } from "./metadata";
export async function directUpload(
  task: any,
  item: Inspected,
  progress: (n: number) => void,
) {
  if (item.hash.sha256 !== task.sha256 || item.file.size !== task.file_size)
    throw new Error(t("恢复任务必须选择 SHA-256 和大小一致的原文件"));
  const status = await api(`/uploads/${task.id}`);
  if (status.status === "complete") {
    progress(100);
    return;
  }
  const uploaded = new Set<number>(status.parts.map((p: any) => p.number));
  const count = Math.ceil(item.file.size / task.part_size);
  let completed = status.parts.reduce((sum: number, p: any) => sum + p.size, 0);
  for (let number = 1; number <= count; number++) {
    if (uploaded.has(number)) continue;
    const block = item.file.slice(
      (number - 1) * task.part_size,
      Math.min(number * task.part_size, item.file.size),
    );
    let succeeded = false;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const { url } = await post(`/uploads/${task.id}/sign?number=${number}`);
        await new Promise<void>((resolve, reject) => {
          const xhr = new XMLHttpRequest();
          xhr.open("PUT", url);
          xhr.timeout = 180000;
          xhr.upload.onprogress = (e) => {
            if (e.lengthComputable)
              progress(
                Math.round(((completed + e.loaded) / item.file.size) * 100),
              );
          };
          xhr.onload = () =>
            xhr.status >= 200 && xhr.status < 300
              ? resolve()
              : reject(
                  new Error(t("OSS 分片上传失败 ({p0})", { p0: xhr.status })),
                );
          xhr.onerror = () =>
            reject(new Error(t("OSS 网络请求失败，请检查 CORS 或网络")));
          xhr.ontimeout = () => reject(new Error(t("分片上传超时")));
          xhr.send(block);
        });
        succeeded = true;
        break;
      } catch (error) {
        if (attempt === 2) throw error;
        await new Promise((resolve) =>
          setTimeout(resolve, 1000 * 2 ** attempt),
        );
      }
    }
    if (!succeeded) throw new Error(t("分片重试失败"));
    completed += block.size;
    progress(Math.round((completed / item.file.size) * 100));
  }
  await post(`/uploads/${task.id}/complete`);
  progress(100);
}
