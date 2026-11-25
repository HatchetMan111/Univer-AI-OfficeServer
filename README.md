# Univer-AI-OfficeServer

Lokale **Office-Suite im Browser** (Tabellen wie Excel, Dokumente wie Word) auf Basis von
[Univer](https://github.com/dream-num/univer) (Apache-2.0) – vollständig **offline**, kein Cloud-Dienst.
Die App ist eine statische **React/Vite-SPA** (Univer-Presets 1.6.2, Sheets + Docs) und wird von
**nginx** in einem Proxmox-**LXC-Container** ausgeliefert.

> Alle Dokumente werden **lokal im Browser** (localStorage) gespeichert. In der UI oben rechts
> gibt es **JSON-Export/Import** und **Drucken / als PDF speichern**. Es ist kein Server-Backend
> und keine Cloud nötig.

---

## Einzeiler-Installation (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Univer-AI-OfficeServer/main/install/univer.sh)"
```

Das Script erstellt selbstständig einen **unprivilegierten LXC-Container** (nächste freie ID,
Standard 2 vCPU / 2 GB RAM / 8 GB Disk, `onboot=1`), installiert nginx + die App und richtet
einen systemd-Service ein. Am Ende wird die **Web-UI-URL** ausgegeben.

### Optionen

| Befehl | Wirkung |
|---|---|
| `… install/univer.sh` | Neu-Installation (nächste freie CT-ID) |
| `… install/univer.sh --ctid 120` | Installation mit fester CT-ID |
| `… install/univer.sh --update` | App im bestehenden CT aktualisieren |
| `… install/univer.sh --status` | Status + HTTP-Check anzeigen |
| `… install/univer.sh --uninstall` | Container dauerhaft löschen |
| `… install/univer.sh --debug` | Vollständiges `bash -x`-Log |

### Erwartete Ausgabe (Auszug)

```
=== Verifikation ===
✔ systemctl is-active univer → active
✔ Web-UI im CT: HTTP 200
✔ Web-UI vom Host erreichbar: http://10.120.1.50:8099 (HTTP 200)

╔══════════════════════════════════════════════════════════════╗
║  ✔ Univer ist installiert und läuft                          ║
╚══════════════════════════════════════════════════════════════╝
  CT-ID     : 120  (onboot=1, 2 vCPU / 2048 MB / 8 GB)
  Web-UI    : http://10.120.1.50:8099
```

---

## Web-UI

- URL: `http://<CT-IP>:8099` (Bind `0.0.0.0`, Port im CT offen)
- Tabs: **📊 Tabelle** und **📄 Dokument**
- **Tabellen-Funktionen:** bedingte Formatierung, Datenvalidierung, Suchen/Ersetzen, Hyperlinks, Notizen, Sortieren, Filtern, Tabellen, Zeichnen/Bilder
- **Dokument-Funktionen:** Zeichnen/Bilder, Hyperlinks, Kommentare
- Autosave alle 5 s in den Browser-LocalStorage des jeweiligen Browsers
- Oben rechts: **Export** (JSON), **Import** (JSON), **Druck** (Browser-Druck/PDF)

> **Präsentationen (Slides)** sind ein kostenpflichtiges **Pro**-Feature (`@univerjs-pro/*`, Lizenz nötig) und nicht Teil der Open-Source-Presets – daher nicht enthalten.

## Architektur

```
Host (PVE) --pct create--> LXC (Debian 13, unprivileged, nesting, onboot)
                              └─ nginx (univer.service, Restart=always)
                                   └─ /opt/univer/dist  (statischer Vite-Build)
```

- **Kein Node.js / kein Build im Container** – der fertige `dist/`-Build ist im Repo committet.
- Der Container startet dank `onboot:1` automatisch mit dem Host.
- `univer.service` überwacht nginx (`Restart=always`, `After=network-online.target`).

## Update / Deinstall

```bash
# Update (holt aktuellen dist-Build, rollt sauber um)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Univer-AI-OfficeServer/main/install/univer.sh)" --update

# Deinstall (löscht den Container inkl. Daten)
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Univer-AI-OfficeServer/main/install/univer.sh)" --uninstall
```

## Projektstruktur

```
install/univer.sh     # Proxmox-Einzeiler (Community-Scripts-konform)
app/                  # React + Vite + TypeScript Quelle
app/dist/             # committeter Build (wird im CT ausgeliefert)
univer.service        # systemd-Unit (nginx foreground, Restart=always)
nginx-univer.conf     # nginx-Referenzkonfiguration (Port 8099)
```

## Lizenz

Univer ist Apache-2.0 lizenziert (© DreamNum Co., Ltd.). Diese Installations- und
Verpackungs-Arbeit liegt unter der MIT-Lizenz.