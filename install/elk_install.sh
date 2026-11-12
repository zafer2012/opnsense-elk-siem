#!/usr/bin/env bash
# =============================================================================
#  ELK Stack 9.x — Full Installation (Single Script)
#  Scope  : APT repo → Certificates → Elasticsearch → Password reset
#           → Kibana → Logstash → OPNsense Pipeline → UFW → Summary
#  Run    : sudo bash elk_install.sh
# =============================================================================

set -euo pipefail
set +e   # ignore apt-get update errors

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

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
ELK_VERSION=""   # If left empty, the latest version from the APT repo is installed
                 # For a specific version, e.g.: "8.17.6" or "9.0.1"

ES_HEAP="1g"
ES_PORT=9200
KB_PORT=5601
LS_BEATS_PORT=5044
LS_SYSLOG_PORT=5140
LS_HEAP="512m"

CERT_COUNTRY="TR"
CERT_STATE="Mersin"
CERT_CITY="Mersin"
CERT_ORG="ELK"
CERT_DAYS=3650

CERTS_DIR="/etc/elasticsearch/certs"
DEPLOY_OPNSENSE_PIPELINE=true
GEOIP_DB="/etc/logstash/geoip/GeoLite2-City.mmdb"
CONFIGURE_UFW=true

LOG_FILE="/var/log/elk_install_$(date +%Y%m%d_%H%M%S).log"
CREDS_FILE="/root/.elk_credentials"

exec > >(tee -a "$LOG_FILE") 2>&1
info "Installation log: $LOG_FILE"

# ──────────────────────────────────────────────────────────────────────────────
# 1. PREREQUISITES
# ──────────────────────────────────────────────────────────────────────────────
header "1/8 · System Prerequisites"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null || true
apt-get install -y -qq \
    curl ca-certificates gnupg openssl \
    net-tools jq apt-transport-https \
    software-properties-common lsb-release ufw

success "Prerequisites satisfied."

# ──────────────────────────────────────────────────────────────────────────────
# 2. APT REPO + PACKAGE INSTALLATION
# ──────────────────────────────────────────────────────────────────────────────
header "2/8 · Adding APT Repo and Installing Packages"

KEYRING="/usr/share/keyrings/elasticsearch-keyring.gpg"
if [[ ! -f "$KEYRING" ]]; then
    info "Downloading Elastic GPG key..."
    curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
        | gpg --dearmor -o "$KEYRING"
fi

if [[ -z "${ELK_VERSION}" ]]; then
    REPO_MAJOR="9.x"
else
    REPO_MAJOR="${ELK_VERSION%%.*}.x"
fi

info "Adding Elastic APT repo (${REPO_MAJOR})..."
rm -f /etc/apt/sources.list.d/elastic-*.list 2>/dev/null || true
echo "deb [signed-by=${KEYRING}] https://artifacts.elastic.co/packages/${REPO_MAJOR}/apt stable main" \
    > /etc/apt/sources.list.d/elastic-${REPO_MAJOR}.list

apt-get update -qq 2>/dev/null || true

if [[ -z "${ELK_VERSION}" ]]; then
    PKG_VERSION=""
    info "Version to install: latest (from APT repo)"
else
    PKG_VERSION="=${ELK_VERSION}"
    info "Version to install: ${ELK_VERSION}"
fi

for PKG in elasticsearch kibana logstash; do
    if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
        INSTALLED=$(dpkg -l "$PKG" | grep "^ii" | awk '{print $3}')
        if [[ -z "${ELK_VERSION}" || "$INSTALLED" == *"${ELK_VERSION}"* ]]; then
            info "${PKG} already installed (${INSTALLED}), skipping."
            continue
        fi
    fi
    info "Installing ${PKG}..."
    apt-get install -y -qq "${PKG}${PKG_VERSION}"
    success "${PKG} installed."
done

systemctl daemon-reload
for SVC in elasticsearch kibana logstash; do
    systemctl stop    "$SVC" &>/dev/null || true
    systemctl disable "$SVC" &>/dev/null || true
done

ES_INSTALLED=$(dpkg -l elasticsearch | grep "^ii" | awk '{print $3}')
success "Elasticsearch ${ES_INSTALLED} installed."

# ──────────────────────────────────────────────────────────────────────────────
# 3. TLS CERTIFICATES
# ──────────────────────────────────────────────────────────────────────────────
header "3/8 · TLS Certificates"

