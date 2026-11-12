#!/bin/bash
# ============================================================
# Negative Traffic Test (False Positive / True Negative Measurement)
# Purpose: Measure whether ElastAlert2 rules trigger FALSELY
#          under normal/benign traffic.
# Duration: 24 hours recommended (configurable via parameter)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

CREDS_FILE="/root/.elk_credentials"
if [[ -f "$CREDS_FILE" ]]; then
    ES_PASS=$(grep ^ELASTIC_PASS "$CREDS_FILE" | cut -d= -f2-)
fi
ELK_IP=$(ip route get 8.8.8.8 | awk '{print $7}' | head -n1)
ELK_PORT=5140
HOSTNAME="OPNsense.internal"
VICTIM_IP="192.168.100.1"
SEQ=90000

DURATION_HOURS=${1:-24}   # Default 24 hours, configurable via parameter
END_TIME=$(( $(date +%s) + DURATION_HOURS * 3600 ))

echo "[INFO] Negative traffic test started. Duration: ${DURATION_HOURS} hour(s)"
echo "[INFO] End time: $(date -d @$END_TIME)"

send_log() {
  local TIMESTAMP
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  local MSG="<134>1 $TIMESTAMP $HOSTNAME filterlog $$ - [meta sequenceId=\"$SEQ\"] $1"
  echo "$MSG" | nc -u -w0 "$ELK_IP" "$ELK_PORT"
  SEQ=$((SEQ + 1))
}

# ------------------------------------------------------------
# Scenario 1: Normal SSH/RDP login (valid credentials, infrequent)
# ------------------------------------------------------------
normal_auth_traffic() {
  SRC_IP="192.168.100.$((RANDOM%50+10))"
  PORT=$([ $((RANDOM%2)) -eq 0 ] && echo 22 || echo 3389)
  # Single packet, action=pass (simulates successful login)
  send_log "0,,,normal_auth,em0,match,pass,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),$PORT,0,0,0,65535,S,"
}

# ------------------------------------------------------------
# Scenario 2: Normal web/port access (human-paced, small number of ports)
# ------------------------------------------------------------
normal_web_traffic() {
  SRC_IP="192.168.100.$((RANDOM%50+10))"
  PORTS=(80 443 22)
  PORT=${PORTS[$((RANDOM%3))]}
  send_log "0,,,normal_web,em0,match,pass,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),$PORT,0,0,0,65535,S,"
}

# ------------------------------------------------------------
# Scenario 3: Normal TCP handshake (SYN, normal flag)
# ------------------------------------------------------------
normal_tcp_handshake() {
  SRC_IP="192.168.100.$((RANDOM%50+10))"
  send_log "0,,,normal_tcp,em0,match,pass,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),80,0,0,0,65535,S,"
}

# ------------------------------------------------------------
# Scenario 4: Normal access from a low-risk country (GeoIP negative)
# ------------------------------------------------------------
normal_geo_traffic() {
  # Local/low-risk country IPs (e.g., Turkey, Germany, US ranges)
  LOW_RISK_IPS=("88.255.$((RANDOM%254+1)).$((RANDOM%254+1))" "85.111.$((RANDOM%254+1)).$((RANDOM%254+1))" "212.156.$((RANDOM%254+1)).$((RANDOM%254+1))")
  SRC_IP=${LOW_RISK_IPS[$((RANDOM%3))]}
  send_log "0,,,normal_geo,em0,match,pass,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),443,0,0,0,65535,S,"
}

# ------------------------------------------------------------
# Scenario 5: Repeated normal SMB access to the same target (lateral movement negative)
# ------------------------------------------------------------
normal_smb_traffic() {
  SRC_IP="192.168.100.$((RANDOM%50+10))"
  # ALWAYS to the exact same single target (so it does not exceed the cardinality threshold)
  send_log "0,,,normal_smb,em0,match,pass,out,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),445,0,0,0,65535,S,"
}

# ------------------------------------------------------------
# Scenario 6: Gradual/low-volume daily traffic fluctuation (spike negative)
# ------------------------------------------------------------
normal_gradual_increase() {
  SRC_IP="192.168.100.$((RANDOM%50+10))"
  PORT=$([ $((RANDOM%2)) -eq 0 ] && echo 80 || echo 443)
  send_log "0,,,normal_gradual,em0,match,pass,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),$PORT,0,0,0,65535,S,"
}

# ============================================================
# MAIN LOOP
# ============================================================
EVENT_COUNT=0
while [ "$(date +%s)" -lt "$END_TIME" ]; do

  # Select a random scenario (weighted: normal_web and normal_gradual more frequent)
  R=$((RANDOM % 100))
  if   [ $R -lt 10 ]; then normal_auth_traffic
  elif [ $R -lt 35 ]; then normal_web_traffic
  elif [ $R -lt 50 ]; then normal_tcp_handshake
  elif [ $R -lt 65 ]; then normal_geo_traffic
  elif [ $R -lt 80 ]; then normal_smb_traffic
  else normal_gradual_increase
  fi

  EVENT_COUNT=$((EVENT_COUNT+1))
  if [ $((EVENT_COUNT % 50)) -eq 0 ]; then
    info "Events sent: $EVENT_COUNT | Remaining time: $(( (END_TIME - $(date +%s)) / 60 )) min"
  fi

  # Human-like random interval: between 10-90 seconds
  sleep $((RANDOM % 80 + 10))
done

success "Negative traffic test completed. Total events sent: $EVENT_COUNT"
echo ""
echo "Now run the check_false_positives.sh script to analyze the results."