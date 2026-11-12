#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  install_elastalert2.sh
#  Production-ready ElastAlert2 installer
#  Target: Ubuntu 22.04 / Debian 12
#  Run as root. Idempotent — safe to re-run.
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
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo -i or su -)."

# ════════════════════════════════════════════════════════════════
# 1. CREDENTIALS
# ════════════════════════════════════════════════════════════════
CREDS_FILE="/root/.elk_credentials"

if [[ ! -f "$CREDS_FILE" ]]; then
    info "Credentials file not found — creating template at $CREDS_FILE"
    cat > "$CREDS_FILE" << 'CREDEOF'
# ElastAlert2 credentials
# Fill in every value, then re-run the installer.
ELASTIC_USER="elastalert"
ELASTIC_PASS="changeme"
SMTP_USER="you@gmail.com"
SMTP_PASS="your_app_password"
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
TELEGRAM_BOT_TOKEN="your_bot_token"
TELEGRAM_CHAT_ID="your_chat_id"
CREDEOF
    chmod 600 "$CREDS_FILE"
    warn "Edit $CREDS_FILE with real values, then re-run."
    exit 1
fi

chmod 600 "$CREDS_FILE"
# shellcheck source=/dev/null
source "$CREDS_FILE"

: "${ELASTIC_USER:?}"   "${ELASTIC_PASS:?}"
: "${SMTP_USER:?}"      "${SMTP_PASS:?}"
: "${SLACK_WEBHOOK_URL:?}"
: "${TELEGRAM_BOT_TOKEN:?}" "${TELEGRAM_CHAT_ID:?}"

# ════════════════════════════════════════════════════════════════
# 2. VARIABLES
# ════════════════════════════════════════════════════════════════
EA_VERSION="2.30.0"
VENV_DIR="/opt/elastalert2/venv"
EA_BIN="$VENV_DIR/bin/elastalert"
EA_TEST_BIN="$VENV_DIR/bin/elastalert-test-rule"
EA_INDEX_BIN="$VENV_DIR/bin/elastalert-create-index"
CONF_DIR="/etc/elastalert"
RULES_DIR="$CONF_DIR/rules"
CERTS_DIR="$CONF_DIR/certs"
LOG_DIR="/var/log/elastalert"
CONFIG_FILE="$CONF_DIR/config.yaml"
SMTP_AUTH_FILE="$CONF_DIR/smtp_auth.yaml"
ENV_FILE="$CONF_DIR/.env"
SERVICE_FILE="/etc/systemd/system/elastalert.service"
CRON_FILE="/etc/cron.d/elastalert"
EA_USER="elastalert"

# ════════════════════════════════════════════════════════════════
# 3. SYSTEM PACKAGES & PYTHON
# ════════════════════════════════════════════════════════════════
info "[1/9] Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv python3-dev \
    libssl-dev libffi-dev gcc git curl > /dev/null
ok "System packages installed"

PY_VERSION=$(python3 --version)
ok "Python: $PY_VERSION"

# ════════════════════════════════════════════════════════════════
# 4. SYSTEM USER & DIRECTORIES
# ════════════════════════════════════════════════════════════════
info "[2/9] Creating system user and directories..."

if ! id "$EA_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$EA_USER"
    ok "User '$EA_USER' created"
else
    ok "User '$EA_USER' already exists"
fi

for d in "$CONF_DIR" "$RULES_DIR" "$CERTS_DIR" "$LOG_DIR" /opt/elastalert2; do
    mkdir -p "$d"
done

chown -R "$EA_USER:$EA_USER" "$CONF_DIR" "$LOG_DIR"
chmod 750 "$CONF_DIR" "$LOG_DIR"
ok "Directories ready"

# ════════════════════════════════════════════════════════════════
# 5. PYTHON VIRTUALENV & ELASTALERT2
# ════════════════════════════════════════════════════════════════
info "[3/9] Installing ElastAlert2 ${EA_VERSION} in virtualenv..."

if [[ ! -x "$EA_BIN" ]]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    "$VENV_DIR/bin/pip" install --quiet "elastalert2==${EA_VERSION}"
    ok "ElastAlert2 ${EA_VERSION} installed"
else
    INSTALLED=$("$VENV_DIR/bin/pip" show elastalert2 2>/dev/null | awk '/^Version/{print $2}')
    ok "ElastAlert2 already installed (version: $INSTALLED)"
fi

# ════════════════════════════════════════════════════════════════
# 6. CERTIFICATES
# ════════════════════════════════════════════════════════════════
info "[4/9] Checking certificates..."

CA_SRC="/etc/elasticsearch/certs/ca.crt"
CA_DEST="$CERTS_DIR/ca.crt"

if [[ -f "$CA_DEST" ]]; then
    ok "ca.crt already present at $CA_DEST"
