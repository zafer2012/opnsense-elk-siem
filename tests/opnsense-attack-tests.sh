#!/bin/bash
# ============================================================
# OPNsense Attack Simulation Test Script
# Scope: SSH BF, RDP BF, Port Scan, DDoS,
#        SMB Lateral, TCP Flags, High Risk Country,
#        DB Port Scan
#
# Usage: ./opnsense-attack-tests.sh [option]
#   1 | ssh    → SSH Brute Force
#   2 | rdp    → RDP Brute Force
#   3 | scan   → Port Scan
#   4 | ddos   → DDoS / Traffic Flood
#   5 | smb    → SMB Lateral Movement
#   6 | flags  → Abnormal TCP Flags
#   7 | geo    → High Risk Country
#   8 | db     → Database Port Scan
#   all        → Run all in sequence
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*"; exit 1; }
header()  {
    echo ""
    echo -e "${BOLD}${CYAN}── $* ────────────────────────────────────────────────────${NC}"
}

# ── Load credentials ──────────────────────────────────────────────────────────
# FIX: read with grep instead of source — lines like KB_ENC_KEY break bash
CREDS_FILE="/root/.elk_credentials"

if [[ -f "$CREDS_FILE" ]]; then
    ES_PASS=$(grep ^ELASTIC_PASS "$CREDS_FILE" | cut -d= -f2-)
    info "Credentials file loaded: ${CREDS_FILE}"
else
    warn "Credentials file not found: ${CREDS_FILE}"
fi

ES_HOST="${ES_HOST:-https://127.0.0.1:9200}"
CACERT="/etc/elasticsearch/certs/ca.crt"

if [[ -z "${ES_PASS:-}" ]]; then
    read -rsp "Elasticsearch 'elastic' password: " ES_PASS
    echo ""
fi

# ==================== AUTO IP DETECTION ====================
# Best method: IP used by outbound traffic (most accurate)
ELK_IP=$(ip route get 8.8.8.8 | awk '{print $7}' | head -n1)

# Alternative fallback methods (if one fails):
if [[ -z "$ELK_IP" || "$ELK_IP" == "8.8.8.8" ]]; then
    ELK_IP=$(hostname -I | awk '{print $1}')
fi

if [[ -z "$ELK_IP" ]]; then
    echo "[ERROR] Could not detect IP address automatically!"
    read -rp "Enter ELK_IP address manually: " ELK_IP
fi

echo "[INFO] Auto-detected ELK_IP: $ELK_IP"
# ========================================================

ELK_PORT=5140
HOSTNAME="OPNsense.internal"
LOCAL_VICTIM="192.168.100.1"
ES_USER="elastic"
ES_PASS="${ES_PASS}"

SEQ=1  # Global sequence ID counter

RED='\033[0;31m'; YELLOW='\033[1;33m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'
NC='\033[0m'; BOLD='\033[1m'

# ============================================================
# RFC5424 FORMAT:
# <PRI>VERSION TIMESTAMP HOSTNAME PROGRAM PID - [meta sequenceId="N"] FILTERLOG_CSV
#
# Logstash CSV columns (28 columns, order matters):
# rule_number, sub_rule_number, anchor, tracker,
# interface, reason, action, direction,
# ip_version, tos, ecn, ttl, packet_id, offset, flags,
# protocol_id, protocol, length,
# src_ip, dst_ip, src_port, dst_port,
# data_length, tcp_seq, tcp_ack, tcp_window, tcp_flags, tcp_options
# ============================================================

send_log() {
  # $1 = filterlog CSV content (28 columns)
  local TIMESTAMP
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  local MSG="<134>1 $TIMESTAMP $HOSTNAME filterlog $$ - [meta sequenceId=\"$SEQ\"] $1"
  echo "$MSG" | nc -u -w0 "$ELK_IP" "$ELK_PORT"
  SEQ=$((SEQ + 1))
}

header() {
  echo ""
  echo -e "${BOLD}${CYAN}============================================${NC}"
  echo -e "${BOLD}${CYAN}  $1${NC}"
  echo -e "${BOLD}${CYAN}============================================${NC}"
}

progress() {
  if [ $(($1 % 50)) -eq 0 ] || [ $1 -eq $2 ]; then
    echo -e "  ${GREEN}→ $1 / $2 sent${NC}"
  fi
}