mkdir -p "$CERTS_DIR"
HOST_IP=$(hostname -I | awk '{print $1}')
FQDN=$(hostname -f 2>/dev/null || hostname)

# CA
if [[ ! -f "${CERTS_DIR}/ca.crt" ]] || \
   ! openssl x509 -checkend 86400 -noout -in "${CERTS_DIR}/ca.crt" &>/dev/null; then
    info "Generating CA certificate..."
    openssl genrsa -out "${CERTS_DIR}/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes \
        -key "${CERTS_DIR}/ca.key" -sha256 -days "${CERT_DAYS}" \
        -subj "/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/CN=ELK-CA" \
        -out "${CERTS_DIR}/ca.crt"
    success "CA certificate generated."
else
    info "Valid CA certificate exists, skipping."
fi

# SAN config — add all IPs (including Tailscale/VPN)
SAN_CNF=$(mktemp /tmp/es_san_XXXXXX.cnf)
cat > "$SAN_CNF" <<SANCNF
[req]
req_extensions     = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${FQDN}
DNS.2 = localhost
IP.1  = ${HOST_IP}
IP.2  = 127.0.0.1
SANCNF

IP_IDX=3
while IFS= read -r ip; do
    if [[ "$ip" != "$HOST_IP" && "$ip" != "127.0.0.1" ]]; then
        echo "IP.${IP_IDX}  = ${ip}" >> "$SAN_CNF"
        (( IP_IDX++ )) || true
    fi