elif [[ -f "$CA_SRC" ]]; then
    cp "$CA_SRC" "$CA_DEST"
    chown "$EA_USER:$EA_USER" "$CA_DEST"
    chmod 640 "$CA_DEST"
    ok "ca.crt copied from $CA_SRC"
else
    warn "ca.crt not found. Copy it manually:"
    warn "  cp /path/to/ca.crt $CA_DEST"
    warn "  chown ${EA_USER}:${EA_USER} $CA_DEST && chmod 640 $CA_DEST"
fi

# ════════════════════════════════════════════════════════════════
# 7. CONFIGURATION FILES
# ════════════════════════════════════════════════════════════════
info "[5/9] Writing configuration files..."

# ── config.yaml ─────────────────────────────────────────────────
# Written only once; re-run will not overwrite.
if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" << 'EOF'
# /etc/elastalert/config.yaml

# ── Elasticsearch connection (TLS) ──────────────────────────────
es_host: localhost
es_port: 9200
use_ssl: true
verify_certs: true
ca_certs: /etc/elastalert/certs/ca.crt
es_username: "${ELASTIC_USER}"
es_password: "${ELASTIC_PASS}"

# ── Rule and log directories ─────────────────────────────────────
rules_folder: /etc/elastalert/rules
run_every:
  minutes: 1
buffer_time:
  minutes: 15

# ── ElastAlert metadata index ────────────────────────────────────
writeback_index: elastalert_status
alert_time_limit:
  days: 2

# ── Misc ─────────────────────────────────────────────────────────
scan_subdirectories: false

# ── Logging ──────────────────────────────────────────────────────
logging:
  version: 1
  formatters:
    logline:
      format: '%(asctime)s %(levelname)s %(name)s %(message)s'
  handlers:
    file:
      class: logging.handlers.RotatingFileHandler
      formatter: logline
      filename: /var/log/elastalert/elastalert.log
      maxBytes: 10485760
      backupCount: 5
  root:
    level: INFO
    handlers: [file]
EOF
    chown "$EA_USER:$EA_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    ok "config.yaml created"
else
    ok "config.yaml already exists — skipped"
fi

# ── .env (credential substitution for config.yaml) ──────────────
cat > "$ENV_FILE" << EOF
ELASTIC_USER=${ELASTIC_USER}
ELASTIC_PASS=${ELASTIC_PASS}
EOF
chown "$EA_USER:$EA_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"
ok ".env written"

# ── smtp_auth.yaml ───────────────────────────────────────────────
cat > "$SMTP_AUTH_FILE" << EOF
user: ${SMTP_USER}
password: ${SMTP_PASS}
EOF
chown "$EA_USER:$EA_USER" "$SMTP_AUTH_FILE"
chmod 640 "$SMTP_AUTH_FILE"
ok "smtp_auth.yaml written"

# ── Rule 01: SSH Brute Force ─────────────────────────────────────
RULE01="$RULES_DIR/opnsense-rule-01-ssh-brute-force.yaml"
if [[ ! -f "$RULE01" ]]; then
    cat > "$RULE01" << EOF
# ============================================================
# opnsense-rule-01: SSH Brute Force
# ============================================================
name: OPNsense - SSH Brute Force Attack
type: frequency

index: opnsense-syslog-*

num_events: 10
timeframe:
  minutes: 5

filter:
  - query:
      query_string:
        query: >
          destination.port:(22 OR 2222)
          AND (event.action:"deny" OR event.action:"block" OR event.action:"allow")

query_key:
  - source.ip.keyword
  - destination.ip.keyword

alert:
  - email
  - telegram
  - slack

# ── Email ────────────────────────────────────────────────────────
email:
  - "${SMTP_USER}"
from_addr: ${SMTP_USER}
smtp_host: smtp.gmail.com
smtp_port: 587
smtp_auth_file: /etc/elastalert/smtp_auth.yaml
smtp_ssl: false
smtp_starttls: true

# ── Telegram ─────────────────────────────────────────────────────
telegram_bot_token: "${TELEGRAM_BOT_TOKEN}"
telegram_room_id: "${TELEGRAM_CHAT_ID}"

# ── Slack ────────────────────────────────────────────────────────
slack_webhook_url: "${SLACK_WEBHOOK_URL}"
slack_channel_override: "#soc-alerts"
slack_username_override: "OPNsense SOC Bot"
slack_emoji_override: ":rotating_light:"
slack_msg_color: "warning"

# ── Alert content ────────────────────────────────────────────────
alert_subject: "[HIGH] SSH Brute Force Detected - {0}"
alert_subject_args:
  - source.ip

alert_text_type: alert_text_only
alert_text_args:
  - source.ip
  - destination.ip
  - num_matches
  - "@timestamp"