# -------------------------------------------------------
# 01 - SSH BRUTE FORCE
# Same src IP → port 22 → block → 15 packets
# Rule threshold: source.ip >= 10
# -------------------------------------------------------
test_ssh_bruteforce() {
  header "01 - SSH Brute Force Test"
  SRC_IP="185.220.101.$((RANDOM % 200 + 10))"
  echo -e "  Source IP : ${YELLOW}$SRC_IP${NC} (fixed)"
  echo -e "  Target    : $LOCAL_VICTIM:22"
  echo -e "  Count     : 15 packets  |  Threshold: 10"

  for i in $(seq 1 15); do
    # rule_number,sub_rule,anchor,tracker,iface,reason,action,direction,
    # ip_ver,tos,ecn,ttl,pkt_id,offset,flags,proto_id,proto,length,
    # src_ip,dst_ip,src_port,dst_port,
    # data_len,tcp_seq,tcp_ack,tcp_win,tcp_flags,tcp_opts
    send_log "1,,, ssh_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$LOCAL_VICTIM,$((RANDOM%60000+1024)),22,0,0,0,65535,S,"
    sleep 0.1
    progress $i 15
  done
  echo -e "  ${GREEN}✓ SSH Brute Force test completed${NC}"
}

# -------------------------------------------------------
# 02 - RDP BRUTE FORCE
# Same src IP → port 3389 → block → 15 packets
# Rule threshold: source.ip >= 10
# -------------------------------------------------------
test_rdp_bruteforce() {
  header "02 - RDP Brute Force Test"
  SRC_IP="91.92.$((RANDOM % 254 + 1)).$((RANDOM % 254 + 1))"
  echo -e "  Source IP : ${YELLOW}$SRC_IP${NC} (fixed)"
  echo -e "  Target    : $LOCAL_VICTIM:3389"
  echo -e "  Count     : 15 packets  |  Threshold: 10"

  for i in $(seq 1 15); do
    send_log "2,,,rdp_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$LOCAL_VICTIM,$((RANDOM%60000+1024)),3389,0,0,0,65535,S,"
    sleep 0.1
    progress $i 15
  done
  echo -e "  ${GREEN}✓ RDP Brute Force test completed${NC}"
}

# -------------------------------------------------------
# 03 - PORT SCAN
# Same src IP → 20 different ports → block
# Rule threshold: cardinality(destination.port) >= 15
# -------------------------------------------------------
test_port_scan() {
  header "03 - Port Scan Test"
  SRC_IP="45.33.32.156"
  PORTS=(21 22 23 25 53 80 110 135 139 143 443 445 1433 3306 3389 5432 6379 8080 8443 27017)
  echo -e "  Source IP : ${YELLOW}$SRC_IP${NC} (fixed)"
  echo -e "  Target    : $LOCAL_VICTIM"
  echo -e "  Ports     : ${#PORTS[@]} different ports  |  Threshold: 15"

  for PORT in "${PORTS[@]}"; do
    send_log "3,,,scan_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$LOCAL_VICTIM,$((RANDOM%60000+1024)),$PORT,0,0,0,1024,S,"
    sleep 0.05
    echo -e "  → Port ${YELLOW}$PORT${NC} sent"
  done
  echo -e "  ${GREEN}✓ Port scan test completed (${#PORTS[@]} ports)${NC}"
}

# -------------------------------------------------------
# 04 - DDoS / TRAFFIC FLOOD
# Different src IPs to a single target → 550 packets
# Rule threshold: destination.ip >= 500 hits/min
# -------------------------------------------------------
test_ddos() {
  header "04 - DDoS / Traffic Flood Test"
  VICTIM_IP="192.168.100.150"
  TOTAL=750
  echo -e "  Target IP : ${YELLOW}$VICTIM_IP${NC} (fixed)"
  echo -e "  Source    : Random public IPs"
  echo -e "  Count     : $TOTAL packets  |  Threshold: 500/min"

  PUBLIC_IPS=("8.8.8.8" "1.1.1.1" "93.184.216.34" "151.101.1.69" "185.220.101.5" "80.91.71.225" "87.250.224.226" "36.255.41.188")

  for i in $(seq 1 $TOTAL); do
    SRC_IP="${PUBLIC_IPS[$RANDOM % ${#PUBLIC_IPS[@]}]}"
    send_log "4,,,ddos_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,17,udp,100,$SRC_IP,$VICTIM_IP,$((RANDOM%60000+1024)),53,80,,,"
    progress $i $TOTAL
  done
  echo -e "  ${GREEN}✓ DDoS test completed ($TOTAL packets)${NC}"
}


