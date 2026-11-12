#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  uninstall_elastalert2.sh
#  Removes ElastAlert2 and all associated files.
#  Run as root. Prompts for confirmation before each major step.
# ════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colour helpers ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RESET='\033[0m'
info()  { echo -e "${CYAN}==> $*${RESET}"; }
ok()    { echo -e "    ${GREEN}✓${RESET} $*"; }
warn()  { echo -e "    ${YELLOW}⚠${RESET}  $*"; }
die()   { echo -e "${RED}FATAL: $*${RESET}" >&2; exit 1; }

# ── Must run as root ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run this script as root."

# ── Confirmation helper ──────────────────────────────────────────
confirm() {
    local msg="$1"
    local answer
    read -rp "$(echo -e "    ${YELLOW}?${RESET}  ${msg} [y/N]: ")" answer
    [[ "${answer,,}" == "y" ]]
}

# ════════════════════════════════════════════════════════════════
# VARIABLES  (must match install_elastalert2.sh)
# ════════════════════════════════════════════════════════════════
VENV_DIR="/opt/elastalert2"
CONF_DIR="/etc/elastalert"
LOG_DIR="/var/log/elastalert"
SERVICE_FILE="/etc/systemd/system/elastalert.service"
CRON_FILE="/etc/cron.d/elastalert"
EA_USER="elastalert"
CREDS_FILE="/root/.elk_credentials"

# ════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${RED}════════════════════════════════════════${RESET}"
echo -e "${RED}  ElastAlert2 Uninstaller${RESET}"
echo -e "${RED}════════════════════════════════════════${RESET}"
echo ""
echo "  The following will be removed:"
echo "    Service  : $SERVICE_FILE"
echo "    Cron     : $CRON_FILE"
echo "    Venv     : $VENV_DIR"
echo "    Config   : $CONF_DIR"
echo "    Logs     : $LOG_DIR"
echo "    User     : $EA_USER"
echo ""
echo "  The following will NOT be removed unless you confirm:"
echo "    Credentials : $CREDS_FILE"
echo "    Writeback index in Elasticsearch (elastalert_status)"
echo ""

confirm "Proceed with uninstall?" || { echo "Aborted."; exit 0; }
echo ""

# ════════════════════════════════════════════════════════════════
# 1. STOP & DISABLE SERVICE
# ════════════════════════════════════════════════════════════════
info "[1/6] Stopping and disabling elastalert service..."

if systemctl is-active --quiet elastalert 2>/dev/null; then
    systemctl stop elastalert
    ok "Service stopped"
else
    warn "Service was not running"
fi

if systemctl is-enabled --quiet elastalert 2>/dev/null; then
    systemctl disable elastalert --quiet
    ok "Service disabled"
else
    warn "Service was not enabled"
fi

if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    ok "Service file removed"
else
    warn "Service file not found — skipped"
fi

# ════════════════════════════════════════════════════════════════
# 2. CRON JOB
# ════════════════════════════════════════════════════════════════
info "[2/6] Removing cron job..."

if [[ -f "$CRON_FILE" ]]; then
    rm -f "$CRON_FILE"
    ok "Cron job removed"
else
    warn "$CRON_FILE not found — skipped"
fi

# ════════════════════════════════════════════════════════════════
# 3. VIRTUALENV / BINARIES
# ════════════════════════════════════════════════════════════════
info "[3/6] Removing virtualenv..."

if [[ -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
    ok "$VENV_DIR removed"
else
    warn "$VENV_DIR not found — skipped"
fi

# ════════════════════════════════════════════════════════════════
# 4. CONFIGURATION & RULES
# ════════════════════════════════════════════════════════════════
info "[4/6] Removing configuration directory..."

if [[ -d "$CONF_DIR" ]]; then
    rm -rf "$CONF_DIR"
    ok "$CONF_DIR removed"
else
    warn "$CONF_DIR not found — skipped"
fi

# ════════════════════════════════════════════════════════════════
# 5. LOGS
# ════════════════════════════════════════════════════════════════
info "[5/6] Removing log directory..."

if [[ -d "$LOG_DIR" ]]; then
    rm -rf "$LOG_DIR"
    ok "$LOG_DIR removed"
else
    warn "$LOG_DIR not found — skipped"
fi

# ════════════════════════════════════════════════════════════════
# 6. SYSTEM USER
# ════════════════════════════════════════════════════════════════
info "[6/6] Removing system user '$EA_USER'..."

if id "$EA_USER" &>/dev/null; then
    userdel "$EA_USER"
    ok "User '$EA_USER' removed"
else
    warn "User '$EA_USER' not found — skipped"
fi

# ════════════════════════════════════════════════════════════════
# OPTIONAL: CREDENTIALS FILE
# ════════════════════════════════════════════════════════════════
echo ""
if [[ -f "$CREDS_FILE" ]]; then
    if confirm "Remove credentials file $CREDS_FILE?"; then
        rm -f "$CREDS_FILE"
        ok "$CREDS_FILE removed"
    else
        warn "$CREDS_FILE kept"
    fi
fi

# ════════════════════════════════════════════════════════════════
# OPTIONAL: ELASTICSEARCH WRITEBACK INDEX
# ════════════════════════════════════════════════════════════════
echo ""
if confirm "Delete Elasticsearch writeback index 'elastalert_status'?"; then
    warn "Attempting to delete index via curl..."
    CREDS_SOURCE="/root/.elk_credentials"
    if [[ -f "$CREDS_SOURCE" ]]; then
        # shellcheck source=/dev/null
        source "$CREDS_SOURCE"
    fi
    : "${ELASTIC_USER:=elastic}" "${ELASTIC_PASS:=changeme}"
    HTTP_CODE=$(curl -sk -o /tmp/ea_del.log -w "%{http_code}" \
        -u "${ELASTIC_USER}:${ELASTIC_PASS}" \
        -X DELETE "https://localhost:9200/elastalert_status")
    if [[ "$HTTP_CODE" == "200" ]]; then
        ok "Index 'elastalert_status' deleted (HTTP 200)"
    else
        warn "Unexpected response (HTTP $HTTP_CODE). Manual check:"
        warn "  cat /tmp/ea_del.log"
    fi
    rm -f /tmp/ea_del.log
else
    warn "Writeback index kept"
fi

# ════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}════════════════════════════════════════${RESET}"
echo -e "${GREEN}  Uninstall complete.${RESET}"
echo -e "${GREEN}════════════════════════════════════════${RESET}"
echo ""
echo "  To reinstall, run: bash install_elastalert2.sh"
echo ""
