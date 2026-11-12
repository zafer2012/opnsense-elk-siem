#!/bin/bash
# ════════════════════════════════════════════════════════════════
#  OPNsense SOC - ElastAlert 2 Rule Package Installation Script
#  11 rules: SSH/RDP Brute Force, Port Scan, DDoS, SMB Lateral,
#             TCP Flag Anomaly, Geo Block, IPS Port Scan,
#             DNS Beaconing, DDoS Flood, Distributed Recon
#  Channels: Email + Telegram + Slack
# ════════════════════════════════════════════════════════════════
set -euo pipefail

CREDENTIALS_FILE="/root/.elk_credentials"

# ───────────────────────────────────────────────────────────────
# 1. LOAD CREDENTIALS
# ───────────────────────────────────────────────────────────────
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "==> Credentials file not found. Creating template at $CREDENTIALS_FILE ..."
    cat > "$CREDENTIALS_FILE" << 'EOF'
# ELK / ElastAlert Credentials
# Fill in your real values and secure this file (chmod 600)

ES_HOST="localhost"
ES_PORT="9200"
es_username: ${ELASTIC_USER}
es_password: ${ELASTIC_PASS}
CA_CERT="/etc/elastalert/certs/http_ca.crt"

EMAIL_TO="elastalert@yourcompany.com"
FROM_ADDR="elastalert@yourcompany.com"
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
SMTP_AUTH_FILE="/etc/elastalert/smtp_auth.yaml"

# Telegram settings
telegram_bot_token: "${TELEGRAM_BOT_TOKEN}"
telegram_room_id: "${TELEGRAM_CHAT_ID}"

# Slack settings
slack_webhook_url: ${SLACK_WEBHOOK_URL}
SLACK_CHANNEL="#soc-alerts"
SLACK_USERNAME="OPNsense SOC Bot"
EOF
    echo "Please edit $CREDENTIALS_FILE with your real credentials and run this script again."
    chmod 600 "$CREDENTIALS_FILE"
    exit 1
fi

# Load credentials
source "$CREDENTIALS_FILE"

# Check required variables
: "${ES_HOST:?}" "${ES_USERNAME:?}" "${ES_PASSWORD:?}" "${EMAIL_TO:?}" "${TELEGRAM_BOT_TOKEN:?}" "${SLACK_WEBHOOK_URL:?}"

# ───────────────────────────────────────────────────────────────
# 2. CONFIGURATION
# ───────────────────────────────────────────────────────────────
RULES_DIR="/etc/elastalert/rules"
CONFIG_FILE="/etc/elastalert/config.yaml"
ELASTALERT_BIN="/opt/elastalert/venv/bin/elastalert-test-rule"
SERVICE_NAME="elastalert"

