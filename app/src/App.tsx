import { useEffect, useRef, useState } from 'react';
import { createUniver, LocaleType, type FUniver } from '@univerjs/presets';

// --- Sheets: Core + kostenlose Feature-Presets (keine -pro Lizenz nötig) ---
import { UniverSheetsCorePreset } from '@univerjs/preset-sheets-core';
import { UniverSheetsConditionalFormattingPreset } from '@univerjs/preset-sheets-conditional-formatting';
import { UniverSheetsDataValidationPreset } from '@univerjs/preset-sheets-data-validation';
import { UniverSheetsFindReplacePreset } from '@univerjs/preset-sheets-find-replace';
import { UniverSheetsHyperLinkPreset } from '@univerjs/preset-sheets-hyper-link';
import { UniverSheetsNotePreset } from '@univerjs/preset-sheets-note';
import { UniverSheetsSortPreset } from '@univerjs/preset-sheets-sort';
import { UniverSheetsFilterPreset } from '@univerjs/preset-sheets-filter';
import { UniverSheetsTablePreset } from '@univerjs/preset-sheets-table';
import { UniverSheetsDrawingPreset } from '@univerjs/preset-sheets-drawing';

// --- Docs: Core + kostenlose Feature-Presets ---
import { UniverDocsCorePreset } from '@univerjs/preset-docs-core';
import { UniverDocsDrawingPreset } from '@univerjs/preset-docs-drawing';
import { UniverDocsHyperLinkPreset } from '@univerjs/preset-docs-hyper-link';
import { UniverDocsThreadCommentPreset } from '@univerjs/preset-docs-thread-comment';

// --- Locales (de-DE + en-US) je Preset ---
import SheetsCoreDe from '@univerjs/preset-sheets-core/locales/de-DE';
import SheetsCoreEn from '@univerjs/preset-sheets-core/locales/en-US';
import SheetsCfDe from '@univerjs/preset-sheets-conditional-formatting/locales/de-DE';
import SheetsCfEn from '@univerjs/preset-sheets-conditional-formatting/locales/en-US';
import SheetsDvDe from '@univerjs/preset-sheets-data-validation/locales/de-DE';
import SheetsDvEn from '@univerjs/preset-sheets-data-validation/locales/en-US';
import SheetsFrDe from '@univerjs/preset-sheets-find-replace/locales/de-DE';
import SheetsFrEn from '@univerjs/preset-sheets-find-replace/locales/en-US';
import SheetsHlDe from '@univerjs/preset-sheets-hyper-link/locales/de-DE';
import SheetsHlEn from '@univerjs/preset-sheets-hyper-link/locales/en-US';
import SheetsNoteDe from '@univerjs/preset-sheets-note/locales/de-DE';
import SheetsNoteEn from '@univerjs/preset-sheets-note/locales/en-US';
import SheetsSortDe from '@univerjs/preset-sheets-sort/locales/de-DE';
import SheetsSortEn from '@univerjs/preset-sheets-sort/locales/en-US';
import SheetsFilterDe from '@univerjs/preset-sheets-filter/locales/de-DE';
import SheetsFilterEn from '@univerjs/preset-sheets-filter/locales/en-US';
import SheetsTableDe from '@univerjs/preset-sheets-table/locales/de-DE';
import SheetsTableEn from '@univerjs/preset-sheets-table/locales/en-US';
import SheetsDrawDe from '@univerjs/preset-sheets-drawing/locales/de-DE';
import SheetsDrawEn from '@univerjs/preset-sheets-drawing/locales/en-US';

import DocsCoreDe from '@univerjs/preset-docs-core/locales/de-DE';
import DocsCoreEn from '@univerjs/preset-docs-core/locales/en-US';
import DocsDrawDe from '@univerjs/preset-docs-drawing/locales/de-DE';
import DocsDrawEn from '@univerjs/preset-docs-drawing/locales/en-US';
import DocsHlDe from '@univerjs/preset-docs-hyper-link/locales/de-DE';
import DocsHlEn from '@univerjs/preset-docs-hyper-link/locales/en-US';
import DocsTcDe from '@univerjs/preset-docs-thread-comment/locales/de-DE';
import DocsTcEn from '@univerjs/preset-docs-thread-comment/locales/en-US';

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

const SHEETS_LOCALES_DE = {
  ...SheetsCoreDe, ...SheetsCfDe, ...SheetsDvDe, ...SheetsFrDe, ...SheetsHlDe,
  ...SheetsNoteDe, ...SheetsSortDe, ...SheetsFilterDe, ...SheetsTableDe, ...SheetsDrawDe,
};
const SHEETS_LOCALES_EN = {
  ...SheetsCoreEn, ...SheetsCfEn, ...SheetsDvEn, ...SheetsFrEn, ...SheetsHlEn,
  ...SheetsNoteEn, ...SheetsSortEn, ...SheetsFilterEn, ...SheetsTableEn, ...SheetsDrawEn,
};
const DOCS_LOCALES_DE = { ...DocsCoreDe, ...DocsDrawDe, ...DocsHlDe, ...DocsTcDe };
const DOCS_LOCALES_EN = { ...DocsCoreEn, ...DocsDrawEn, ...DocsHlEn, ...DocsTcEn };

export default function App() {
  // Two INDEPENDENT Univer instances (two core presets in one createUniver share
  // a single UI plugin and only the last paints). One instance per doc type.
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
          [LocaleType.DE_DE]: SHEETS_LOCALES_DE,
          [LocaleType.EN_US]: SHEETS_LOCALES_EN,
        },
        presets: [
          UniverSheetsCorePreset({ container: sheetsEl }),
          UniverSheetsConditionalFormattingPreset(),
          UniverSheetsDataValidationPreset(),
          UniverSheetsFindReplacePreset(),
          UniverSheetsHyperLinkPreset(),
          UniverSheetsNotePreset(),
          UniverSheetsSortPreset(),
          UniverSheetsFilterPreset(),
          UniverSheetsTablePreset(),
          UniverSheetsDrawingPreset(),
        ],
      });
      sheetsApi.current = s.univerAPI;
      const savedSheets = store.loadSheets();
      s.univerAPI.createWorkbook((savedSheets as any) ?? defaultWorkbook());

      const d = createUniver({
        locale: LocaleType.DE_DE,
        locales: {
          [LocaleType.DE_DE]: DOCS_LOCALES_DE,
          [LocaleType.EN_US]: DOCS_LOCALES_EN,
        },
        presets: [
          UniverDocsCorePreset({ container: docsEl }),
          UniverDocsDrawingPreset(),
          UniverDocsHyperLinkPreset(),
          UniverDocsThreadCommentPreset(),
        ],
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