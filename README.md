[README.md](https://github.com/user-attachments/files/34772305/README.md)
# OPNsense ELK SIEM — Open-Source Security Operations Center

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![ELK Stack](https://img.shields.io/badge/ELK-9.x-005571?logo=elastic)](https://www.elastic.co/)
[![OPNsense](https://img.shields.io/badge/OPNsense-26.x-orange)](https://opnsense.org/)
[![ElastAlert2](https://img.shields.io/badge/ElastAlert2-2.x-blue)](https://elastalert2.readthedocs.io/)

A fully open-source, zero-licensing-cost SIEM architecture integrating the ELK Stack
with OPNsense firewall and ElastAlert2 for real-time threat detection and multi-channel
alerting. Designed for organizations operating at the 1,000–5,000 user scale (university
campuses, municipalities, healthcare facilities, small ISPs).

> **Associated publication:** Özer, Z. (2026). Cost-Effective Security Operations Center
> Design for Academic and SME Environments: Integrating Open-Source SIEM with
> Multi-Channel Alerting. *(under review)*

---

## Architecture Overview

```
[Kali Linux / External Attacker]
           │ (WAN)
    ┌──────▼──────┐
    │  OPNsense   │  ← Suricata IPS (ET Open ruleset)
    │  Firewall   │  ← filterlog → UDP 5140
    └──────┬──────┘
           │ (LAN)
    ┌──────▼──────┐     ┌──────────────────────┐
    │Metasploitable│     │    Ubuntu Server     │
    │      2       │     │                      │
    │  (target)    │     │  Logstash (UDP 5140) │
    └─────────────┘     │         ↓            │
                        │  Elasticsearch        │ opnsense-syslog-*
                        │         ↓            │ opnsense-suricata-*
                        │  Kibana / ElastAlert2 │
                        │         ↓            │
                        │  Email / Telegram /   │
                        │  Slack Notifications  │
                        └──────────────────────┘
```

---

## Features

- Automated deployment via two-stage Bash scripts (ELK Stack + ElastAlert2)
- ECS v9 compliant field mapping for OPNsense filterlog and Suricata EVE JSON
- GeoIP enrichment using MaxMind GeoLite2-City database
- TCP flag detection tagging for NULL, FIN, and XMAS scan patterns
- 12 custom ElastAlert2 rules covering brute force, lateral movement, anomaly scans,
  geo-blocking, DDoS, and traffic spike detection
- Multi-channel alerting via Email (SMTP), Telegram Bot, and Slack webhook
- Kibana Security detection rules importable via NDJSON
- Attack simulation script for end-to-end validation
- TLS/HTTPS throughout (self-signed CA, X-Pack security)
- Least-privilege Logstash user with keystore credential storage

---

## Repository Structure

```
opnsense-elk-siem/
├── install/
│   ├── elk_install.sh               # ELK Stack full installation (8 stages)
│   ├── elk_index_templates.sh       # ECS index template deployment
│   └── elastalert_install.sh        # ElastAlert2 installation and configuration
├── uninstall/
│   ├── elk_uninstall.sh             # Full ELK Stack removal
│   └── elastalert_uninstall.sh      # ElastAlert2 removal
├── logstash/
│   └── opnsense.conf                # Logstash pipeline (filterlog + Suricata EVE)
├── elastalert/
│   ├── config.yaml                  # ElastAlert2 main configuration (template)
│   └── rules/
│       ├── opnsense-rule-01-ssh-brute-force.yaml
│       ├── opnsense-rule-02-rdp-brute-force.yaml
│       ├── opnsense-rule-03-port-scan.yaml
│       ├── opnsense-rule-04-ddos.yaml
│       ├── opnsense-rule-05-smb-lateral.yaml
│       ├── opnsense-rule-06-tcp-flag.yaml
│       ├── opnsense-rule-07-geo-block.yaml
│       ├── opnsense-rule-08-ips-portscan.yaml
│       ├── opnsense-rule-09-dns-beaconing.yaml
│       ├── opnsense-rule-10-ddos-flood.yaml
│       ├── opnsense-rule-11-distributed-recon.yaml
│       └── opnsense-rule-12-spike.yaml
├── kibana-detection-rules/
│   └── opnsense-siem-rules.ndjson   # Kibana/Elastic Security detection rules
├── tests/
│   └── opnsense-attack-tests.sh     # Attack simulation and validation script
├── docs/
│   ├── architecture-diagram.png
│   ├── logstash-pipeline-flow.png
│   └── elastalert-block-diagram.png
├── README.md
├── requirements.txt
└── LICENSE
```

---

## Requirements

See [requirements.txt](requirements.txt) for full software details.

**Host system:** Ubuntu Server 24.04 LTS — minimum 4 vCPU / 8 GB RAM / 50 GB disk

**Network prerequisites:**
- OPNsense firewall with Suricata IPS enabled on the WAN interface
- UDP port 5140 open from OPNsense to the SIEM host
- TCP 9200 (Elasticsearch) and TCP 5601 (Kibana) accessible on the SIEM host LAN

---

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/<your-username>/opnsense-elk-siem.git
cd opnsense-elk-siem
```

### 2. Install ELK Stack

```bash
chmod +x install/elk_install.sh
sudo bash install/elk_install.sh
```

The script installs Elasticsearch, Kibana, and Logstash (9.x), generates a
self-signed CA with TLS certificates, enables X-Pack security, deploys the
OPNsense Logstash pipeline, applies ECS index templates, and hardens the host
with UFW rules. Note the generated `elastic` password at the end of the run.

### 3. Deploy ECS index templates

```bash
chmod +x install/elk_index_templates.sh
sudo bash install/elk_index_templates.sh
```

### 4. Configure credentials before installing ElastAlert2

Edit `elastalert/config.yaml` and replace all placeholder values:

| Placeholder | Replace with |
|---|---|
| `${ELASTIC_USER}` | `elastic` |
| `${ELASTIC_PASS}` | Your Elasticsearch password |
| `${SLACK_WEBHOOK_URL}` | Your Slack incoming webhook URL |
| `${TELEGRAM_BOT_TOKEN}` | Your Telegram bot token |
| `${TELEGRAM_CHAT_ID}` | Your Telegram chat/channel ID |

Update the `email` field in each rule YAML with your recipient address and
configure `/etc/elastalert/smtp_auth.yaml` with your SMTP credentials.

### 5. Install ElastAlert2

```bash
chmod +x install/elastalert_install.sh
sudo bash install/elastalert_install.sh
```

### 6. Configure OPNsense syslog forwarding

On the OPNsense web interface:

1. **System → Settings → Logging → Remote** → Add destination:
   `<SIEM_HOST_IP>`, Port `5140`, Protocol `UDP`
2. **Services → Intrusion Detection → Administration**:
   - Enable Suricata in **Divert (IPS)** mode on WAN interface
   - Enable ET Open categories: `emerging-exploit`, `emerging-web_server`,
     `emerging-web_specific_apps`, `emerging-sql`, `emerging-attack_response`,
     `emerging-malware`, `emerging-worm`

### 7. Import Kibana detection rules

**Kibana → Security → Rules → Import rules**
→ Upload `kibana-detection-rules/opnsense-siem-rules.ndjson`

### 8. Validate the deployment

```bash
chmod +x tests/opnsense-attack-tests.sh
sudo bash tests/opnsense-attack-tests.sh all
```

Check Kibana → Security → Alerts and your notification channels within 1–2 minutes.

---

## ElastAlert2 Detection Rules

| Rule | Type | Threshold | Scenario |
|---|---|---|---|
| opnsense-rule-01 | frequency | 10 hits / 5 min | SSH brute force |
| opnsense-rule-02 | frequency | 10 hits / 5 min | RDP brute force |
| opnsense-rule-03 | cardinality | ≥15 distinct dst ports | Port scanning |
| opnsense-rule-04 | frequency | >500 hits / min | DDoS / traffic flood |
| opnsense-rule-05 | cardinality | ≥3 distinct target IPs | SMB lateral movement |
| opnsense-rule-06 | any | tag match | TCP NULL/FIN/XMAS scans |
| opnsense-rule-07 | any | country match | High-risk country access |
| opnsense-rule-08 | frequency | Suricata-based | IPS port scan detection |
| opnsense-rule-09 | cardinality | DNS query diversity | DNS beaconing / DGA |
| opnsense-rule-10 | cardinality | Suricata-based | DDoS flood (IPS layer) |
| opnsense-rule-11 | cardinality | Suricata-based | Distributed reconnaissance |
| opnsense-rule-12 | spike | spike_height ≥ 3× | Traffic volume anomaly |

---

## Uninstallation

```bash
sudo bash uninstall/elastalert_uninstall.sh   # Remove ElastAlert2
sudo bash uninstall/elk_uninstall.sh           # Remove ELK Stack (deletes all data)
```

---

## Security Notes

- **Never commit real credentials.** All sensitive values use placeholders.
  Store actual values in `/root/.elk_credentials` (mode 600) on the SIEM host.
- Self-signed certificates are used for TLS. Replace with CA-signed certificates
  for production deployments.
- Single-node Elasticsearch does not provide high availability. For production,
  use a minimum three-node cluster.
- This repository is intended for controlled lab and small-organization deployments.

---

## Test Environment

| Component | Specification |
|---|---|
| SIEM Host | Ubuntu 24.04 LTS, VMware VM, 4 vCPU, 8 GB RAM |
| Firewall | OPNsense 26.x (VMware VM) |
| Attacker | Kali Linux (VMware VM, WAN segment) |
| Target | Metasploitable 2 (VMware VM, LAN segment) |
| Hypervisor | VMware Workstation Pro 17.x |

---

## Citation

If you use this repository in academic work, please cite:

```bibtex
@article{ozer2026siem,
  title   = {Cost-Effective Security Operations Center Design for Academic
             and SME Environments: Integrating Open-Source SIEM with
             Multi-Channel Alerting},
  author  = {{\"O}zer, Zafer},
  journal = {(under review)},
  year    = {2026},
  url     = {https://github.com/<your-username>/opnsense-elk-siem}
}
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.

Component licenses: Elasticsearch/Kibana (ELv2/SSPL), Logstash (Apache 2.0),
OPNsense (BSD 2-Clause), ElastAlert2 (Apache 2.0), GeoLite2 (CC BY-SA 4.0).
Review each component license before production deployment.

---

**Author:** Zafer ÖZER · Mersin University · [ORCID 0000-0001-7118-938X](https://orcid.org/0000-0001-7118-938X) · zaferozer@mersin.edu.tr
