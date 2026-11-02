// IndexedDB storage for offline-first: downloaded audio blobs, local files,
// and an outbox of writes made while offline (play history, podcast progress).

const DB_NAME = "lipina";
const VERSION = 1;
let dbp;

function open() {
  dbp ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      db.createObjectStore("downloads", { keyPath: "key" }); // {key, item, blob, size, savedAt}
      db.createObjectStore("local", { keyPath: "key" }); // {key, item, blob}
      db.createObjectStore("outbox", { keyPath: "id" }); // {id, path, body}
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbp;
}

async function tx(store, mode, fn) {
  const db = await open();
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode);
    const s = t.objectStore(store);
    let result;
    Promise.resolve(fn(s)).then((r) => { result = r; });
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error || new Error("Transaction aborted (storage full?)"));
  });
}

const wrap = (req) => new Promise((res, rej) => { req.onsuccess = () => res(req.result); req.onerror = () => rej(req.error); });

export const db = {
  put: (store, value) => tx(store, "readwrite", (s) => wrap(s.put(value))),
  get: (store, key) => tx(store, "readonly", (s) => wrap(s.get(key))),
  del: (store, key) => tx(store, "readwrite", (s) => wrap(s.delete(key))),
  all: (store) => tx(store, "readonly", (s) => wrap(s.getAll())),
  keys: (store) => tx(store, "readonly", (s) => wrap(s.getAllKeys())),
  clear: (store) => tx(store, "readwrite", (s) => wrap(s.clear())),
};

/** Ask the browser not to evict our downloads under storage pressure. */
export async function requestPersistence() {
  try {
    if (navigator.storage?.persist && !(await navigator.storage.persisted())) await navigator.storage.persist();
  } catch { /* best effort */ }
}

export async function storageEstimate() {
  try { return await navigator.storage.estimate(); } catch { return null; }
}
