/**
 * Local-only storage for the original PDFs. Statement metadata intentionally
 * lives in localStorage, while the binary stays in IndexedDB so the document
 * can be opened again after a reload without sending it anywhere.
 */

const databaseName = "marcelito-documents.v1";
const objectStoreName = "pdfs";

type StoredPdf = {
  key: string;
  blob: Blob;
  fileName: string;
  savedAt: string;
};

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new Error("IndexedDB no está disponible en este dispositivo."));
      return;
    }
    const request = indexedDB.open(databaseName, 1);
    request.onerror = () => reject(request.error ?? new Error("No se pudo abrir el almacenamiento local."));
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(objectStoreName)) {
        database.createObjectStore(objectStoreName, { keyPath: "key" });
      }
    };
    request.onsuccess = () => resolve(request.result);
  });
}

/** Saves a PDF by its immutable source fingerprint. Failures are non-fatal. */
export async function saveImportedPdf(key: string | undefined, file: File) {
  if (!key) return false;
  try {
    const database = await openDatabase();
    await new Promise<void>((resolve, reject) => {
      const transaction = database.transaction(objectStoreName, "readwrite");
      transaction.objectStore(objectStoreName).put({
        key,
        blob: file,
        fileName: file.name,
        savedAt: new Date().toISOString(),
      } satisfies StoredPdf);
      transaction.onerror = () => reject(transaction.error ?? new Error("No se pudo guardar el PDF localmente."));
      transaction.oncomplete = () => resolve();
    });
    database.close();
    return true;
  } catch {
    return false;
  }
}

async function readImportedPdf(key: string): Promise<StoredPdf | undefined> {
  const database = await openDatabase();
  try {
    return await new Promise<StoredPdf | undefined>((resolve, reject) => {
      const request = database.transaction(objectStoreName, "readonly").objectStore(objectStoreName).get(key);
      request.onerror = () => reject(request.error ?? new Error("No se pudo leer el PDF local."));
      request.onsuccess = () => resolve(request.result as StoredPdf | undefined);
    });
  } finally {
    database.close();
  }
}

/**
 * Opens a stored PDF in a new tab. The blank tab is created synchronously to
 * avoid popup blockers when this function is called from a click handler.
 */
export async function openImportedPdf(key: string | undefined) {
  if (!key || typeof window === "undefined") return false;
  let popup: Window | null = null;
  try {
    popup = window.open("about:blank", "_blank");
    const stored = await readImportedPdf(key);
    if (!stored) {
      popup?.close();
      return false;
    }
    const url = URL.createObjectURL(stored.blob);
    if (popup) {
      // Keep the new tab isolated while preserving the synchronous popup
      // handle required by browsers that block delayed window.open calls.
      popup.opener = null;
      popup.location.href = url;
      window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
      return true;
    }
    // If the browser blocked the popup, make one best-effort download/open
    // attempt. The caller still receives false so the UI can explain why.
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.target = "_blank";
    anchor.rel = "noopener noreferrer";
    anchor.download = stored.fileName;
    anchor.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
    return false;
  } catch {
    popup?.close();
    return false;
  }
}

/** Removes binary PDFs when the user deletes the local account. */
export async function clearImportedPdfs() {
  if (typeof indexedDB === "undefined") return;
  try {
    await new Promise<void>((resolve, reject) => {
      const request = indexedDB.deleteDatabase(databaseName);
      request.onerror = () => reject(request.error ?? new Error("No se pudo limpiar el almacenamiento local."));
      request.onsuccess = () => resolve();
      request.onblocked = () => resolve();
    });
  } catch {
    // Account deletion should never crash if a browser has disabled storage.
  }
}