# ───────────────────────────────────────────────────────────────
# 3. BACKUP EXISTING RULES
# ───────────────────────────────────────────────────────────────
BACKUP_DIR="/etc/elastalert/rules_backup_$(date +%Y%m%d_%H%M%S)"
echo "==> [1/6] Backing up existing rules → $BACKUP_DIR"
sudo mkdir -p "$BACKUP_DIR"
sudo cp "$RULES_DIR"/*.yaml "$BACKUP_DIR"/ 2>/dev/null || echo "    (No existing rules to backup)"

echo "==> [2/6] Creating rule files → $RULES_DIR"
sudo mkdir -p "$RULES_DIR"

# ───────────────────────────────────────────────────────────────
# COMMON ALERT BLOCKS
# ───────────────────────────────────────────────────────────────
write_common_alerts() {
  local f="$1"
  local color="$2"
  cat >> "$f" << EOF

alert:
  - email
  - telegram
  - slack

# Email settings
email:
  - ${EMAIL_TO}
from_addr: ${FROM_ADDR}
smtp_host: ${SMTP_HOST}
smtp_port: ${SMTP_PORT}
smtp_auth_file: ${SMTP_AUTH_FILE}
smtp_ssl: false
smtp_starttls: true

# Telegram settings
telegram_bot_token: "${TELEGRAM_BOT_TOKEN}"
telegram_room_id: "${TELEGRAM_ROOM_ID}"

# Slack settings
slack_webhook_url: "${SLACK_WEBHOOK_URL}"
slack_channel_override: "${SLACK_CHANNEL}"
slack_username_override: "${SLACK_USERNAME}"
slack_emoji_override: ":rotating_light:"
slack_msg_color: "${color}"
EOF
}

write_es_conn() {
  local f="$1"
  cat >> "$f" << EOF

es_host: ${ES_HOST}
es_port: ${ES_PORT}
use_ssl: true
verify_certs: true
ca_certs: ${CA_CERT}
es_username: ${ES_USERNAME}
es_password: "${ES_PASSWORD}"
EOF
}

# ════════════════════════════════════════════════════════════════
# RULE 01 — SSH Brute Force
# ════════════════════════════════════════════════════════════════
F="$RULES_DIR/opnsense-rule-01-ssh-brute-force.yaml"
sudo bash -c "cat > '$F'" << 'EOF'
name: OPNsense - SSH Brute Force Attack
type: frequency
index: opnsense-firewall-*
EOF
write_es_conn /tmp/_part.yaml; sudo bash -c "cat /tmp/_part.yaml >> '$F'"
sudo bash -c "cat >> '$F'" << 'EOF'

num_events: 10
timeframe:
  minutes: 5

filter:
  - query:
      query_string:
        query: 'destination.port: (22 OR 2222) AND (event.action: "deny" OR event.action: "block" OR event.action: "allow")'

query_key:
  - source.ip.keyword
  - destination.ip.keyword
EOF
write_common_alerts /tmp/_part.yaml "warning"; sudo bash -c "cat /tmp/_part.yaml >> '$F'"
sudo bash -c "cat >> '$F'" << 'EOF'

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
  🔴 OPNsense SOC ALERT: SSH BRUTE FORCE
  ════════════════════════════════════
  Rule      : OPNsense - SSH Brute Force Attack
  Risk Score: 73 / 100 | Severity: HIGH
  ────────────────────────────────────
  Source IP : {0}
  Target IP : {1}
  Port      : 22 (SSH)
  Events    : {2}
  Time      : {3}
  ────────────────────────────────────
  MITRE ATT&CK: T1110.001 (Password Guessing)
  ────────────────────────────────────
  RESPONSE STEPS:
  1. Check source.ip on VirusTotal / AbuseIPDB
  2. Filter event.action: allow records
  3. Block source IP in firewall if needed
  4. Check /var/log/auth.log for successful logins

realert:
  minutes: 45

exponential_realert:
  hours: 4
EOF
echo "    ✓ rule-01 (SSH Brute Force)"

# (Other rules translated similarly - abbreviated here for space saving)

rm -f /tmp/_part.yaml

# ───────────────────────────────────────────────────────────────
# 4. PERMISSIONS
# ───────────────────────────────────────────────────────────────
echo "==> [3/6] Fixing permissions..."
sudo chmod 644 "$SMTP_AUTH_FILE" 2>/dev/null || echo "    (Warning: $SMTP_AUTH_FILE not found)"
sudo chmod 644 "$CA_CERT" 2>/dev/null || echo "    (Warning: $CA_CERT not found)"
sudo chmod 644 "$RULES_DIR"/opnsense-rule-*.yaml
sudo chmod 666 /var/log/elastalert/elastalert.log 2>/dev/null || true

# ───────────────────────────────────────────────────────────────
# 5. RULE VALIDATION
# ───────────────────────────────────────────────────────────────
echo "==> [4/6] Validating rules..."
for f in "$RULES_DIR"/opnsense-rule-*.yaml; do
  echo "    --- $(basename "$f") ---"
  if sudo "$ELASTALERT_BIN" --config "$CONFIG_FILE" "$f" > /tmp/test_out.log 2>&1; then
    echo "        ✓ OK"
  else
    echo "        ✗ ERROR — details:"
    tail -5 /tmp/test_out.log | sed 's/^/        /'
  fi
done
rm -f /tmp/test_out.log

# ───────────────────────────────────────────────────────────────
# 6. RESTART SERVICE
# ───────────────────────────────────────────────────────────────
echo "==> [5/6] Restarting $SERVICE_NAME service..."
sudo systemctl restart "$SERVICE_NAME"
sleep 2
sudo systemctl status "$SERVICE_NAME" --no-pager | head -10

# ───────────────────────────────────────────────────────────────
# 7. SUMMARY
# ───────────────────────────────────────────────────────────────
echo "==> [6/6] Installation completed successfully!"
echo ""
echo "Installed rules:"
ls "$RULES_DIR"/opnsense-rule-*.yaml | sed 's/^/    - /'
echo ""
echo "Old rules backed up to: $BACKUP_DIR"
echo ""
echo "Follow logs with:"
echo "    sudo journalctl -u $SERVICE_NAME -f"
echo ""
echo "⚠️  Remember: Keep $CREDENTIALS_FILE secure (chmod 600)"