# -------------------------------------------------------
# 05 - SMB LATERAL MOVEMENT
# Same src IP → port 445 → 5 different target IPs
# Rule threshold: cardinality(destination.ip) >= 3
# -------------------------------------------------------
test_smb_lateral() {
  header "05 - SMB Lateral Movement Test"
  SRC_IP="192.168.100.55"
  TARGETS=("192.168.100.10" "192.168.100.20" "192.168.100.30" "192.168.100.40" "192.168.100.50")
  echo -e "  Source IP : ${YELLOW}$SRC_IP${NC} (internal network — ransomware simulation)"
  echo -e "  Targets   : ${#TARGETS[@]} different IPs, port 445"
  echo -e "  Count     : 5 packets per target = $((${#TARGETS[@]}*5)) total  |  Threshold: 3 different IPs"

  for TARGET in "${TARGETS[@]}"; do
    for j in $(seq 1 5); do
      send_log "5,,,smb_tracker,em0,match,pass,out,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$TARGET,$((RANDOM%60000+1024)),445,0,0,0,65535,S,"
      sleep 0.1
    done
    echo -e "  → $TARGET:445 → 5 packets sent"
  done
  echo -e "  ${GREEN}✓ SMB Lateral Movement test completed${NC}"
}

# -------------------------------------------------------
# 06 - ABNORMAL TCP FLAGS
# NULL / FIN / XMAS flagged packets → 10 packets
# Logstash adds tcp_null_scan / tcp_fin_scan / tcp_xmas_scan tags
# tcp_flags values: 0x000=NULL, 0x001=FIN, 0x029=XMAS
# Rule threshold: source.ip >= 5 hits
# -------------------------------------------------------
test_tcp_flags() {
  header "06 - Abnormal TCP Flag Test"
  SRC_IP="198.51.100.$((RANDOM % 200 + 10))"
  echo -e "  Source IP : ${YELLOW}$SRC_IP${NC} (fixed)"
  echo -e "  Flags     : NULL(0x000), FIN(0x001), XMAS(0x029)"
  echo -e "  Count     : 10 packets  |  Threshold: 5"

  # Logstash config: 0x000=null_scan, 0x001=fin_scan, 0x029=xmas_scan
  FLAGS=("0x000" "0x001" "0x029" "0x000" "0x001" "0x029" "0x000" "0x001" "0x029" "0x000")
  LABELS=("NULL" "FIN" "XMAS" "NULL" "FIN" "XMAS" "NULL" "FIN" "XMAS" "NULL")

  for i in "${!FLAGS[@]}"; do
    FLAG="${FLAGS[$i]}"
    LABEL="${LABELS[$i]}"
    PORT=$((RANDOM % 1024 + 1))
    send_log "6,,,flag_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$LOCAL_VICTIM,$((RANDOM%60000+1024)),$PORT,0,0,0,1024,$FLAG,"
    echo -e "  → Packet $((i+1)): flag=${YELLOW}$LABEL${NC} ($FLAG) target port=$PORT"
    sleep 0.2
  done
  echo -e "  ${GREEN}✓ TCP Flag test completed${NC}"
}

# -------------------------------------------------------
# 07 - HIGH RISK COUNTRY
# Real foreign IPs → country detection via GeoIP lookup
# Rule threshold: source.ip >= 3 + country match
# NOTE: GeoLite2 DB must be active
# -------------------------------------------------------
test_high_risk_country() {
  header "07 - High Risk Country Test"
  echo -e "  ${YELLOW}NOTE: GeoLite2 DB must be active and up to date${NC}"

  declare -A COUNTRY_IPS
  COUNTRY_IPS["RU-Russia"]="77.88.8.8"
  COUNTRY_IPS["CN-China"]="223.5.5.5"
  COUNTRY_IPS["IR-Iran"]="5.160.0.1"
  COUNTRY_IPS["BY-Belarus"]="178.172.2.1"
  COUNTRY_IPS["SY-Syria"]="94.188.164.1"

  for LABEL in "${!COUNTRY_IPS[@]}"; do
    SRC_IP="${COUNTRY_IPS[$LABEL]}"
    for j in $(seq 1 5); do
      # UDP packet
      send_log "7,,,geo_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,17,udp,60,$SRC_IP,$LOCAL_VICTIM,$((RANDOM%50000+1024)),80,40,,,"
      sleep 0.1
    done
    echo -e "  → ${YELLOW}$LABEL${NC} ($SRC_IP): 5 packets sent"
  done
  echo -e "  ${GREEN}✓ High risk country test completed${NC}"
}

