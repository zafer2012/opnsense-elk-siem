#!/bin/bash
# =============================================================================
# ELK Stack — Elasticsearch Index Template Kurulumu
# opnsense-other-*  / opnsense-syslog-*  / opnsense-suricata-*
# =============================================================================

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

# ── Credentials yükle ────────────────────────────────────────────────────────
# FIX: source yerine grep ile oku — KB_ENC_KEY gibi satırlar bash'i patlatıyor
CREDS_FILE="/root/.elk_credentials"

if [[ -f "$CREDS_FILE" ]]; then
    ES_PASS=$(grep ^ELASTIC_PASS "$CREDS_FILE" | cut -d= -f2-)
    info "Credentials dosyası yüklendi: ${CREDS_FILE}"
else
    warn "Credentials dosyası bulunamadı: ${CREDS_FILE}"
fi

ES_HOST="${ES_HOST:-https://127.0.0.1:9200}"
CACERT="/etc/elasticsearch/certs/ca.crt"

if [[ -z "${ES_PASS:-}" ]]; then
    read -rsp "Elasticsearch 'elastic' şifresi: " ES_PASS
    echo ""
fi

# ── Bağlantı testi ────────────────────────────────────────────────────────────
header "Elasticsearch Bağlantı Testi"

HEALTH=$(curl -s -u "elastic:${ES_PASS}" \
    --cacert "${CACERT}" \
    "${ES_HOST}/_cluster/health" 2>/dev/null \
    | grep -o '"status":"[^"]*"' | cut -d'"' -f4)

if [[ -z "$HEALTH" ]]; then
    warn "CA cert ile bağlanılamadı, -k ile deneniyor..."
    HEALTH=$(curl -s -u "elastic:${ES_PASS}" -k \
        "${ES_HOST}/_cluster/health" 2>/dev/null \
        | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    [[ -n "$HEALTH" ]] && CURL_OPTS="-k" || \
        error "Elasticsearch'e ulaşılamadı. Host: ${ES_HOST}"
fi

CURL_OPTS="${CURL_OPTS:---cacert ${CACERT}}"
success "Cluster durumu: ${HEALTH}"

# ── Yardımcı fonksiyon ────────────────────────────────────────────────────────
apply_template() {
    local NAME="$1"
    local PAYLOAD="$2"

    RESPONSE=$(curl -s -o /tmp/_es_response.json -w "%{http_code}" \
        -u "elastic:${ES_PASS}" ${CURL_OPTS} \
        -X PUT "${ES_HOST}/_index_template/${NAME}" \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD")

    if [[ "$RESPONSE" == "200" ]]; then
        success "Template oluşturuldu/güncellendi: ${NAME}"
    else
        warn "Template '${NAME}' — HTTP ${RESPONSE}"
        cat /tmp/_es_response.json 2>/dev/null
        echo ""
    fi
}

# ── Template 1: opnsense-other-* ──────────────────────────────────────────────
header "Template: opnsense-other-*"

apply_template "opnsense-other" '{
  "index_patterns": ["opnsense-other-*"],
  "priority": 100,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "dynamic": "true",
      "dynamic_templates": [
        { "ip_fields":   { "match_pattern": "regex", "match": ".*\\.ip$",   "mapping": { "type": "ip"      } } },
        { "port_fields": { "match_pattern": "regex", "match": ".*\\.port$", "mapping": { "type": "integer" } } }
      ],
      "properties": {
        "@timestamp":  { "type": "date" },
        "source":      { "properties": { "ip": { "type": "ip" }, "port": { "type": "integer" },
          "geo": { "properties": {
            "country_iso_code": { "type": "keyword" }, "country_name": { "type": "keyword" },
            "city_name": { "type": "keyword" }, "region_name": { "type": "keyword" },
            "location": { "type": "geo_point" }
          }}}},
        "destination": { "properties": { "ip": { "type": "ip" }, "port": { "type": "integer" },
          "geo": { "properties": {
            "country_iso_code": { "type": "keyword" }, "country_name": { "type": "keyword" },
            "city_name": { "type": "keyword" }, "region_name": { "type": "keyword" },
            "location": { "type": "geo_point" }
          }}}},
        "network":  { "properties": { "transport": { "type": "keyword" }, "direction": { "type": "keyword" }, "protocol": { "type": "keyword" } } },
        "event":    { "properties": { "action": { "type": "keyword" }, "outcome": { "type": "keyword" }, "category": { "type": "keyword" }, "type": { "type": "keyword" }, "kind": { "type": "keyword" }, "module": { "type": "keyword" }, "dataset": { "type": "keyword" }, "severity": { "type": "integer" } } },
        "observer": { "properties": { "hostname": { "type": "keyword" } } },
        "rule":     { "properties": { "id": { "type": "keyword" }, "name": { "type": "keyword" }, "category": { "type": "keyword" }, "version": { "type": "keyword" }, "ruleset": { "type": "keyword" } } }
      }
    }
  }
}'

# ── Template 2: opnsense-syslog-* ─────────────────────────────────────────────
# FIX: sed ile COMMON_MAPPINGS manipülasyonu yerine tam JSON olarak yazıldı
header "Template: opnsense-syslog-*"

