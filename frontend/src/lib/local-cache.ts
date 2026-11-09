import { sha256 } from "hash-wasm";

const prefix = `yearly-cache-v1:${import.meta.env.BASE_URL}:`;
const listLifetime = 5 * 60_000;
const imageLifetime = 7 * 24 * 60 * 60_000;
let account: number | null = null;
let revision = 0;
const shareExpiry = new Map<string, number>();

export function setCacheAccount(id: number | null) { account = id; }
export function cacheRevision() { return revision; }
export function cacheScope(path: string) {
  const share = path.match(/^\/public\/shares\/[^/?]+/);
  return share ? share[0] : account === null ? null : `account:${account}`;
}
export function rememberShare(path: string, expires: string) {
  const scope = cacheScope(path);
  if (scope) shareExpiry.set(scope, new Date(expires).getTime());
}
async function storageKey(scope: string, path: string) {
  return prefix + await sha256(scope) + ":" + await sha256(path);
}
export async function readCachedJSON(scope: string, path: string) {
  try {
    const key = await storageKey(scope, path);
    const raw = localStorage.getItem(key);
    if (!raw) return undefined;
    const entry = JSON.parse(raw);
    if (entry.expires <= Date.now()) { localStorage.removeItem(key); return undefined; }
    return entry.value;
  } catch { return undefined; } // Storage can be disabled or evicted by the browser.
}
export async function writeCachedJSON(scope: string, path: string, value: any) {
  try {
    const expires = Math.min(Date.now() + listLifetime, shareExpiry.get(scope) ?? Infinity);
    const key = await storageKey(scope, path);
    const raw = JSON.stringify({ expires, value });
    if (raw.length > 512_000) return;
    const entries = Object.keys(localStorage).filter((key) => key.startsWith(prefix));
    let size = raw.length;
    for (const stored of entries) size += localStorage.getItem(stored)?.length ?? 0;
    // Keep metadata within approximately 4 MiB, limiting the number of saved pages.
    while (entries.length && (size > 2_000_000 || entries.length >= 200)) {
      const oldest = entries.shift()!;
      size -= localStorage.getItem(oldest)?.length ?? 0;
      localStorage.removeItem(oldest);
    }
    localStorage.setItem(key, raw);
  } catch { /* A full or unavailable cache must not interrupt browsing. */ }
}
export function invalidateCachedLists() {
  revision++;
  try {
    for (const key of Object.keys(localStorage))
      if (key.startsWith(prefix)) localStorage.removeItem(key);
  } catch { /* Browsing also works with storage disabled. */ }
}

let database: Promise<IDBDatabase | undefined> | undefined;
function imageDatabase() {
  database ??= new Promise((resolve) => {
    if (typeof indexedDB === "undefined") { resolve(undefined); return; }
    const request = indexedDB.open("yearly-images-v1", 1);
    request.onupgradeneeded = () => {
      const store = request.result.createObjectStore("images", { keyPath: "key" });
      store.createIndex("scope", "scope");
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => resolve(undefined);
    request.onblocked = () => resolve(undefined);
  });
  return database;
}
function result<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}
export async function cachedImage(scope: string, path: string) {
  try {
    const db = await imageDatabase();
    if (!db) return undefined;
    const key = await storageKey(scope, path);
    const entry = await result(db.transaction("images").objectStore("images").get(key));
    if (entry?.expires > Date.now()) return entry.blob as Blob;
  } catch { /* A cache miss falls back to the authorized image request. */ }
  return undefined;
}
export async function saveCachedImage(scope: string, path: string, blob: Blob) {
  if (!blob.type.startsWith("image/") || blob.size > 20 * 1024 * 1024) return;
  try {
    const db = await imageDatabase();
    if (!db) return;
    const key = await storageKey(scope, path);
    const hashedScope = await sha256(prefix + scope);
    const expires = Math.min(Date.now() + imageLifetime, shareExpiry.get(scope) ?? Infinity);
    const entries = await result(db.transaction("images").objectStore("images").getAll());
    const transaction = db.transaction("images", "readwrite");
    const store = transaction.objectStore("images");
    let size = blob.size + entries.reduce((sum, entry) => sum + entry.blob.size, 0);
    let count = entries.length;
    for (const entry of entries.sort((a, b) => a.created - b.created)) {
      if (entry.expires <= Date.now() || size > 128 * 1024 * 1024 || count >= 500) {
        store.delete(entry.key);
        size -= entry.blob.size;
        count--;
      }
    }
    store.put({ key, scope: hashedScope, blob, expires, created: Date.now() });
    await new Promise<void>((resolve, reject) => {
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
  } catch { /* Quota and private-browsing restrictions only disable caching. */ }
}
export async function clearCachedScope(scope: string) {
  revision++;
  try {
    const hashedScope = await sha256(scope);
    for (const key of Object.keys(localStorage))
      if (key.startsWith(prefix + hashedScope + ":")) localStorage.removeItem(key);
    const db = await imageDatabase();
    if (!db) return;
    const imageScope = await sha256(prefix + scope);
    const keys = await result(db.transaction("images").objectStore("images").index("scope").getAllKeys(imageScope));
    const store = db.transaction("images", "readwrite").objectStore("images");
    for (const key of keys) store.delete(key);
  } catch { /* Cache cleanup is best effort when browser storage is unavailable. */ }
}
