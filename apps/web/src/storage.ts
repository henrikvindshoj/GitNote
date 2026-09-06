import type { Workspace } from "./model";
const DB_NAME = "gitnote-web";
const STORE = "workspaces";
function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () =>
      request.result.createObjectStore(STORE, { keyPath: "id" });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () =>
      reject(new Error("Close other GitNote tabs to update local storage."));
  });
}
async function transaction<T>(
  mode: IDBTransactionMode,
  operation: (store: IDBObjectStore) => IDBRequest<T>,
): Promise<T> {
  const db = await open();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, mode);
    let request: IDBRequest<T>;
    try {
      request = operation(tx.objectStore(STORE));
    } catch (error) {
      db.close();
      reject(error);
      return;
    }
    tx.oncomplete = () => {
      db.close();
      resolve(request.result);
    };
    tx.onabort = tx.onerror = () => {
      db.close();
      reject(tx.error ?? new Error("Could not save notes in this browser."));
    };
  });
}
export const loadWorkspaces = () =>
  transaction<Workspace[]>("readonly", (store) => store.getAll());
export const saveWorkspace = (workspace: Workspace) =>
  transaction("readwrite", (store) => store.put(workspace));
export const removeWorkspace = (id: string) =>
  transaction("readwrite", (store) => store.delete(id));