# -------------------------------------------------------
# 08 - DATABASE PORT SCAN
# Same src IP → 8 different DB ports
# Rule threshold: cardinality(destination.port) >= 3
# -------------------------------------------------------
test_db_port_scan() {
  header "08 - Database Port Scan Test"
  SRC_IP="203.0.113.$((RANDOM % 200 + 10))"
  DB_PORTS=(1433 3306 5432 6379 27017 9200 5984 9042)
  echo -e "  Source IP : ${YELLOW}$SRC_IP${NC} (fixed)"
  echo -e "  DB Ports  : ${DB_PORTS[*]}"
  echo -e "  Threshold : cardinality(destination.port) >= 3"

  declare -A PORT_NAMES
  PORT_NAMES[1433]="MSSQL"    PORT_NAMES[3306]="MySQL"
  PORT_NAMES[5432]="PostgreSQL" PORT_NAMES[6379]="Redis"
  PORT_NAMES[27017]="MongoDB" PORT_NAMES[9200]="Elasticsearch"
  PORT_NAMES[5984]="CouchDB"  PORT_NAMES[9042]="Cassandra"

  for PORT in "${DB_PORTS[@]}"; do
    send_log "8,,,db_tracker,em0,match,block,in,4,0x0,,64,0,0,DF,6,tcp,60,$SRC_IP,$LOCAL_VICTIM,$((RANDOM%60000+1024)),$PORT,0,0,0,1024,S,"
    echo -e "  → Port ${YELLOW}$PORT${NC} (${PORT_NAMES[$PORT]}) sent"
    sleep 0.1
  done
  echo -e "  ${GREEN}✓ Database port scan test completed${NC}"
}

# -------------------------------------------------------
# INDEX CHECK
# -------------------------------------------------------
check_index() {
  echo ""
  echo -e "${BOLD}Index check:${NC}"
  COUNT=$(curl -s "http://$ELK_IP:9200/opnsense-syslog-*/_count" \
    -u "$ES_USER:$ES_PASS" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('count','?'))" 2>/dev/null)
  echo -e "  opnsense-syslog-* total records: ${GREEN}$COUNT${NC}"
  echo -e "  ${CYAN}Kibana → Security → Alerts → wait 1-2 min${NC}"
}

# -------------------------------------------------------
# MENU
# -------------------------------------------------------
case "${1:-help}" in
  1|ssh)   test_ssh_bruteforce ;;
  2|rdp)   test_rdp_bruteforce ;;
  3|scan)  test_port_scan ;;
  4|ddos)  test_ddos ;;
  5|smb)   test_smb_lateral ;;
  6|flags) test_tcp_flags ;;
  7|geo)   test_high_risk_country ;;
  8|db)    test_db_port_scan ;;
  all)
    test_ssh_bruteforce;    sleep 3
    test_rdp_bruteforce;    sleep 3
    test_port_scan;         sleep 3
    test_ddos;              sleep 3
    test_smb_lateral;       sleep 3
    test_tcp_flags;         sleep 3
    test_high_risk_country; sleep 3
    test_db_port_scan
    ;;
  *)
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [option]"
    echo ""
    echo -e "  ${YELLOW}1${NC}  | ssh    → SSH Brute Force         (threshold: 10 hits)"
    echo -e "  ${YELLOW}2${NC}  | rdp    → RDP Brute Force         (threshold: 10 hits)"
    echo -e "  ${YELLOW}3${NC}  | scan   → Port Scan               (threshold: 15 different ports)"
    echo -e "  ${YELLOW}4${NC}  | ddos   → DDoS / Traffic Flood    (threshold: 500 hits/min)"
    echo -e "  ${YELLOW}5${NC}  | smb    → SMB Lateral Movement    (threshold: 3 different target IPs)"
    echo -e "  ${YELLOW}6${NC}  | flags  → Abnormal TCP Flags      (threshold: 5 hits)"
    echo -e "  ${YELLOW}7${NC}  | geo    → High Risk Country       (threshold: 3 hits + country match)"
    echo -e "  ${YELLOW}8${NC}  | db     → Database Port Scan      (threshold: 3 different DB ports)"
    echo -e "  ${YELLOW}all${NC}        → Run all in sequence"
    echo ""
    exit 0
    ;;
esac

check_index