// Local persistence for Univer snapshots. Everything stays in the browser
// (IndexedDB via localStorage fallback is avoided — we use localStorage which
// is ample for document snapshots and dead simple). No network, no cloud.

const SHEETS_KEY = 'univer.local.sheets.v1';
const DOCS_KEY = 'univer.local.docs.v1';

export type DocKind = 'sheets' | 'docs';

function read<T>(key: string): T | null {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch {
    return null;
  }
}

function write(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (e) {
    // Quota exceeded or private mode — surface but never crash the editor.
    console.warn('[univer] local save failed:', e);
  }
}

export const store = {
  loadSheets: () => read(SHEETS_KEY),
  loadDocs: () => read(DOCS_KEY),
  saveSheets: (data: unknown) => write(SHEETS_KEY, data),
  saveDocs: (data: unknown) => write(DOCS_KEY, data),
  clearAll: () => {
    localStorage.removeItem(SHEETS_KEY);
    localStorage.removeItem(DOCS_KEY);
  },
};

export function downloadJson(filename: string, data: unknown): void {
  const blob = new Blob([JSON.stringify(data, null, 2)], {
    type: 'application/json',
  });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}