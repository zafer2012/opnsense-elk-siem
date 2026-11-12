#!/bin/bash
# ============================================================
# Negative Traffic Test Result Analysis
# Checks how many alerts ElastAlert2 generated during the negative
# test window (False Positives) and calculates the confusion matrix.
#
# Usage:   ./check_false_positives.sh <test_start_timestamp> <test_end_timestamp>
# Example: ./check_false_positives.sh "2026-06-25T10:00:00" "2026-06-26T10:00:00"
# ============================================================

CREDS_FILE="/root/.elk_credentials"
if [[ -f "$CREDS_FILE" ]]; then
    ES_PASS=$(grep ^ELASTIC_PASS "$CREDS_FILE" | cut -d= -f2-)
fi
ES_URL="https://localhost:9200"
ES_USER="elastic"

START="$1"
END="$2"

if [[ -z "$START" || -z "$END" ]]; then
  echo "Usage: $0 <start_timestamp_UTC> <end_timestamp_UTC>"
  echo "Example: $0 \"2026-06-25T10:00:00\" \"2026-06-26T10:00:00\""
  exit 1
fi

echo "=========================================================="
echo " Negative Traffic Test — False Positive Analysis"
echo " Test Window: $START  →  $END"
echo "=========================================================="

# All rule names (the 8 ElastAlert2 rules in your system)
declare -a RULES=(
  "OPNsense - SSH Brute Force Attack"
  "OPNsense - RDP Brute Force Attack"
  "OPNsense - Port Scan Detection"
  "OPNsense - DDoS Traffic Flood"
  "OPNsense - SMB Lateral Movement / Ransomware"
  "OPNsense - Abnormal TCP Flag Combination"
  "OPNsense - Access from High-Risk Country"
  "OPNsense - Traffic Spike Detection"
)

OUT_CSV="fp_analysis_results.csv"
echo "rule_name,false_positive_count" > "$OUT_CSV"

TOTAL_FP=0

for RULE in "${RULES[@]}"; do
  RESULT=$(curl -s -k -u "$ES_USER:$ES_PASS" \
    "$ES_URL/elastalert_status/_count" \
    -H "Content-Type: application/json" \
    -d "{
      \"query\": {
        \"bool\": {
          \"must\": [
            {\"match_phrase\": {\"rule_name\": \"$RULE\"}},
            {\"range\": {\"alert_time\": {\"gte\": \"$START\", \"lte\": \"$END\"}}}
          ]
        }
      }
    }")

  COUNT=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)
  COUNT=${COUNT:-0}

  echo "  $RULE : $COUNT false positive(s)"
  echo "\"$RULE\",$COUNT" >> "$OUT_CSV"
  TOTAL_FP=$((TOTAL_FP + COUNT))
done

echo ""
echo "=========================================================="
echo " TOTAL FALSE POSITIVES: $TOTAL_FP"
echo " Results saved to: $OUT_CSV"
echo "=========================================================="

# ------------------------------------------------------------
# Count total sent negative events from filterlog
# ------------------------------------------------------------
TOTAL_NEGATIVE_EVENTS=$(curl -s -k -u "$ES_USER:$ES_PASS" \
  "$ES_URL/opnsense-syslog-*/_count" \
  -H "Content-Type: application/json" \
  -d "{
    \"query\": {
      \"bool\": {
        \"must\": [
          {\"range\": {\"@timestamp\": {\"gte\": \"$START\", \"lte\": \"$END\"}}},
          {\"query_string\": {\"query\": \"event.original: (*normal_auth* OR *normal_web* OR *normal_tcp* OR *normal_geo* OR *normal_smb* OR *normal_gradual*)\"}}
        ]
      }
    }
  }" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)

echo ""
echo "Total negative (benign) events sent: $TOTAL_NEGATIVE_EVENTS"

# ------------------------------------------------------------
# Confusion Matrix and Metric Calculation
# ------------------------------------------------------------
echo ""
echo "=========================================================="
echo " CONFUSION MATRIX AND METRICS"
echo " (Manually enter your positive test results from Table 5/6)"
echo "=========================================================="

python3 << PYEOF
# ───────────────────────────────────────────────────────────
# UPDATE THE VALUES BELOW with your ACTUAL results from
# Table 5/6 (True Positive and False Negative counts)
# ───────────────────────────────────────────────────────────
TP = 7    # Number of true positive scenarios in Table 5 (update including DDoS)
FN = 1    # Number of false negative scenarios in Table 5 (if any)
FP = $TOTAL_FP
TN = $TOTAL_NEGATIVE_EVENTS - FP

print(f"True Positive  (TP): {TP}")
print(f"False Negative (FN): {FN}")
print(f"False Positive (FP): {FP}")
print(f"True Negative  (TN): {TN}")
print()

precision = TP / (TP + FP) if (TP + FP) > 0 else 0
recall    = TP / (TP + FN) if (TP + FN) > 0 else 0
f1        = 2 * (precision * recall) / (precision + recall) if (precision + recall) > 0 else 0
fpr       = FP / (FP + TN) if (FP + TN) > 0 else 0
fnr       = FN / (FN + TP) if (FN + TP) > 0 else 0

print(f"Precision             : {precision:.3f}")
print(f"Recall (Sensitivity)  : {recall:.3f}")
print(f"F1-Score               : {f1:.3f}")
print(f"False Positive Rate    : {fpr:.4f}  ({fpr*100:.2f}%)")
print(f"False Negative Rate    : {fnr:.4f}  ({fnr*100:.2f}%)")
PYEOF

echo ""
echo "Note: Do not forget to update the TP/FN values inside the script"
echo "      with your actual results from Table 5/6."