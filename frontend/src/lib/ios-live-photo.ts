type Resource = { name: string; type: string; size: number };
type Selection = { id: string; original: Resource; video: Resource };

export function iosLivePhotoBridge() {
  const { webkit } = window as Window & {
    webkit?: {
      messageHandlers?: {
        yearlyLivePhoto?: { postMessage: (message: object) => Promise<unknown> };
      };
    };
  };
  return webkit?.messageHandlers?.yearlyLivePhoto;
}

export async function pickIOSLivePhoto(signal: AbortSignal) {
  const bridge = iosLivePhotoBridge();
  if (!bridge) return null;
  const selection = (await bridge.postMessage({ action: "pick" })) as
    | Selection
    | { error: string }
    | null;
  if (!selection) return null;
  if ("error" in selection) throw new Error(selection.error);
  const { id } = selection;
  const read = async (role: "original" | "video") => {
    const resource = selection[role];
    const chunks: Uint8Array<ArrayBuffer>[] = [];
    let offset = 0;
    while (offset < resource.size) {
      signal.throwIfAborted();
      const encoded = (await bridge.postMessage({ action: "read", id, role, offset })) as string;
      const chunk = Uint8Array.from(atob(encoded), (byte) => byte.charCodeAt(0));
      if (!chunk.length || chunk.length > resource.size - offset)
        throw new Error("Incomplete Live Photo resource");
      chunks.push(chunk);
      offset += chunk.length;
    }
    // PhotoKit supplies the file bytes. The export's modification date is synthetic.
    return new File(chunks, resource.name, { type: resource.type, lastModified: 0 });
  };
  try {
    return { original: await read("original"), video: await read("video") };
  } finally {
    await bridge.postMessage({ action: "release", id }).catch(() => {});
  }
}
