#!/usr/bin/env bash
# =============================================================================
#  Univer-AI-OfficeServer – lokaler Office-Suite-Container (Tabellen + Dokumente)
#  Community-Scripts-konformer Einzeiler-Installer für Proxmox VE.
#
#  App:      Univer (dream-num/univer, Apache-2.0) als statische React/Vite-SPA
#  Web-UI:   http://<CT-IP>:8099  (nginx, Bind 0.0.0.0)
#  Modus:    LXC (unprivileged, nesting=1, onboot=1)
#
#  Einzeiler (auf dem PVE-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Univer-AI-OfficeServer/main/install/univer.sh)"
#
#  Optionen: --ctid <id>  --id <id> (--update/--uninstall/--status)  --debug
# =============================================================================
set -Eeuo pipefail

# ---------- Variablen (oben, anpassbar) --------------------------------------
APP_DIR="/opt/univer"
PORT="8099"
CT_HOSTNAME="univer"
CORES="2"
RAM="2048"            # MB
DISK="8"             # GB
TEMPLATE_STORAGE="local"
STORAGE=""           # leer -> automatische Erkennung
BRIDGE=""            # leer -> automatische Erkennung
REPO="HatchetMan111/Univer-AI-OfficeServer"
REPO_REF="main"
TARBALL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REPO_REF}"
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Univer-AI-OfficeServer/main/install/univer.sh)"'

# ---------- Farben / Helper --------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi
info()  { echo "${C_BLUE}➜${C_RESET} $*"; }
ok()    { echo "${C_GREEN}✔${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}⚠${C_RESET} $*"; }
err()   { echo "${C_RED}✖ $*${C_RESET}" >&2; }
header(){ echo; echo "${C_BOLD}=== $* ===${C_RESET}"; }

# ---------- Fehlerkette (vollständig, nie nur letzte Zeile) ------------------
CTID=""
MODE="install"
FORCE_ID=""
DEBUG=0

on_error() {
  local rc=$1 line=$2
  echo >&2
  err "ABBRUCH (Exit ${rc}) in Zeile ${line}"
  echo "${C_RED}------------------------------------------------------------${C_RESET}" >&2
  echo "Vollständige Fehlerkette:" >&2
  echo "  • Exit-Code : ${rc}" >&2
  echo "  • Zeile     : ${line}" >&2
  if [[ -n "${CTID}" ]]; then
    echo "  • CT ${CTID} – innerer Setup-Log (letzte 40 Zeilen):" >&2
    pct exec "${CTID}" -- bash -c 'cat /var/log/univer-setup.log 2>/dev/null | tail -40' >&2 || true
    echo "  • CT ${CTID} – journalctl univer (letzte 30 Zeilen):" >&2
    pct exec "${CTID}" -- journalctl -u univer --no-pager 2>/dev/null | tail -30 >&2 || true
  fi
  echo "${C_RED}------------------------------------------------------------${C_RESET}" >&2
  echo "Tipp: mit ${C_BOLD}--debug${C_RESET} erneut starten, um ein vollständiges 'bash -x'-Log zu erhalten:" >&2
  echo "  ${ONE_LINER} --debug" >&2
  exit "${rc}"
}
trap 'on_error $? $LINENO' ERR

# ---------- Basisprüfungen ---------------------------------------------------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Dieses Script muss als root auf dem Proxmox-Host laufen."
    exit 1
  fi
  if ! command -v pct >/dev/null 2>&1; then
    err "'pct' nicht gefunden – läuft das hier auf einem Proxmox-Host?"
    exit 1
  fi
}

detect_arch() {
  local a
  a="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$(uname -m 2>/dev/null || echo x86_64)" in
    aarch64|arm64) a="arm64" ;;
    x86_64|amd64)  a="amd64" ;;
  esac
  echo "${a:-amd64}"
}

