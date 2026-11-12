#!/usr/bin/env bash
# =============================================================================
#  ELK Stack 9.x — Full Uninstall (Single Script)
#  Scope   : Services → Packages → Certificates → Config → Data → UFW → Summary
#  Usage   : sudo bash uninstall_elk.sh
#
#  WARNING : This script permanently deletes all ELK data, certificates,
#            and configuration files!
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $*${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

[[ $EUID -ne 0 ]] && error "Root privileges required. Run with 'sudo bash $0'."

LOG_FILE="/var/log/elk_uninstall_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Uninstall log: $LOG_FILE"

# ──────────────────────────────────────────────────────────────────────────────
# CONFIRMATION
# ──────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${RED}"
echo "  ██╗   ██╗ █████╗ ██████╗ ██╗  ██╗██╗███╗   ██╗  ██████╗  ██╗"
echo "  ██║   ██║██╔══██╗██╔══██╗██║  ██║██║████╗  ██║ ██╔════╝ ███║"
echo "  ██║   ██║███████║██████╔╝███████║██║██╔██╗ ██║ ██║  ███╗╚██║"
echo "  ██║   ██║██╔══██║██╔══██╗██╔══██║██║██║╚██╗██║ ██║   ██║ ██║"
echo "  ╚██████╔╝██║  ██║██║  ██║██║  ██║██║██║ ╚████║ ╚██████╔╝ ██║"
echo "   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝  ╚═════╝  ╚═╝"
echo -e "${NC}"
echo -e "${BOLD}${RED}  WARNING: This action cannot be undone!${NC}"
echo -e "  The following will be permanently removed:"
echo -e "    • Elasticsearch, Kibana, Logstash packages and all data"
echo -e "    • /etc/elasticsearch, /etc/kibana, /etc/logstash"
echo -e "    • /var/lib/elasticsearch, /var/log/elasticsearch"
echo -e "    • /var/log/kibana, /var/log/logstash"
echo -e "    • /etc/elasticsearch/certs, /etc/kibana/certs, /etc/logstash/certs"
echo -e "    • /usr/local/share/ca-certificates/elk-ca.crt"
echo -e "    • /etc/sysctl.d/99-elasticsearch.conf"
echo -e "    • /etc/systemd/system/elasticsearch.service.d/"
echo -e "    • /root/.elk_credentials"
echo -e "    • UFW ELK rules"
echo ""

# Flags
PURGE_DATA=true
CONFIGURE_UFW=true

# Parse command-line arguments
for arg in "$@"; do
    case $arg in
        --keep-data)   PURGE_DATA=false ;;
        --no-ufw)      CONFIGURE_UFW=false ;;
        --yes|-y)      CONFIRMED=true ;;
    esac
done

if [[ "${CONFIRMED:-false}" != "true" ]]; then
    echo -ne "${BOLD}${RED}  Do you want to continue? [yes/NO]: ${NC}"
    read -r CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        info "Operation cancelled."
        exit 0
    fi
fi

echo ""
info "Starting uninstall..."

# ──────────────────────────────────────────────────────────────────────────────
# 1. STOP AND DISABLE SERVICES
# ──────────────────────────────────────────────────────────────────────────────
header "1/7 · Stopping Services"

for SVC in logstash kibana elasticsearch; do
    if systemctl list-units --full -all 2>/dev/null | grep -q "${SVC}.service"; then
        info "Stopping ${SVC}..."
        systemctl stop    "$SVC" 2>/dev/null || true
        systemctl disable "$SVC" 2>/dev/null || true
        success "${SVC} stopped."
    else
        info "${SVC} service not found, skipping."
    fi
done

# Force-kill any remaining child processes
pkill -f logstash       2>/dev/null || true
pkill -f elasticsearch  2>/dev/null || true
pkill -f kibana         2>/dev/null || true
sleep 3

success "All ELK services stopped."

# ──────────────────────────────────────────────────────────────────────────────
# 2. REMOVE PACKAGES
# ──────────────────────────────────────────────────────────────────────────────
header "2/7 · Removing Packages"

export DEBIAN_FRONTEND=noninteractive

for PKG in logstash kibana elasticsearch; do
    if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
        info "Purging ${PKG}..."
        apt-get purge -y -qq "$PKG" 2>/dev/null || true
        success "${PKG} removed."
    else
        info "${PKG} is not installed, skipping."
    fi
done

apt-get autoremove -y -qq 2>/dev/null || true
apt-get autoclean  -y -qq 2>/dev/null || true

success "Packages removed."

# ──────────────────────────────────────────────────────────────────────────────
# 3. REMOVE APT REPO AND GPG KEY
# ──────────────────────────────────────────────────────────────────────────────
header "3/7 · Removing APT Repository and GPG Key"

# Remove all elastic repo list files
find /etc/apt/sources.list.d/ -name "elastic-*.list" -delete 2>/dev/null && \
    success "Elastic APT repository removed." || \
    info "Elastic APT repository not found."

# Remove GPG keyring
KEYRING="/usr/share/keyrings/elasticsearch-keyring.gpg"
if [[ -f "$KEYRING" ]]; then
    rm -f "$KEYRING"
    success "GPG key removed."
else
    info "GPG key not found."
fi