alert_text: |
  🔴 SOC ALERT: SSH BRUTE FORCE
  ════════════════════════════════════
  Rule      : OPNsense - SSH Brute Force Attack
  Risk Score: 73 / 100 | Severity: HIGH
  ────────────────────────────────────
  Source IP  : {0}
  Target IP  : {1}
  Port       : 22 (SSH)
  Event Count: {2}
  Timestamp  : {3}
  ────────────────────────────────────
  MITRE ATT&CK: T1110.001 (Password Guessing)
  ────────────────────────────────────
  RESPONSE STEPS:
  1. Check source IP on VirusTotal / AbuseIPDB
  2. Filter event.action:allow for successful attempts
  3. Block source IP on firewall if malicious
  4. If successful login found, review /var/log/auth.log

realert:
  minutes: 45

exponential_realert:
  hours: 4
EOF
    chown "$EA_USER:$EA_USER" "$RULE01"
    chmod 640 "$RULE01"
    ok "rule-01 (SSH Brute Force) created"
else
    ok "rule-01 already exists — skipped"
fi

# ════════════════════════════════════════════════════════════════
# 8. SYSTEMD SERVICE
# ════════════════════════════════════════════════════════════════
info "[6/9] Writing systemd service..."

if [[ ! -f "$SERVICE_FILE" ]]; then
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=ElastAlert2 - Alerting for Elasticsearch
After=network.target

[Service]
Type=simple
User=${EA_USER}
Group=${EA_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=${EA_BIN} --config ${CONFIG_FILE}
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "elastalert.service created"
else
    ok "elastalert.service already exists — skipped"
fi

systemctl enable elastalert --quiet
ok "Service enabled"

# ════════════════════════════════════════════════════════════════
# 9. WRITEBACK INDEX
# ════════════════════════════════════════════════════════════════
info "[7/9] Creating ElastAlert writeback index..."

# Run as EA_USER so it uses the same permissions as the service
if sudo -u "$EA_USER" "$EA_INDEX_BIN" \
        --config "$CONFIG_FILE" \
        --index elastalert_status \
        --old-index "" 2>&1 | grep -q "New index elastalert_status created"; then
    ok "Writeback index created"
else
    warn "Index may already exist or Elasticsearch is unreachable — continuing"
fi

# ════════════════════════════════════════════════════════════════
# 10. RULE VALIDATION
# ════════════════════════════════════════════════════════════════
info "[8/9] Validating rules..."

ERRORS=0
for rule in "$RULES_DIR"/opnsense-rule-*.yaml; do
    name="$(basename "$rule")"
    if sudo -u "$EA_USER" "$EA_TEST_BIN" \
            --config "$CONFIG_FILE" "$rule" \
            > /tmp/ea_test.log 2>&1; then
        ok "$name"
    else
        echo -e "    ${RED}✗${RESET} $name"
        tail -5 /tmp/ea_test.log | sed 's/^/        /'
        ERRORS=$((ERRORS + 1))
    fi
done
rm -f /tmp/ea_test.log

if [[ $ERRORS -gt 0 ]]; then
    die "$ERRORS rule(s) failed validation. Fix errors above before continuing."
fi

# ════════════════════════════════════════════════════════════════
# 11. START SERVICE
# ════════════════════════════════════════════════════════════════
info "[9/9] Starting elastalert service..."
systemctl restart elastalert
sleep 3

if systemctl is-active --quiet elastalert; then
    ok "elastalert is running"
else
    die "elastalert failed to start. Check: journalctl -u elastalert -n 30"
fi

# ════════════════════════════════════════════════════════════════
# 12. CRON JOB
# ════════════════════════════════════════════════════════════════
cat > "$CRON_FILE" << 'EOF'
# Restart ElastAlert2 nightly at 01:00 to rotate log handles
0 1 * * * root systemctl restart elastalert
EOF
chmod 644 "$CRON_FILE"
ok "Cron job written to $CRON_FILE"

# ════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}════════════════════════════════════════${RESET}"
echo -e "${GREEN}  ElastAlert2 installation complete!${RESET}"
echo -e "${GREEN}════════════════════════════════════════${RESET}"
echo ""
echo "  Config      : $CONFIG_FILE"
echo "  SMTP auth   : $SMTP_AUTH_FILE"
echo "  Rules       :"
ls "$RULES_DIR"/opnsense-rule-*.yaml 2>/dev/null | sed 's/^/    - /'
echo "  Service     : systemctl status elastalert"
echo "  Logs        : journalctl -u elastalert -f"
echo "  Cron        : $CRON_FILE"
echo ""
echo -e "  ${YELLOW}⚠  Keep credentials secure: chmod 600 $CREDS_FILE${RESET}"
echo ""