next_free_id() {
  local id
  id="$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')"
  [[ -n "$id" ]] && { echo "$id"; return 0; }
  # Fallback: höchste belegte ID + 1
  local max=100
  while read -r used _; do
    [[ "$used" =~ ^[0-9]+$ ]] || continue
    (( used > max )) && max=$used
  done < <(pct list 2>/dev/null)
  echo $((max + 1))
}

detect_storage() {
  if [[ -n "$STORAGE" ]]; then echo "$STORAGE"; return 0; fi
  local s
  s="$(pvesm status 2>/dev/null | awk 'NR>1 && $2=="active" && $6 ~ /vztmpl|rootdir/ {print $1; exit}')"
  [[ -n "$s" ]] && { echo "$s"; return 0; }
  echo "local-lvm"
}

detect_bridge() {
  if [[ -n "$BRIDGE" ]]; then echo "$BRIDGE"; return 0; fi
  local d name
  # 1) Bevorzugt eine echte vmbr*-Bridge.
  for d in /sys/class/net/vmbr*; do
    [[ -e "$d" ]] || continue
    [[ -d "$d/bridge" ]] && { basename "$d"; return 0; }
  done
  # 2) Jede echte Bridge, die ein PHYSISCHES Interface eingebunden hat.
  #    fwbr*/fwln*/veth*/tap*/vme* sind virtuelle Proxmox-Brücken – die CTs
  #    hängen daran, taugen aber NICHT als net0-Bridge.
  for d in /sys/class/net/*; do
    name="$(basename "$d")"
    case "$name" in
      fwbr*|fwln*|veth*|tap*|vme*|lo) continue ;;
    esac
    [[ -d "$d/bridge" ]] || continue
    if ls "$d/brif" 2>/dev/null | grep -qE '^(en|eth|eno|ens|enp|bond|ib|wl)'; then
      echo "$name"; return 0
    fi
  done
  # 3) Fallback vmbr0 (Warnung im Aufrufer, notfalls --bridge nutzen).
  echo "vmbr0"
}

# ---------- Template (arch-bewusst, kein arm64-auf-amd64) --------------------
choose_template() {
  local arch="$1" tpl
  # 1) lokal vorhandenes, arch-korrektes Debian-Template (neueste zuerst)
  tpl="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
        | awk '{print $1}' \
        | grep -E "debian-1[23]-standard.*_${arch}\.tar\.(zst|xz|gz)$" \
        | sort -rV | head -1 || true)"
  if [[ -z "$tpl" ]]; then
    warn "Kein passendes ${arch}-Template lokal – lade debian-13-standard herunter …"
    pveam download "$TEMPLATE_STORAGE" "debian-13-standard_${arch}.tar.zst" || {
      err "Template-Download fehlgeschlagen (Architektur: ${arch})."
      exit 1
    }
    tpl="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
          | awk '{print $1}' \
          | grep -E "debian-13-standard.*_${arch}\.tar\.(zst|xz|gz)$" \
          | sort -rV | head -1 || true)"
  fi
  [[ -n "$tpl" ]] || { err "Kein Debian-Template für ${arch} verfügbar."; exit 1; }
  echo "$tpl"
}

# ---------- CT-Helfer --------------------------------------------------------
# pct create mit ostype-Fallback: neues PVE (>=9) kennt 'l26' nicht mehr und
# verlangt 'debian' – wir probieren beide, wiederholen aber NUR bei einem
# echten ostype-Enum-Fehler (sonst sofort abbrechen + vollständige Ausgabe).
create_ct() {
  local id="$1" tpl="$2" storage="$3" bridge="$4" ost errlog
  local -a base=(
    "$id" "$tpl"
    --hostname "$CT_HOSTNAME"
    --cores "$CORES" --memory "$RAM"
    --rootfs "${storage}:${DISK}"
    --net0 "name=eth0,bridge=${bridge},ip=dhcp"
    --nameserver "1.1.1.1 8.8.8.8"
    --unprivileged 1 --features nesting=1
    --onboot 1 --start 1
  )
  errlog="$(mktemp)"
  for ost in l26 debian; do
    if pct create "${base[@]}" --ostype "$ost" 2>"$errlog"; then
      ok "CT ${id} angelegt (ostype=${ost}, onboot=1, Start angefordert)."
      rm -f "$errlog"; return 0
    fi
    if ! grep -qi "ostype" "$errlog"; then
      err "pct create fehlgeschlagen (vollständige Ausgabe):"
      cat "$errlog" >&2; rm -f "$errlog"; return 1
    fi
  done
  err "pct create mit keinem ostype (l26/debian) erfolgreich:"
  cat "$errlog" >&2; rm -f "$errlog"; return 1
}

find_ct_id_by_hostname() {
  local name="$1" id
  if [[ -n "$FORCE_ID" ]]; then echo "$FORCE_ID"; return 0; fi
  for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
    if pct config "$id" 2>/dev/null | grep -q "^hostname: ${name}$"; then
      echo "$id"; return 0
    fi
  done
  # Fallback: Name ist immer die letzte Spalte
  pct list 2>/dev/null | awk -v n="$name" 'NR>1 && $NF==n{print $1; exit}'
}

ensure_ct_running() {
  local id="$1" st
  st="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
  if [[ "$st" != "running" ]]; then
    info "CT ${id} ist ${st:-unbekannt} – starte ihn …"
    pct start "$id" || { err "pct start ${id} fehlgeschlagen."; exit 1; }
    wait_ct_network "$id"
  fi
}

get_ct_ip() {
  local id="$1" ip
  ip="$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\./){print $i; exit}}' || true)"
  echo "${ip:-}"
}

wait_ct_network() {
  local id="$1" ip
  for _ in $(seq 1 30); do
    ip="$(get_ct_ip "$id")"
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    sleep 2
  done
  return 0
}

verify_ct_started() {
  local id="$1" arch="$2" st
  for _ in $(seq 1 15); do
    st="$(pct status "$id" 2>/dev/null | awk '{print $2}')"
    [[ "$st" == "running" ]] && { ok "CT ${id} läuft."; return 0; }
    sleep 1
  done
  err "CT ${id} startet nicht (Status: ${st:-unbekannt})."
  err "Häufige Ursache: Template-Architektur (${arch}) passt nicht zum Host."
  err "Diagnose: 'pct start ${id}' sowie 'pct config ${id}' prüfen."
  err "Reinstall: ${ONE_LINER} --ctid ${id} --debug"
  exit 1
}

verify_ct_dns() {
  local id="$1" host="$2" ok_count=0
  for _ in $(seq 1 8); do
    if pct exec "$id" -- getent hosts "$host" >/dev/null 2>&1; then
      ok_count=$((ok_count + 1))
      if (( ok_count >= 3 )); then return 0; fi
    else
      ok_count=0
    fi
    sleep 2
  done
  warn "DNS im CT instabil – schreibe Fallback-Nameserver …"
  local ns
  ns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
  pct exec "$id" -- bash -c "printf 'nameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' '${ns:-192.168.178.1}' > /etc/resolv.conf" || true
  pct exec "$id" -- getent hosts "$host" >/dev/null 2>&1 || {
    err "DNS im CT bleibt defekt (Host: ${host})."
    exit 1
  }
  ok "DNS-Fallback aktiv."
}

# ---------- Inner-Script (im CT ausgeführt) ----------------------------------
# Wird als QUOTETER Heredoc geschrieben; Werte kommen zur Laufzeit als ENV
# (MODE, PORT, APP_DIR, TARBALL) über 'pct exec -- env … bash inner.sh'.
write_inner_script() {
  cat > /root/univer-inner.sh <<'INNEREOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee /var/log/univer-setup.log) 2>&1
MODE="${MODE:-install}"; PORT="${PORT:-8099}"; APP_DIR="${APP_DIR:-/opt/univer}"; TARBALL="${TARBALL:?}"
log(){ echo "[inner] $*"; }

log "Basis-Pakete installieren (curl VOR jedem Download!) …"
apt-get update -qq
apt-get install -y -qq ca-certificates curl tar nginx

# Distro-nginx (Port 80) deaktivieren – wir betreiben eine eigene Instanz.
systemctl disable --now nginx.service >/dev/null 2>&1 || true

log "Repo-Tarball laden: ${TARBALL}"
WORK="$(mktemp -d)"
curl -fsSL "${TARBALL}" -o "${WORK}/repo.tar.gz"
tar -xzf "${WORK}/repo.tar.gz" -C "${WORK}"
SRC="$(find "${WORK}" -maxdepth 1 -type d -name 'Univer-AI-OfficeServer-*' | head -1)"
if [[ -z "${SRC}" || ! -d "${SRC}/app/dist" ]]; then
  log "FEHLER: app/dist fehlt im Tarball (Repo-Struktur prüfen)."
  exit 1
fi

log "dist nach ${APP_DIR}/dist kopieren (Swap, rollback-fähig) …"
mkdir -p "${APP_DIR}"
if [[ -d "${APP_DIR}/dist" ]]; then
  rm -rf "${APP_DIR}/dist.old"
  mv "${APP_DIR}/dist" "${APP_DIR}/dist.old"
fi
mv "${SRC}/app/dist" "${APP_DIR}/dist"
rm -rf "${APP_DIR}/dist.old" "${WORK}"

log "nginx-Konfiguration schreiben (/etc/univer/nginx.conf) …"
mkdir -p /etc/univer /var/log/univer
cat > /etc/univer/nginx.conf <<NGINX
worker_processes 1;
pid /run/univer-nginx.pid;
error_log /var/log/univer/nginx-error.log;
events { worker_connections 256; }
http {
    access_log /var/log/univer/nginx-access.log;
    server {
        listen ${PORT};
        listen [::]:${PORT};
        server_name _;
        root ${APP_DIR}/dist;
        index index.html;
        location / { try_files \$uri \$uri/ /index.html; }
    }
}
NGINX

log "systemd-Unit schreiben (/etc/systemd/system/univer.service) …"
cat > /etc/systemd/system/univer.service <<UNIT
[Unit]
Description=Univer local office suite (nginx static SPA)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/nginx -g 'daemon off;' -c /etc/univer/nginx.conf
ExecReload=/usr/sbin/nginx -s reload -c /etc/univer/nginx.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable univer.service >/dev/null 2>&1
systemctl restart univer.service

log "Verifikation im CT …"
sleep 1
if ! systemctl is-active --quiet univer.service; then
  log "FEHLER: univer.service nicht aktiv."
  journalctl -u univer --no-pager | tail -30
  exit 1
fi
CODE="$(curl -s -L -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" || true)"
if [[ "${CODE}" != "200" ]]; then
  log "FEHLER: Web-UI antwortet mit HTTP ${CODE} (erwartet 200)."
  journalctl -u univer --no-pager | tail -30
  exit 1
fi
log "OK: Service aktiv, Web-UI HTTP 200 auf Port ${PORT}."
INNEREOF
  chmod +x /root/univer-inner.sh
}

run_inner() {
  local id="$1"
  pct push "$id" /root/univer-inner.sh /root/univer-inner.sh
  pct exec "$id" -- env \
    MODE="$MODE" PORT="$PORT" APP_DIR="$APP_DIR" TARBALL="$TARBALL" \
    bash /root/univer-inner.sh
}

# ---------- Modi -------------------------------------------------------------
do_install() {
  header "Univer – Installation"
  check_root
  local arch tpl storage bridge ip
  arch="$(detect_arch)"
  storage="$(detect_storage)"
  bridge="$(detect_bridge)"
  info "Architektur: ${arch} | Speicher: ${storage} | Bridge: ${bridge}"

  if [[ -n "$FORCE_ID" ]]; then
    CTID="$FORCE_ID"
  else
    CTID="$(next_free_id)"
  fi
  if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CTID"; then
    warn "CT ${CTID} existiert bereits – --update wird ausgeführt."
    MODE="update"; do_update; return 0
  fi

  tpl="$(choose_template "$arch")"
  ok "Template: ${tpl}"

  header "CT ${CTID} (${CT_HOSTNAME}) erstellen"
  if [[ ! -d "/sys/class/net/${bridge}/bridge" ]]; then
    warn "Bridge '${bridge}' ist keine Linux-Bridge – CT-Netz könnte scheitern."
    warn "Bei Problemen mit --bridge <vmbrX> eine echte Bridge angeben."
  fi
  create_ct "$CTID" "$tpl" "$storage" "$bridge"
  ok "CT ${CTID} angelegt (onboot=1, Start angefordert)."

  # Start + Arch-Spawn-Implosion abfangen (pct create --start meldet trotz
  # fehlgeschlagenem Spawn Exit 0 – Status-Poll macht es sichtbar).
  verify_ct_started "$CTID" "$arch"
  ip="$(wait_ct_network "$CTID")"
  [[ -n "$ip" ]] || { err "CT ${CTID} bekam keine IP (DHCP/DNS prüfen)."; exit 1; }
  ok "CT-IP: ${ip}"
  verify_ct_dns "$CTID" "github.com"

  header "App im CT einrichten"
  write_inner_script
  run_inner "$CTID"

  verify_installation "$CTID" "$ip"
  summary "$ip"
}

do_update() {
  header "Univer – Update"
  check_root
  if [[ -z "$CTID" ]]; then
    CTID="$(find_ct_id_by_hostname "$CT_HOSTNAME")"
  fi
  [[ -n "$CTID" ]] || { err "Kein CT '${CT_HOSTNAME}' gefunden. Mit --id <id> angeben."; exit 1; }
  ensure_ct_running "$CTID"
  local ip; ip="$(get_ct_ip "$CTID")"
  MODE="update"
  write_inner_script
  run_inner "$CTID"
  verify_installation "$CTID" "$ip"
  summary "$ip"
}

do_uninstall() {
  header "Univer – Deinstallation"
  check_root
  if [[ -z "$CTID" ]]; then
    CTID="$(find_ct_id_by_hostname "$CT_HOSTNAME")"
  fi
  [[ -n "$CTID" ]] || { err "Kein CT '${CT_HOSTNAME}' gefunden. Mit --id <id> angeben."; exit 1; }
  warn "CT ${CTID} wird DAUERHAFT gelöscht (inkl. aller lokalen Daten im Browser? nein – nur der Container)."
  read -r -p "Wirklich löschen? [j/N] " ans
  case "$ans" in
    j|J|ja|JA)
      pct stop "$CTID" 2>/dev/null || true
      pct destroy "$CTID" --purge || { err "pct destroy fehlgeschlagen."; exit 1; }
      ok "CT ${CTID} gelöscht."
      ;;
    *) warn "Abgebrochen." ;;
  esac
}

do_status() {
  header "Univer – Status"
  if [[ -z "$CTID" ]]; then
    CTID="$(find_ct_id_by_hostname "$CT_HOSTNAME")"
  fi
  [[ -n "$CTID" ]] || { err "Kein CT '${CT_HOSTNAME}' gefunden."; exit 1; }
  local st ip code
  st="$(pct status "$CTID" 2>/dev/null | awk '{print $2}')"
  ip="$(get_ct_ip "$CTID")"
  echo "CT-ID     : ${CTID}"
  echo "Status    : ${st}"
  echo "IP        : ${ip:-—}"
  if [[ "$st" == "running" ]]; then
    code="$(pct exec "$CTID" -- curl -s -L -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" 2>/dev/null || true)"
    echo "Web-UI    : HTTP ${code:-?} auf Port ${PORT}"
    pct exec "$CTID" -- systemctl is-active univer 2>/dev/null | sed 's/^/Service   : /' || true
  fi
}

verify_installation() {
  local id="$1" ip="$2" code
  header "Verifikation"
  local active; active="$(pct exec "$id" -- systemctl is-active univer 2>/dev/null || true)"
  [[ "$active" == "active" ]] && ok "systemctl is-active univer → active" || { err "Service nicht aktiv (${active})."; exit 1; }
  code="$(pct exec "$id" -- curl -s -L -o /dev/null -w '%{http_code}' "http://localhost:${PORT}/" 2>/dev/null || true)"
  [[ "$code" == "200" ]] && ok "Web-UI im CT: HTTP 200" || { err "Web-UI im CT antwortet mit ${code}."; exit 1; }
  if [[ -n "$ip" ]]; then
    local hcode; hcode="$(curl -s -L -o /dev/null -w '%{http_code}' "http://${ip}:${PORT}/" 2>/dev/null || true)"
    [[ "$hcode" == "200" ]] && ok "Web-UI vom Host erreichbar: http://${ip}:${PORT} (HTTP 200)" \
      || warn "Host-Check HTTP ${hcode} – ggf. Firewall/Bridge prüfen (URL: http://${ip}:${PORT})."
  fi
}

summary() {
  local ip="$1"
  echo
  echo "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}║  ✔ Univer ist installiert und läuft                          ║${C_RESET}"
  echo "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
  echo "  CT-ID     : ${CTID}  (onboot=1, ${CORES} vCPU / ${RAM} MB / ${DISK} GB)"
  echo "  Web-UI    : ${C_GREEN}http://${ip}:${PORT}${C_RESET}"
  echo "  Service   : systemctl status univer   (nginx, Restart=always)"
  echo "  Logs      : pct exec ${CTID} -- journalctl -u univer -f"
  echo
  echo "  Update    : ${ONE_LINER} --update"
  echo "  Status    : ${ONE_LINER} --status"
  echo "  Deinstall : ${ONE_LINER} --uninstall"
  echo
  echo "  Hinweis: Die App ist eine statische SPA – alle Dokumente werden"
  echo "  lokal im Browser (localStorage) gespeichert. JSON-Export/Import"
  echo "  und Drucken/PDF sind in der UI oben rechts verfügbar."
  echo
}

# ---------- Argumente ($0-Fallback für bash -c) ------------------------------
# Bei 'bash -c "<script>" --flag …' belegt der erste Parameter $0 (nicht $1).
# Daher $0 bei Bedarf voranstellen und ALLE Argumente aus dem Array parsen.
args=("$@")
[[ "${0:-}" == -* ]] && args=("${0}" "${args[@]}")
set -- "${args[@]}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)     MODE="update" ;;
    --uninstall)  MODE="uninstall" ;;
    --status)     MODE="status" ;;
    --ctid)       CTID="${2:-}"; FORCE_ID="${2:-}"; shift ;;
    --id)         FORCE_ID="${2:-}"; CTID="${2:-}"; shift ;;
    --bridge)     BRIDGE="${2:-}"; shift ;;
    --debug)      DEBUG=1 ;;
    -h|--help)
      echo "Univer-Installer  Optionen: --ctid <id> | --update | --uninstall | --status | --id <id> | --debug"
      exit 0 ;;
    *) err "Unbekannte Option: $1"; exit 1 ;;
  esac
  shift
done

if [[ "$DEBUG" == "1" ]]; then
  warn "Debug-Modus: set -x aktiv – vollständiges Log folgt."
  set -x
fi

case "$MODE" in
  install)   do_install ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *) err "Unbekannter Modus: $MODE"; exit 1 ;;
esac