apt-get update -qq 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# 4. CERTIFICATES AND CONFIGURATION FILES
# ──────────────────────────────────────────────────────────────────────────────
header "4/7 · Removing Certificates and Configuration Files"

# Remove ELK CA from system trust store
if [[ -f /usr/local/share/ca-certificates/elk-ca.crt ]]; then
    rm -f /usr/local/share/ca-certificates/elk-ca.crt
    update-ca-certificates --fresh &>/dev/null || true
    success "ELK CA certificate removed from system trust store."
fi

# Configuration directories
CONF_DIRS=(
    /etc/elasticsearch
    /etc/kibana
    /etc/logstash
    /etc/systemd/system/elasticsearch.service.d
    /etc/sysctl.d/99-elasticsearch.conf
)

for PATH_ITEM in "${CONF_DIRS[@]}"; do
    if [[ -e "$PATH_ITEM" ]]; then
        rm -rf "$PATH_ITEM"
        success "Removed: ${PATH_ITEM}"
    else
        info "Not found, skipping: ${PATH_ITEM}"
    fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 5. DATA AND LOG DIRECTORIES
# ──────────────────────────────────────────────────────────────────────────────
header "5/7 · Cleaning Data and Log Directories"

if [[ "${PURGE_DATA}" == "true" ]]; then
    DATA_DIRS=(
        /var/lib/elasticsearch
        /var/lib/kibana
        /var/lib/logstash
        /var/log/elasticsearch
        /var/log/kibana
        /var/log/logstash
        /tmp/logstash-*
        /tmp/elasticsearch-*
    )

    for PATH_ITEM in "${DATA_DIRS[@]}"; do
        # Expand glob patterns
        for EXPANDED in $PATH_ITEM; do
            if [[ -e "$EXPANDED" ]]; then
                rm -rf "$EXPANDED"
                success "Removed: ${EXPANDED}"
            fi
        done
    done
else
    warn "--keep-data flag is active: data directories will be preserved."
    warn "  /var/lib/elasticsearch, /var/lib/kibana, /var/lib/logstash"
fi

# Remove credentials file
if [[ -f /root/.elk_credentials ]]; then
    rm -f /root/.elk_credentials
    success "Credentials file removed: /root/.elk_credentials"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 6. REVERT SYSTEM SETTINGS
# ──────────────────────────────────────────────────────────────────────────────
header "6/7 · Reverting System Settings"

# Remove elasticsearch sysctl config
if [[ -f /etc/sysctl.d/99-elasticsearch.conf ]]; then
    rm -f /etc/sysctl.d/99-elasticsearch.conf
fi

# Restore default vm.max_map_count
sysctl -w vm.max_map_count=65530 &>/dev/null || true
success "vm.max_map_count restored to default (65530)."

# Reload systemd
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
success "systemd reloaded."

# ──────────────────────────────────────────────────────────────────────────────
# 7. REMOVE UFW RULES
# ──────────────────────────────────────────────────────────────────────────────
header "7/7 · Removing UFW ELK Rules"

if [[ "${CONFIGURE_UFW}" == "true" ]]; then
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then

        ELK_PORTS=(9200 5601 5044 5140)

        for PORT in "${ELK_PORTS[@]}"; do
            # TCP rule
            ufw delete allow "${PORT}/tcp" &>/dev/null && \
                success "UFW rule removed: ${PORT}/tcp" || true
            # UDP rule (syslog)
            ufw delete allow "${PORT}/udp" &>/dev/null && \
                success "UFW rule removed: ${PORT}/udp" || true
        done

        success "UFW ELK rules cleaned up."
        info "Current UFW status:"
        ufw status verbose
    else
        info "UFW is not active or not found, skipping."
    fi
else
    warn "--no-ufw flag is active: UFW rules will be preserved."
fi

# ──────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        ELK STACK SUCCESSFULLY UNINSTALLED                   ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Removed packages  : elasticsearch, kibana, logstash"
echo -e "${BOLD}${GREEN}║${NC}  APT repository    : /etc/apt/sources.list.d/elastic-*.list"
echo -e "${BOLD}${GREEN}║${NC}  GPG key           : /usr/share/keyrings/elasticsearch-keyring.gpg"
echo -e "${BOLD}${GREEN}║${NC}  Certificates      : /etc/elasticsearch/certs"
echo -e "${BOLD}${GREEN}║${NC}                     /etc/kibana/certs"
echo -e "${BOLD}${GREEN}║${NC}                     /etc/logstash/certs"
echo -e "${BOLD}${GREEN}║${NC}  System CA         : /usr/local/share/ca-certificates/elk-ca.crt"

if [[ "${PURGE_DATA}" == "true" ]]; then
echo -e "${BOLD}${GREEN}║${NC}  Data directories  : ${RED}Removed${NC}"
else
echo -e "${BOLD}${GREEN}║${NC}  Data directories  : ${YELLOW}Preserved (--keep-data)${NC}"
fi

echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Uninstall log     : ${LOG_FILE}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

success "ELK Stack has been successfully removed."
echo ""
info "To check for any remaining files:"
echo "  find /etc /var /usr -name '*elastic*' -o -name '*kibana*' -o -name '*logstash*' 2>/dev/null | grep -v proc"