done < <(hostname -I | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

info "SAN config:"
cat "$SAN_CNF"

for CERT in elasticsearch kibana; do
    if [[ -f "${CERTS_DIR}/${CERT}.crt" ]] && \
       openssl x509 -checkend 86400 -noout -in "${CERTS_DIR}/${CERT}.crt" &>/dev/null; then
        info "${CERT} certificate is valid, skipping."
        continue
    fi
    info "Generating ${CERT} certificate..."
    openssl genrsa -out "${CERTS_DIR}/${CERT}.key" 2048 2>/dev/null
    openssl req -new -key "${CERTS_DIR}/${CERT}.key" \
        -subj "/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORG}/CN=${FQDN}" \
        -out "/tmp/${CERT}.csr"
    if [[ "$CERT" == "elasticsearch" ]]; then
        openssl x509 -req -in "/tmp/${CERT}.csr" \
            -CA "${CERTS_DIR}/ca.crt" -CAkey "${CERTS_DIR}/ca.key" -CAcreateserial \
            -out "${CERTS_DIR}/${CERT}.crt" -days "${CERT_DAYS}" -sha256 \
            -extfile "$SAN_CNF" -extensions v3_req 2>/dev/null
    else
        openssl x509 -req -in "/tmp/${CERT}.csr" \
            -CA "${CERTS_DIR}/ca.crt" -CAkey "${CERTS_DIR}/ca.key" -CAcreateserial \
            -out "${CERTS_DIR}/${CERT}.crt" -days "${CERT_DAYS}" -sha256 2>/dev/null
    fi
    success "${CERT} certificate generated."
done

rm -f "$SAN_CNF" /tmp/elasticsearch.csr /tmp/kibana.csr
chmod 640 "${CERTS_DIR}"/*.key "${CERTS_DIR}"/*.crt
chown -R root:elasticsearch "${CERTS_DIR}"

cp "${CERTS_DIR}/ca.crt" /usr/local/share/ca-certificates/elk-ca.crt
update-ca-certificates -f &>/dev/null

# Avoid conflicts with p12 files generated by Elasticsearch itself
rm -f "${CERTS_DIR}"/http.p12 \
      "${CERTS_DIR}"/http_ca.crt \
      "${CERTS_DIR}"/transport.p12 \
      /etc/elasticsearch/elastic-stack-ca.p12 \
      /etc/elasticsearch/elastic-certificates.p12 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# 4. ELASTICSEARCH CONFIGURATION + STARTUP
# ──────────────────────────────────────────────────────────────────────────────
header "4/8 · Configuring and Starting Elasticsearch"

cat > /etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: elk-cluster
node.name: elk-node-1
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: ${ES_PORT}
discovery.type: single-node
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.key: ${CERTS_DIR}/elasticsearch.key
xpack.security.http.ssl.certificate: ${CERTS_DIR}/elasticsearch.crt
xpack.security.http.ssl.certificate_authorities: ["${CERTS_DIR}/ca.crt"]
xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.key: ${CERTS_DIR}/elasticsearch.key
xpack.security.transport.ssl.certificate: ${CERTS_DIR}/elasticsearch.crt
xpack.security.transport.ssl.certificate_authorities: ["${CERTS_DIR}/ca.crt"]
bootstrap.memory_lock: true
EOF

mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms${ES_HEAP}
-Xmx${ES_HEAP}
EOF

mkdir -p /etc/systemd/system/elasticsearch.service.d
cat > /etc/systemd/system/elasticsearch.service.d/override.conf <<EOF
[Service]
LimitMEMLOCK=infinity
LimitNOFILE=65535
LimitNPROC=4096
EOF

sysctl -w vm.max_map_count=262144 &>/dev/null
echo "vm.max_map_count=262144" > /etc/sysctl.d/99-elasticsearch.conf

systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

info "Starting Elasticsearch (max 120s)..."
ES_READY=false
for i in $(seq 1 24); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        --cacert "${CERTS_DIR}/ca.crt" --max-time 5 \
        "https://127.0.0.1:${ES_PORT}/_cluster/health" 2>/dev/null || echo "000")
    if [[ "$HTTP" == "200" || "$HTTP" == "401" ]]; then
        ES_READY=true; break
    fi
    warn "Waiting... ($i/24) [HTTP $HTTP]"
    sleep 5
done
[[ "$ES_READY" == "false" ]] && \
    error "Elasticsearch did not start.\n  Diagnose: journalctl -u elasticsearch -n 80 --no-pager"

success "Elasticsearch is running."

# ──────────────────────────────────────────────────────────────────────────────
# 5. RESET elastic PASSWORD
# ──────────────────────────────────────────────────────────────────────────────
header "5/8 · elastic User Password"

info "Resetting elastic password..."
RESET_OUTPUT=$(/usr/share/elasticsearch/bin/elasticsearch-reset-password \
    -u elastic --batch --force \
    --url "https://127.0.0.1:${ES_PORT}" \
    -E xpack.security.http.ssl.certificate_authorities="${CERTS_DIR}/ca.crt" 2>&1)

ES_PASS=$(echo "$RESET_OUTPUT" | grep -oP '(?<=New value: )\S+')

if [[ -z "$ES_PASS" ]]; then
    warn "Could not parse password. Raw output:"
    echo "$RESET_OUTPUT"
    error "Failed to obtain elastic password automatically."
fi

success "elastic password obtained."

HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    --cacert "${CERTS_DIR}/ca.crt" \
    -u "elastic:${ES_PASS}" \
    "https://127.0.0.1:${ES_PORT}/_cluster/health" 2>/dev/null || echo "000")

[[ "$HTTP" == "200" ]] && success "Connection verified (HTTP 200)." || \
    warn "Verification HTTP code: ${HTTP}"

# ──────────────────────────────────────────────────────────────────────────────
# 6. KIBANA
# ──────────────────────────────────────────────────────────────────────────────
header "6/8 · Configuring Kibana"

# Service token
curl -s --cacert "${CERTS_DIR}/ca.crt" \
    -u "elastic:${ES_PASS}" -X DELETE \
    "https://127.0.0.1:${ES_PORT}/_security/service/elastic/kibana/credential/token/kibana-token" \
    &>/dev/null || true
sleep 2

TOKEN_JSON=$(curl -s --cacert "${CERTS_DIR}/ca.crt" \
    -u "elastic:${ES_PASS}" -X POST \
    "https://127.0.0.1:${ES_PORT}/_security/service/elastic/kibana/credential/token/kibana-token")

KIBANA_TOKEN=$(echo "$TOKEN_JSON" | jq -r '.token.value' 2>/dev/null || echo "")
[[ -z "$KIBANA_TOKEN" || "$KIBANA_TOKEN" == "null" ]] && \
    error "Failed to obtain Kibana token.\nAPI response: ${TOKEN_JSON}"
success "Kibana service token obtained."

# Copy certificates to the kibana directory
mkdir -p /etc/kibana/certs
cp "${CERTS_DIR}/ca.crt" \
   "${CERTS_DIR}/kibana.crt" \
   "${CERTS_DIR}/kibana.key" \
   /etc/kibana/certs/

chown -R root:kibana /etc/kibana/certs
chmod 755 /etc/kibana/certs
chmod 640 /etc/kibana/certs/ca.crt \
          /etc/kibana/certs/kibana.crt \
          /etc/kibana/certs/kibana.key

# Encryption keys
info "Generating encryption keys..."
ENC_OUT=$(/usr/share/kibana/bin/kibana-encryption-keys generate 2>/dev/null || true)

KB_ENC_KEY=$(echo "$ENC_OUT" | grep 'encryptedSavedObjects.encryptionKey' \
    | sed 's/.*encryptionKey: //' | tr -d '"' | tr -d "'" | xargs)
KB_REP_KEY=$(echo "$ENC_OUT" | grep 'reporting.encryptionKey' \
    | sed 's/.*encryptionKey: //' | tr -d '"' | tr -d "'" | xargs)
KB_SEC_KEY=$(echo "$ENC_OUT" | grep 'security.encryptionKey' \
    | sed 's/.*encryptionKey: //' | tr -d '"' | tr -d "'" | xargs)

[[ ${#KB_ENC_KEY} -lt 32 ]] && KB_ENC_KEY=$(openssl rand -hex 32)
[[ ${#KB_REP_KEY} -lt 32 ]] && KB_REP_KEY=$(openssl rand -hex 32)
[[ ${#KB_SEC_KEY} -lt 32 ]] && KB_SEC_KEY=$(openssl rand -hex 32)

# kibana.yml
KB_CONF="/etc/kibana/kibana.yml"
cp "${KB_CONF}" "${KB_CONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true

tee "$KB_CONF" > /dev/null <<EOF
server.port: ${KB_PORT}
server.host: "0.0.0.0"
server.name: "elk-kibana"

server.ssl.enabled: true
server.ssl.certificate: /etc/kibana/certs/kibana.crt
server.ssl.key: /etc/kibana/certs/kibana.key

elasticsearch.hosts: ["https://127.0.0.1:${ES_PORT}"]
elasticsearch.serviceAccountToken: '${KIBANA_TOKEN}'
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/ca.crt"]
elasticsearch.ssl.verificationMode: "certificate"

xpack.encryptedSavedObjects.encryptionKey: '${KB_ENC_KEY}'
xpack.reporting.encryptionKey: '${KB_REP_KEY}'
xpack.security.encryptionKey: '${KB_SEC_KEY}'

logging.appenders.file.type: file
logging.appenders.file.fileName: /var/log/kibana/kibana.log
logging.appenders.file.layout.type: json
logging.root.appenders: [default, file]
EOF

grep -q "serviceAccountToken:" "$KB_CONF" || \
    error "Failed to write serviceAccountToken line to kibana.yml."
grep -q "encryptedSavedObjects" "$KB_CONF" || \
    error "Failed to write encryption key to kibana.yml."

systemctl daemon-reload
systemctl enable kibana
systemctl start kibana
success "Kibana started."

# ──────────────────────────────────────────────────────────────────────────────
# 7. LOGSTASH
# ──────────────────────────────────────────────────────────────────────────────
header "7/8 · Configuring Logstash"

mkdir -p /etc/logstash/certs
cp "${CERTS_DIR}/ca.crt" /etc/logstash/certs/
chown -R root:logstash /etc/logstash/certs
chmod 750 /etc/logstash/certs
chmod 640 /etc/logstash/certs/ca.crt

# JVM heap
LS_JVM="/etc/logstash/jvm.options"
if [[ -f "$LS_JVM" ]]; then
    sed -i "s/^-Xms[[:space:]]*[0-9]*[mMgG]$/-Xms${LS_HEAP}/" "$LS_JVM"
    sed -i "s/^-Xmx[[:space:]]*[0-9]*[mMgG]$/-Xmx${LS_HEAP}/" "$LS_JVM"
fi

# logstash_writer user
LS_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)

curl -s --cacert "${CERTS_DIR}/ca.crt" -u "elastic:${ES_PASS}" \
    -X PUT -H "Content-Type: application/json" \
    "https://127.0.0.1:${ES_PORT}/_security/role/logstash_writer" \
    -d '{
      "cluster": ["manage_index_templates","monitor","manage_ilm"],
      "indices": [{
        "names": ["logstash-*","logs-*","opnsense-*"],
        "privileges": ["write","create","create_index","manage","manage_ilm"]
      }]
    }' &>/dev/null

curl -s --cacert "${CERTS_DIR}/ca.crt" -u "elastic:${ES_PASS}" \
    -X PUT -H "Content-Type: application/json" \
    "https://127.0.0.1:${ES_PORT}/_security/user/logstash_writer" \
    -d "{\"password\":\"${LS_PASS}\",\"roles\":[\"logstash_writer\"],
         \"full_name\":\"Logstash Writer\"}" &>/dev/null

success "logstash_writer user created."

# ── OPNsense + GeoIP Pipeline ─────────────────────────────────────────────────
if [[ "${DEPLOY_OPNSENSE_PIPELINE}" == "true" ]]; then
    info "Setting up OPNsense pipeline..."

    GEOIP_DIR="$(dirname "$GEOIP_DB")"
    mkdir -p "$GEOIP_DIR"

    if [[ ! -f "$GEOIP_DB" ]]; then
        info "Downloading GeoIP database (P3TERX mirror)..."
        GEOIP_TMP=$(mktemp -d)
        GEOIP_URL="https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"

        if curl -fsSL --retry 5 --retry-delay 10 \
                --connect-timeout 30 --max-time 300 \
                -o "${GEOIP_TMP}/GeoLite2-City.mmdb" "$GEOIP_URL" 2>/dev/null; then
            FILE_SIZE=$(stat -c%s "${GEOIP_TMP}/GeoLite2-City.mmdb" 2>/dev/null || echo 0)
            if [[ "$FILE_SIZE" -gt 1048576 ]]; then
                mv "${GEOIP_TMP}/GeoLite2-City.mmdb" "$GEOIP_DB"
                success "GeoIP DB downloaded: ${GEOIP_DB} ($(( FILE_SIZE / 1048576 )) MB)"
            else
                warn "GeoIP DB too small (${FILE_SIZE} bytes), may be corrupt."
            fi
        else
            warn "Could not download GeoIP DB. Pipeline will continue without GeoIP."
        fi
        rm -rf "$GEOIP_TMP"
    else
        info "GeoIP DB exists: ${GEOIP_DB}"
    fi

    chown -R root:logstash "$GEOIP_DIR"
    chmod 750 "$GEOIP_DIR"
    [[ -f "$GEOIP_DB" ]] && chmod 640 "$GEOIP_DB"

    # Pipeline conf
    # NOTE: Logstash environment variables (e.g. ${ES_PASS}) are escaped with \$.
    # Bash variables (e.g. ${LS_SYSLOG_PORT}) are expanded here.
    cat > /etc/logstash/conf.d/opnsense.conf <<EOF
# =============================================================================
# OPNsense + Suricata Logstash Pipeline (ECS v8 + GeoIP)
# =============================================================================

input {
  udp {
    port  => ${LS_SYSLOG_PORT}
    codec => plain
    type  => "opnsense"
  }
}

filter {

  # ---------------------------------------------------------------------------
  # RFC 5424 — parse the syslog header
  # ---------------------------------------------------------------------------
  grok {
    match => {
      "message" => [
        "^<%{INT:syslog_pri}>%{INT:syslog_ver} %{TIMESTAMP_ISO8601:syslog_timestamp} %{HOSTNAME:hostname} %{WORD:program} %{INT:pid} - \[meta sequenceId=\"%{INT:sequence_id}\"\] %{GREEDYDATA:raw_payload}$",
        "^<%{INT:syslog_pri}>%{INT:syslog_ver} %{TIMESTAMP_ISO8601:syslog_timestamp} %{HOSTNAME:hostname} %{WORD:program} %{INT:pid} - - %{GREEDYDATA:raw_payload}$"
      ]
    }
    tag_on_failure => ["_grok_rfc5424_failure"]
  }

  date {
    match  => ["syslog_timestamp", "ISO8601"]
    target => "@timestamp"
  }

  mutate { rename => { "hostname" => "[observer][hostname]" } }

  # ===========================================================================
  # SURICATA IPS / EVE JSON
  # ===========================================================================
  if [program] == "suricata" or [program] == "suricata-alert" {

    json {
      source         => "raw_payload"
      target         => "suricata"
      tag_on_failure => ["_suricata_json_failure"]
    }

    mutate {
      rename => {
        "[suricata][src_ip]"    => "[source][ip]"
        "[suricata][dest_ip]"   => "[destination][ip]"
        "[suricata][src_port]"  => "[source][port]"
        "[suricata][dest_port]" => "[destination][port]"
        "[suricata][proto]"     => "[network][transport]"
      }
      add_field => {
        "[event][kind]"    => "alert"
        "[event][module]"  => "suricata"
        "[event][dataset]" => "suricata.eve"
      }
      lowercase => ["[network][transport]"]
    }

    if [suricata][event_type] == "alert" {
      mutate {
        rename => {
          "[suricata][alert][signature]"    => "[rule][name]"
          "[suricata][alert][signature_id]" => "[rule][id]"
          "[suricata][alert][category]"     => "[rule][category]"
          "[suricata][alert][severity]"     => "[event][severity]"
          "[suricata][alert][rev]"          => "[rule][version]"
          "[suricata][alert][gid]"          => "[rule][ruleset]"
        }
        add_field => {
          "[event][category]" => "intrusion_detection"
          "[event][type]"     => "denied"
        }
      }

      ruby {
        code => '
          action = event.get("[suricata][alert][action]").to_s.downcase
          case action
          when "blocked", "drop"
            event.set("[event][action]",  "blocked")
            event.set("[event][outcome]", "failure")
          when "alert", "allowed"
            event.set("[event][action]",  "detected")
            event.set("[event][outcome]", "unknown")
          else
            event.set("[event][action]",  action.empty? ? "unknown" : action)
            event.set("[event][outcome]", "unknown")
          end
        '
      }
    }

    if [suricata][event_type] == "dns" {
      mutate {
        rename => {
          "[suricata][dns][rrname]" => "[dns][question][name]"
          "[suricata][dns][rrtype]" => "[dns][question][type]"
          "[suricata][dns][rcode]"  => "[dns][response_code]"
        }
        add_field => {
          "[event][category]" => "network"
          "[event][type]"     => "protocol"
        }
      }
    }

    if [suricata][event_type] == "http" {
      mutate {
        rename => {
          "[suricata][http][hostname]"      => "[url][domain]"
          "[suricata][http][url]"           => "[url][path]"
          "[suricata][http][http_method]"   => "[http][request][method]"
          "[suricata][http][status]"        => "[http][response][status_code]"
        }
        add_field => {
          "[event][category]" => "web"
          "[event][type]"     => "access"
        }
      }
    }

    if [suricata][event_type] == "tls" {
      mutate {
        rename => {
          "[suricata][tls][sni]"      => "[tls][server][x509][subject][common_name]"
          "[suricata][tls][version]"  => "[tls][version]"
          "[suricata][tls][issuerdn]" => "[tls][server][x509][issuer][common_name]"
        }
        add_field => {
          "[event][category]" => "network"
          "[event][type]"     => "protocol"
        }
      }
    }

    geoip {
      source            => "[source][ip]"
      target            => "source"
      ecs_compatibility => v8
      database          => "${GEOIP_DB}"
    }
    geoip {
      source            => "[destination][ip]"
      target            => "destination"
      ecs_compatibility => v8
      database          => "${GEOIP_DB}"
    }

    mutate {
      remove_field => [
        "raw_payload", "message", "syslog_pri", "syslog_ver",
        "pid", "sequence_id", "syslog_timestamp"
      ]
    }

  # ===========================================================================
  # FILTERLOG / FIREWALL
  # ===========================================================================
  } else if [program] == "filterlog" {

    mutate { rename => { "raw_payload" => "filterlog" } }

    csv {
      source             => "filterlog"
      separator          => ","
      skip_empty_columns => false
      columns            => [
        "rule_number", "sub_rule_number", "anchor", "tracker",
        "interface", "reason", "action", "direction", "ip_version",
        "tos", "ecn", "ttl", "packet_id", "offset", "flags",
        "protocol_id", "protocol", "length",
        "src_ip", "dst_ip", "src_port", "dst_port",
        "data_length", "tcp_seq", "tcp_ack", "tcp_window", "tcp_flags", "tcp_options"
      ]
    }

    mutate {
      rename => {
        "src_ip"      => "[source][ip]"
        "dst_ip"      => "[destination][ip]"
        "src_port"    => "[source][port]"
        "dst_port"    => "[destination][port]"
        "protocol"    => "[network][transport]"
        "action"      => "[event][action]"
        "rule_number" => "[rule][id]"
      }
      convert => {
        "[source][port]"      => "integer"
        "[destination][port]" => "integer"
        "data_length"         => "integer"
        "ttl"                 => "integer"
        "length"              => "integer"
      }
      lowercase => ["[network][transport]"]
      add_field => {
        "[event][kind]"        => "event"
        "[event][module]"      => "opnsense"
        "[event][dataset]"     => "opnsense.filterlog"
        "[network][direction]" => "%{direction}"
      }
    }

    ruby {
      code => '
        event.set("[event][category]", ["network"])
        event.set("[event][type]",     ["connection"])
        action = event.get("[event][action]").to_s.downcase
        event.set("[event][outcome]", action == "block" ? "failure" : "success")
      '
    }

    if [tcp_flags] {
      if [tcp_flags] == "0x000" { mutate { add_tag => ["tcp_null_scan"] } }
      if [tcp_flags] == "0x001" { mutate { add_tag => ["tcp_fin_scan"]  } }
      if [tcp_flags] == "0x02b" { mutate { add_tag => ["tcp_xmas_scan"] } }
    }

    geoip {
      source            => "[source][ip]"
      target            => "source"
      ecs_compatibility => v8
      database          => "${GEOIP_DB}"
    }
    geoip {
      source            => "[destination][ip]"
      target            => "destination"
      ecs_compatibility => v8
      database          => "${GEOIP_DB}"
    }

    mutate {
      remove_field => [
        "message", "filterlog", "syslog_pri", "syslog_ver",
        "pid", "sequence_id", "syslog_timestamp",
        "direction", "sub_rule_number", "anchor", "tracker"
      ]
    }

  # ===========================================================================
  # Unknown program
  # ===========================================================================
  } else {
    mutate {
      add_tag   => ["_unknown_program"]
      add_field => { "[event][module]" => "%{program}" }
    }
  }
}

# =============================================================================
# OUTPUT
#   Suricata alert  → opnsense-suricata-YYYY.MM.dd
#   Firewall log    → opnsense-syslog-YYYY.MM.dd
#   Other/unknown   → opnsense-other-YYYY.MM.dd
# =============================================================================
output {

  if [event][module] == "suricata" {
    elasticsearch {
      hosts                       => ["https://127.0.0.1:9200"]
      user                        => "elastic"
      password                    => "\${es_pass}"
      ssl_enabled                 => true
      ssl_certificate_authorities => ["/etc/logstash/certs/ca.crt"]
      ssl_verification_mode       => "full"
      index                       => "opnsense-suricata-%{+YYYY.MM.dd}"
    }
  } else if [event][module] == "opnsense" {
    elasticsearch {
      hosts                       => ["https://127.0.0.1:9200"]
      user                        => "elastic"
      password                    => "\${es_pass}"
      ssl_enabled                 => true
      ssl_certificate_authorities => ["/etc/logstash/certs/ca.crt"]
      ssl_verification_mode       => "full"
      index                       => "opnsense-syslog-%{+YYYY.MM.dd}"
    }
  } else {
    elasticsearch {
      hosts                       => ["https://127.0.0.1:9200"]
      user                        => "elastic"
      password                    => "\${es_pass}"
      ssl_enabled                 => true
      ssl_certificate_authorities => ["/etc/logstash/certs/ca.crt"]
      ssl_verification_mode       => "full"
      index                       => "opnsense-other-%{+YYYY.MM.dd}"
    }
  }

}
EOF
    success "OPNsense pipeline conf created: /etc/logstash/conf.d/opnsense.conf"

fi  # DEPLOY_OPNSENSE_PIPELINE

# Logstash config test
info "Testing Logstash configuration..."
LS_TEST=$(/usr/share/logstash/bin/logstash \
    --path.settings /etc/logstash -t 2>&1 || true)

if echo "$LS_TEST" | grep -q "Configuration OK"; then
    success "Logstash configuration is valid."
else
    warn "Logstash test output (last 20 lines):"
    echo "$LS_TEST" | tail -20
fi

# ── Logstash Keystore ─────────────────────────────────────────────────────────
info "Creating Logstash keystore..."

# Remove if it exists
rm -f /etc/logstash/logstash.keystore

# Run from /tmp — avoids Bundler directory error
cd /tmp

echo y | /usr/share/logstash/bin/logstash-keystore \
    --path.settings /etc/logstash create 2>/dev/null

# Logstash 9.x lowercases keystore keys,
# we use ${es_pass} in conf.d — lowercase for consistency
printf '%s' "${ES_PASS}" | /usr/share/logstash/bin/logstash-keystore \
    --path.settings /etc/logstash add es_pass 2>/dev/null

chown root:logstash /etc/logstash/logstash.keystore
chmod 640 /etc/logstash/logstash.keystore

success "Logstash keystore ready."
cd - > /dev/null

systemctl daemon-reload
systemctl enable --now logstash
success "Logstash enabled and started."

# ──────────────────────────────────────────────────────────────────────────────
# 8. UFW + CREDENTIALS + SUMMARY
# ──────────────────────────────────────────────────────────────────────────────
header "8/8 · UFW + Credentials + Summary"

if [[ "${CONFIGURE_UFW}" == "true" ]]; then
    ufw --force reset          &>/dev/null || true
    ufw default deny incoming  &>/dev/null
    ufw default allow outgoing &>/dev/null

    ufw allow 22/tcp                  comment "SSH"                 &>/dev/null
    ufw allow "${ES_PORT}/tcp"        comment "Elasticsearch"       &>/dev/null
    ufw allow "${KB_PORT}/tcp"        comment "Kibana"              &>/dev/null
    ufw allow "${LS_BEATS_PORT}/tcp"  comment "Logstash Beats"      &>/dev/null

    if [[ "${DEPLOY_OPNSENSE_PIPELINE}" == "true" ]]; then
        ufw allow "${LS_SYSLOG_PORT}/udp" comment "OPNsense Syslog UDP" &>/dev/null
    fi

    ufw --force enable &>/dev/null
    success "UFW enabled."
    ufw status verbose
fi

# Save credentials
cat > "$CREDS_FILE" <<CREDS
# ELK Stack Credentials — $(date '+%Y-%m-%d %H:%M:%S')
ELASTIC_USER=elastic
ELASTIC_PASS=${ES_PASS}
LOGSTASH_USER=logstash_writer
LOGSTASH_PASS=${LS_PASS}
KIBANA_SERVICE_TOKEN=${KIBANA_TOKEN}
KB_ENC_KEY=${KB_ENC_KEY}
KB_REP_KEY=${KB_REP_KEY}
KB_SEC_KEY=${KB_SEC_KEY}
CREDS
chmod 600 "$CREDS_FILE"
success "Credentials saved: ${CREDS_FILE}"

# Service status summary
info "Preparing services (waiting 30s)..."
sleep 30

ES_STATUS=$(systemctl is-active elasticsearch 2>/dev/null || echo "inactive")
KB_STATUS=$(systemctl is-active kibana        2>/dev/null || echo "inactive")
LS_STATUS=$(systemctl is-active logstash      2>/dev/null || echo "inactive")

_svc_color() {
    [[ "$1" == "active" ]] && echo -e "${GREEN}$1${NC}" || echo -e "${RED}$1${NC}"
}

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║              ELK STACK 9.x INSTALLATION COMPLETE             ║${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Elasticsearch  : ${CYAN}https://${HOST_IP}:${ES_PORT}${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Kibana         : ${CYAN}https://${HOST_IP}:${KB_PORT}${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Logstash Beats : ${CYAN}${HOST_IP}:${LS_BEATS_PORT}${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Syslog (UDP)   : ${CYAN}${HOST_IP}:${LS_SYSLOG_PORT}${NC}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  elastic password   : ${ES_PASS}"
echo -e "${BOLD}${GREEN}║${NC}  logstash password  : ${LS_PASS}"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  elasticsearch  → $(_svc_color "$ES_STATUS")"
echo -e "${BOLD}${GREEN}║${NC}  kibana         → $(_svc_color "$KB_STATUS")"
echo -e "${BOLD}${GREEN}║${NC}  logstash       → $(_svc_color "$LS_STATUS")"
echo -e "${BOLD}${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${GREEN}║${NC}  Credentials file : ${CREDS_FILE}"
echo -e "${BOLD}${GREEN}║${NC}  Installation log : ${LOG_FILE}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

FAILED=()
[[ "$ES_STATUS" != "active" ]] && FAILED+=("elasticsearch")
[[ "$KB_STATUS" != "active" ]] && FAILED+=("kibana")
[[ "$LS_STATUS" != "active" ]] && FAILED+=("logstash")

if [[ ${#FAILED[@]} -gt 0 ]]; then
    warn "Service(s) that did not start: ${FAILED[*]}"
    for SVC in "${FAILED[@]}"; do
        warn "  journalctl -u ${SVC} -n 60 --no-pager"
    done
else
    success "All services are running."
    info "Cluster health check:"
    info "  curl -s --cacert ${CERTS_DIR}/ca.crt -u elastic:${ES_PASS} \\"
    info "    https://127.0.0.1:${ES_PORT}/_cluster/health | jq ."
fi