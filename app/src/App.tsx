import { useEffect, useRef, useState } from 'react';
import { createUniver, LocaleType, type FUniver } from '@univerjs/presets';
import { UniverSheetsCorePreset } from '@univerjs/preset-sheets-core';
import { UniverDocsCorePreset } from '@univerjs/preset-docs-core';
import SheetsCoreDeDE from '@univerjs/preset-sheets-core/locales/de-DE';
import SheetsCoreEnUS from '@univerjs/preset-sheets-core/locales/en-US';
import DocsCoreDeDE from '@univerjs/preset-docs-core/locales/de-DE';
import DocsCoreEnUS from '@univerjs/preset-docs-core/locales/en-US';
import '@univerjs/preset-sheets-core/lib/index.css';
import '@univerjs/preset-docs-core/lib/index.css';
import { store, downloadJson, type DocKind } from './persistence';
import './app.css';

type Tab = DocKind;

// A minimal but valid workbook so the Sheets renderer has a sheet to paint.
function defaultWorkbook() {
  return {
    id: 'wb-local',
    name: 'Tabelle 1',
    sheetOrder: ['sheet-1'],
    sheets: {
      'sheet-1': {
        id: 'sheet-1',
        name: 'Tabelle 1',
        rowCount: 200,
        columnCount: 26,
        cellData: {
          0: { 0: { v: 'Willkommen bei Univer (lokal)!' } },
          1: { 0: { v: 'Alles bleibt in deinem Browser gespeichert.' } },
        },
      },
    },
    styles: {},
    resources: [],
  };
}

export default function App() {
  // Two INDEPENDENT Univer instances. Two core presets inside one createUniver
  // share a single UI plugin and only the last one paints — so we keep one
  // instance per document type, each in its own always-laid-out container.
  const sheetsApi = useRef<FUniver | null>(null);
  const docsApi = useRef<FUniver | null>(null);
  const [tab, setTab] = useState<Tab>('sheets');
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<string>('—');

  useEffect(() => {
    if (sheetsApi.current || docsApi.current) return;
    const sheetsEl = document.getElementById('univer-sheets');
    const docsEl = document.getElementById('univer-docs');
    if (!sheetsEl || !docsEl) return;

    try {
      const s = createUniver({
        locale: LocaleType.DE_DE,
        locales: {
          [LocaleType.DE_DE]: SheetsCoreDeDE,
          [LocaleType.EN_US]: SheetsCoreEnUS,
        },
        presets: [UniverSheetsCorePreset({ container: sheetsEl })],
      });
      sheetsApi.current = s.univerAPI;
      const savedSheets = store.loadSheets();
      s.univerAPI.createWorkbook((savedSheets as any) ?? defaultWorkbook());

      const d = createUniver({
        locale: LocaleType.DE_DE,
        locales: {
          [LocaleType.DE_DE]: DocsCoreDeDE,
          [LocaleType.EN_US]: DocsCoreEnUS,
        },
        presets: [UniverDocsCorePreset({ container: docsEl })],
      });
      docsApi.current = d.univerAPI;
      const savedDocs = store.loadDocs();
      d.univerAPI.createDocument((savedDocs as any) ?? {});

      setReady(true);
    } catch (e) {
      setError(e instanceof Error ? `${e.name}: ${e.message}` : String(e));
    }
  }, []);

  // Autosave loop — snapshot both docs into localStorage every few seconds.
  useEffect(() => {
    if (!ready) return;
    const save = () => {
      try {
        const wb = sheetsApi.current?.getActiveWorkbook?.();
        const doc = docsApi.current?.getActiveDocument?.();
        if (wb) store.saveSheets(wb.save());
        if (doc) store.saveDocs(doc.save());
        setSavedAt(new Date().toLocaleTimeString('de-DE'));
      } catch (e) {
        console.warn('[univer] autosave error', e);
      }
    };
    const id = window.setInterval(save, 5000);
    window.addEventListener('beforeunload', save);
    return () => {
      window.clearInterval(id);
      window.removeEventListener('beforeunload', save);
      save();
    };
  }, [ready]);

  const exportJson = () => {
    const wb = sheetsApi.current?.getActiveWorkbook?.();
    const doc = docsApi.current?.getActiveDocument?.();
    downloadJson(`univer-${tab}-${Date.now()}.json`, {
      kind: tab,
      sheets: wb?.save?.() ?? null,
      docs: doc?.save?.() ?? null,
    });
  };

  const importRef = useRef<HTMLInputElement>(null);
  const onImportFile = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const parsed = JSON.parse(await file.text());
      if (parsed.sheets) {
        sheetsApi.current?.createWorkbook(parsed.sheets);
        store.saveSheets(parsed.sheets);
      }
      if (parsed.docs) {
        docsApi.current?.createDocument(parsed.docs);
        store.saveDocs(parsed.docs);
      }
    } catch (err) {
      setError(`Import fehlgeschlagen: ${err instanceof Error ? err.message : String(err)}`);
    }
    if (importRef.current) importRef.current.value = '';
  };

  return (
    <div className="app">
      <header className="bar">
        <div className="brand">
          <span className="logo">U</span>
          <span className="brand-text">Univer <small>lokal</small></span>
        </div>
        <nav className="tabs">
          <button
            className={tab === 'sheets' ? 'tab active' : 'tab'}
            onClick={() => setTab('sheets')}
          >
            📊 Tabelle
          </button>
          <button
            className={tab === 'docs' ? 'tab active' : 'tab'}
            onClick={() => setTab('docs')}
          >
            📄 Dokument
          </button>
        </nav>
        <div className="actions">
          <span className="saved">Gespeichert: {savedAt}</span>
          <button onClick={exportJson} title="Als JSON herunterladen">⬇ Export</button>
          <button onClick={() => importRef.current?.click()} title="JSON importieren">⬆ Import</button>
          <button onClick={() => window.print()} title="Drucken / als PDF speichern">🖨 Druck</button>
          <input
            ref={importRef}
            type="file"
            accept="application/json,.json"
            hidden
            onChange={onImportFile}
          />
        </div>
      </header>

      {error && (
        <div className="errbanner">
          <strong>Fehler:</strong> {error}
          <button onClick={() => setError(null)}>✕</button>
        </div>
      )}

      <main className="stage">
        {!ready && !error && <div className="loading">Univer wird geladen …</div>}
        <div className={`pane ${tab === 'sheets' ? 'show' : ''}`} id="univer-sheets" />
        <div className={`pane ${tab === 'docs' ? 'show' : ''}`} id="univer-docs" />
      </main>
    </div>
  );
}