apply_template "opnsense-syslog" '{
  "index_patterns": ["opnsense-syslog-*"],
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "dynamic": "true",
      "dynamic_templates": [
        { "ip_fields":   { "match_pattern": "regex", "match": ".*\\.ip$",   "mapping": { "type": "ip"      } } },
        { "port_fields": { "match_pattern": "regex", "match": ".*\\.port$", "mapping": { "type": "integer" } } }
      ],
      "properties": {
        "@timestamp":  { "type": "date" },
        "source":      { "properties": { "ip": { "type": "ip" }, "port": { "type": "integer" },
          "geo": { "properties": {
            "country_iso_code": { "type": "keyword" }, "country_name": { "type": "keyword" },
            "city_name": { "type": "keyword" }, "region_name": { "type": "keyword" },
            "location": { "type": "geo_point" }
          }}}},
        "destination": { "properties": { "ip": { "type": "ip" }, "port": { "type": "integer" },
          "geo": { "properties": {
            "country_iso_code": { "type": "keyword" }, "country_name": { "type": "keyword" },
            "city_name": { "type": "keyword" }, "region_name": { "type": "keyword" },
            "location": { "type": "geo_point" }
          }}}},
        "network":    { "properties": { "transport": { "type": "keyword" }, "direction": { "type": "keyword" }, "protocol": { "type": "keyword" } } },
        "event":      { "properties": { "action": { "type": "keyword" }, "outcome": { "type": "keyword" }, "category": { "type": "keyword" }, "type": { "type": "keyword" }, "kind": { "type": "keyword" }, "module": { "type": "keyword" }, "dataset": { "type": "keyword" }, "severity": { "type": "integer" } } },
        "observer":   { "properties": { "hostname": { "type": "keyword" } } },
        "rule":       { "properties": { "id": { "type": "keyword" }, "name": { "type": "keyword" }, "category": { "type": "keyword" }, "version": { "type": "keyword" }, "ruleset": { "type": "keyword" } } },
        "tcp_flags":  { "type": "keyword" },
        "ip_version": { "type": "keyword" },
        "interface":  { "type": "keyword" },
        "reason":     { "type": "keyword" },
        "ttl":        { "type": "integer" },
        "length":     { "type": "integer" }
      }
    }
  }
}'

# ── Template 3: opnsense-suricata-* ──────────────────────────────────────────
header "Template: opnsense-suricata-*"

apply_template "opnsense-suricata" '{
  "index_patterns": ["opnsense-suricata-*"],
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "dynamic": "true",
      "dynamic_templates": [
        { "ip_fields":   { "match_pattern": "regex", "match": ".*\\.ip$",   "mapping": { "type": "ip"      } } },
        { "port_fields": { "match_pattern": "regex", "match": ".*\\.port$", "mapping": { "type": "integer" } } }
      ],
      "properties": {
        "@timestamp":  { "type": "date" },
        "source":      { "properties": { "ip": { "type": "ip" }, "port": { "type": "integer" },
          "geo": { "properties": {
            "country_iso_code": { "type": "keyword" }, "country_name": { "type": "keyword" },
            "city_name": { "type": "keyword" }, "region_name": { "type": "keyword" },
            "location": { "type": "geo_point" }
          }}}},
        "destination": { "properties": { "ip": { "type": "ip" }, "port": { "type": "integer" },
          "geo": { "properties": {
            "country_iso_code": { "type": "keyword" }, "country_name": { "type": "keyword" },
            "city_name": { "type": "keyword" }, "region_name": { "type": "keyword" },
            "location": { "type": "geo_point" }
          }}}},
        "network":  { "properties": { "transport": { "type": "keyword" }, "protocol": { "type": "keyword" } } },
        "event":    { "properties": { "action": { "type": "keyword" }, "outcome": { "type": "keyword" }, "category": { "type": "keyword" }, "type": { "type": "keyword" }, "kind": { "type": "keyword" }, "module": { "type": "keyword" }, "dataset": { "type": "keyword" }, "severity": { "type": "integer" } } },
        "observer": { "properties": { "hostname": { "type": "keyword" } } },
        "rule":     { "properties": { "id": { "type": "keyword" }, "name": { "type": "keyword" }, "category": { "type": "keyword" }, "version": { "type": "keyword" }, "ruleset": { "type": "keyword" } } },
        "dns": { "properties": {
          "question": { "properties": { "name": { "type": "keyword" }, "type": { "type": "keyword" } } },
          "response_code": { "type": "keyword" }
        }},
        "url":  { "properties": { "domain": { "type": "keyword" }, "path": { "type": "keyword" } } },
        "http": { "properties": {
          "request":  { "properties": { "method": { "type": "keyword" } } },
          "response": { "properties": { "status_code": { "type": "integer" } } }
        }},
        "tls": { "properties": {
          "version": { "type": "keyword" },
          "server": { "properties": { "x509": { "properties": {
            "subject": { "properties": { "common_name": { "type": "keyword" } } },
            "issuer":  { "properties": { "common_name": { "type": "keyword" } } }
          }}}}
        }}
      }
    }
  }
}'

# ── Mevcut templates ──────────────────────────────────────────────────────────
header "Mevcut Index Template Listesi"
echo ""
curl -s -u "elastic:${ES_PASS}" ${CURL_OPTS} \
    "${ES_HOST}/_index_template/opnsense*?pretty" \
    | grep -E '"name"|"index_patterns"' \
    | sed 's/^/  /'

echo ""
success "Tüm template işlemleri tamamlandı."
info "Kibana → Stack Management → Index Management → Index Templates"

# ── Mevcut indekslere template'i uygula (varsa) ───────────────────────────────
header "Mevcut İndeksler"
curl -s -u "elastic:${ES_PASS}" ${CURL_OPTS} \
    "${ES_HOST}/_cat/indices/opnsense-*?v&s=index" 2>/dev/null || true
echo ""