#!/usr/bin/env bash
# Confluent Flink Service Account – role-binding diagnostic
# CLI equivalent of README.md §1.1 and §1.2 (sanity checks on the Flink SA)
#
# Read-only – makes no changes to your Confluent Cloud environment.
#
# Prerequisites:
#   confluent login
#   jq (only needed when COMPUTE_POOL_ID is set for auto-deriving Flink cloud/region)
#
# Usage – either edit the defaults below, or export variables before running:
#   export SA_ID=sa-abc123 ENV_ID=env-abc123 KAFKA_ID=lkc-abc123
#   ./cc-sa-check.sh
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
# Required
SA_ID="${SA_ID:-}"       # service account to inspect, e.g. sa-abc123
ENV_ID="${ENV_ID:-}"     # environment ID, e.g. env-abc123
KAFKA_ID="${KAFKA_ID:-}" # Kafka cluster ID used as Flink database, e.g. lkc-abc123

# Optional – leave empty to skip the associated check
SR_ID="${SR_ID:-}"                    # Schema Registry cluster ID; empty → skip SR check
STATEMENT_NAME="${STATEMENT_NAME:-}"  # Flink statement name; empty → skip statement check

# Flink routing – needed only when STATEMENT_NAME is set.
# Leave both empty to auto-derive from COMPUTE_POOL_ID.
COMPUTE_POOL_ID="${COMPUTE_POOL_ID:-}"          # auto-derive cloud/region from this pool
CLOUD_PROVIDER_ID="${CLOUD_PROVIDER_ID:-}"      # e.g. aws | azure | gcp
CLOUD_PROVIDER_REGION="${CLOUD_PROVIDER_REGION:-}"  # e.g. us-east-2

# Topic and subject prefix expected to have bindings (should match cc-sa-setup.sh values)
TEST_TOPIC="${TEST_TOPIC:-flink_sa_test}"
TABLE_PREFIX="${TABLE_PREFIX:-flink_sa_}"
# ──────────────────────────────────────────────────────────────────────────────

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_num=1
pass_count=0
fail_count=0

section() {
  echo
  printf '── Check %d – %s\n' "${check_num}" "$*"
  check_num=$((check_num + 1))
}

# Print PASS/FAIL for a single expected item.
# Pattern is matched case-insensitively (grep -Eqi) against the full list output.
check_present() {
  local label="$1" pattern="$2" text="$3"
  if echo "${text}" | grep -Eqi "${pattern}"; then
    printf "    ✓  %s\n" "${label}"
    pass_count=$((pass_count + 1))
  else
    printf "    ✗  %s  ← NOT FOUND\n" "${label}"
    fail_count=$((fail_count + 1))
  fi
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Pre-flight ─────────────────────────────────────────────────────────────────
[[ -z "${SA_ID}" ]]    && die "SA_ID is required. Set it at the top of this script or export it."
[[ -z "${ENV_ID}" ]]   && die "ENV_ID is required."
[[ -z "${KAFKA_ID}" ]] && die "KAFKA_ID is required."
command -v confluent >/dev/null 2>&1 || die "confluent CLI not found."
# ──────────────────────────────────────────────────────────────────────────────

echo "Confluent Flink SA role-binding check"
printf "  %-20s %s\n" "SA:"             "${SA_ID}"
printf "  %-20s %s\n" "Environment:"    "${ENV_ID}"
printf "  %-20s %s\n" "Kafka cluster:"  "${KAFKA_ID}"
[[ -n "${SR_ID}" ]]          && printf "  %-20s %s\n" "Schema Registry:" "${SR_ID}"
[[ -n "${STATEMENT_NAME}" ]] && printf "  %-20s %s\n" "Statement:"       "${STATEMENT_NAME}"
[[ -n "${TEST_TOPIC}" ]]     && printf "  %-20s %s\n" "Test topic:"      "${TEST_TOPIC}"
[[ -n "${TABLE_PREFIX}" ]]   && printf "  %-20s %s\n" "Table prefix:"    "${TABLE_PREFIX}"

confluent environment use "${ENV_ID}"

# ── Check 1: Environment-level (FlinkDeveloper) ────────────────────────────────
section "Environment-level bindings (FlinkDeveloper)"
log "Purpose: confirms the SA can submit and manage Flink statements in this environment."
log "Without this binding, all statement submissions fail regardless of data-plane permissions."
log ""
log "Expected: at least one row with Role=FlinkDeveloper, Scope=Environment ${ENV_ID}"
log ""
log "Command:"
echo "  confluent iam rbac role-binding list \\"
echo "    --principal User:${SA_ID} \\"
echo "    --environment ${ENV_ID}"
echo

env_out=$(confluent iam rbac role-binding list \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" 2>&1) || true
echo "${env_out}" | sed 's/^/    /'

echo
log "Results:"
check_present \
  "FlinkDeveloper at environment scope" \
  "FlinkDeveloper" \
  "${env_out}"

# ── Check 2: Kafka cluster-level (Transactional-Id and Topics) ────────────────
section "Kafka cluster-level bindings (Transactional-Id and Topics)"
log "Purpose: confirms the SA has exactly-once semantics support and data-plane topic access."
log "These bindings are scoped to the Kafka cluster and must be queried separately from env-level."
log ""
log "Expected:"
log "  DeveloperRead   on Transactional-Id:_confluent-flink_ (prefix)  ← required for exactly-once read"
log "  DeveloperWrite  on Transactional-Id:_confluent-flink_ (prefix)  ← required for exactly-once write"
log "  DeveloperRead   on Topic:${TEST_TOPIC}                           ← required for SELECT"
log "  DeveloperWrite  on Topic:${TEST_TOPIC}                           ← required for INSERT INTO / CTAS"
log "  DeveloperManage on Topic:${TABLE_PREFIX} (prefix)                ← required for CREATE / ALTER TABLE"
log ""
log "  Note: if any of these are missing, statements will fail with 'insufficient permissions'"
log "  even if FlinkDeveloper is present at the environment level."
log ""
log "Command:"
echo "  confluent iam rbac role-binding list \\"
echo "    --principal User:${SA_ID} \\"
echo "    --environment ${ENV_ID} \\"
echo "    --cloud-cluster ${KAFKA_ID} \\"
echo "    --inclusive"
echo

kafka_out=$(confluent iam rbac role-binding list \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" \
  --cloud-cluster "${KAFKA_ID}" \
  --inclusive 2>&1) || true
echo "${kafka_out}" | sed 's/^/    /'

echo
log "Results:"
check_present \
  "DeveloperRead  on Transactional-Id:_confluent-flink_ (prefix)" \
  "DeveloperRead.+_confluent-flink_|_confluent-flink_.+DeveloperRead" \
  "${kafka_out}"
check_present \
  "DeveloperWrite on Transactional-Id:_confluent-flink_ (prefix)" \
  "DeveloperWrite.+_confluent-flink_|_confluent-flink_.+DeveloperWrite" \
  "${kafka_out}"
check_present \
  "DeveloperRead  on Topic:${TEST_TOPIC}" \
  "DeveloperRead.+${TEST_TOPIC}|${TEST_TOPIC}.+DeveloperRead" \
  "${kafka_out}"
check_present \
  "DeveloperWrite on Topic:${TEST_TOPIC}" \
  "DeveloperWrite.+${TEST_TOPIC}|${TEST_TOPIC}.+DeveloperWrite" \
  "${kafka_out}"
check_present \
  "DeveloperManage on Topic:${TABLE_PREFIX} (prefix)" \
  "DeveloperManage.+${TABLE_PREFIX}|${TABLE_PREFIX}.+DeveloperManage" \
  "${kafka_out}"

# ── Check 3: Schema Registry (optional) ───────────────────────────────────────
if [[ -n "${SR_ID}" ]]; then
  section "Schema Registry bindings (Subjects)"
  log "Purpose: confirms the SA can look up and register schemas under the subject prefix."
  log "Required when tables use Avro, Protobuf, or JSON Schema formats."
  log ""
  log "Expected:"
  log "  DeveloperRead  on Subject:${TABLE_PREFIX} (prefix)  ← schema lookup when reading"
  log "  DeveloperWrite on Subject:${TABLE_PREFIX} (prefix)  ← schema registration when writing"
  log ""
  log "Command:"
  echo "  confluent iam rbac role-binding list \\"
  echo "    --principal User:${SA_ID} \\"
  echo "    --environment ${ENV_ID} \\"
  echo "    --inclusive"
  echo

  sr_out=$(confluent iam rbac role-binding list \
    --principal "User:${SA_ID}" \
    --environment "${ENV_ID}" \
    --inclusive 2>&1) || true
  echo "${sr_out}" | sed 's/^/    /'

  echo
  log "Results:"
  check_present \
    "DeveloperRead  on Subject:${TABLE_PREFIX} (Cluster Type: Schema Registry, Logical Cluster: ${SR_ID})" \
    "DeveloperRead.*Schema Registry.*${SR_ID}.*Subject.*${TABLE_PREFIX}" \
    "${sr_out}"
  check_present \
    "DeveloperWrite on Subject:${TABLE_PREFIX} (Cluster Type: Schema Registry, Logical Cluster: ${SR_ID})" \
    "DeveloperWrite.*Schema Registry.*${SR_ID}.*Subject.*${TABLE_PREFIX}" \
    "${sr_out}"
fi

# ── Check 4: Flink statement principal (optional) ─────────────────────────────
if [[ -n "${STATEMENT_NAME}" ]]; then
  section "Flink statement: ${STATEMENT_NAME}"
  log "Purpose: confirms the statement runs under the SA's identity, not the submitting user's."
  log "If the Account field shows a user ID (u-xxxxx) instead of the SA, the SA's permissions"
  log "are not being applied, even if all role bindings above are correct."
  log ""
  log "Expected:"
  log "  Account field: ${SA_ID}"
  log "  Status: RUNNING or COMPLETED (not FAILED)"
  log "  No 'insufficient permissions' error in the Logs tab"

  # Resolve Flink regional endpoint (describe/delete require region context, not --compute-pool)
  if [[ -z "${CLOUD_PROVIDER_ID}" || -z "${CLOUD_PROVIDER_REGION}" ]]; then
    if [[ -n "${COMPUTE_POOL_ID}" ]]; then
      command -v jq >/dev/null 2>&1 \
        || die "jq is required to auto-derive cloud/region from COMPUTE_POOL_ID. Install: brew install jq"
      log ""
      log "Deriving Flink cloud/region from compute pool ${COMPUTE_POOL_ID}..."
      pool_json=$(confluent flink compute-pool describe "${COMPUTE_POOL_ID}" --output json)
      CLOUD_PROVIDER_ID=$(echo "${pool_json}" | jq -r '(.spec.cloud // .cloud // "") | ascii_downcase')
      CLOUD_PROVIDER_REGION=$(echo "${pool_json}" | jq -r '.spec.region // .region // ""')
      [[ -z "${CLOUD_PROVIDER_ID}" || -z "${CLOUD_PROVIDER_REGION}" ]] \
        && die "Could not derive cloud/region from compute pool. Set CLOUD_PROVIDER_ID and CLOUD_PROVIDER_REGION manually."
      log "  Cloud: ${CLOUD_PROVIDER_ID}  Region: ${CLOUD_PROVIDER_REGION}"
    else
      log ""
      log "Skipping statement check: STATEMENT_NAME is set but neither COMPUTE_POOL_ID nor"
      log "CLOUD_PROVIDER_ID + CLOUD_PROVIDER_REGION are provided."
      log "Set one of those to enable this check."
      STATEMENT_NAME=""
    fi
  fi

  if [[ -n "${STATEMENT_NAME}" ]]; then
    confluent flink region use \
      --cloud "${CLOUD_PROVIDER_ID}" \
      --region "${CLOUD_PROVIDER_REGION}" 2>/dev/null || true

    log ""
    log "Command:"
    echo "  confluent flink statement describe ${STATEMENT_NAME}"
    echo

    stmt_out=$(confluent flink statement describe "${STATEMENT_NAME}" 2>&1) || true
    echo "${stmt_out}" | sed 's/^/    /'

    echo
    log "Results:"
    check_present \
      "Account shows ${SA_ID} (not a user ID)" \
      "${SA_ID}" \
      "${stmt_out}"

    stmt_status=$(echo "${stmt_out}" \
      | awk -F'|' '/\| Status[[:space:]]+\|/{gsub(/[[:space:]]/, "", $3); print $3; exit}')
    if [[ -n "${stmt_status}" ]]; then
      case "${stmt_status}" in
        RUNNING|COMPLETED)
          printf "    ✓  Status: %s\n" "${stmt_status}"
          pass_count=$((pass_count + 1))
          ;;
        FAILED)
          printf "    ✗  Status: %s  ← check the statement's Logs tab for 'insufficient permissions'\n" "${stmt_status}"
          fail_count=$((fail_count + 1))
          ;;
        *)
          printf "    !  Status: %s  (pending or transitional – re-run once it settles)\n" "${stmt_status}"
          ;;
      esac
    fi
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
if [[ ${fail_count} -eq 0 ]]; then
  printf "  Result: ALL %d CHECKS PASSED\n" "${pass_count}"
else
  printf "  Result: %d passed, %d failed\n" "${pass_count}" "${fail_count}"
  echo
  echo "  To apply missing bindings, run cc-sa-setup.sh or see README.md §2.1."
  echo "  For the Flink statement check, also verify in the Console:"
  echo "    Flink → Flink statements → [statement] → Account field and Logs tab."
fi
echo "═══════════════════════════════════════════════════════════════════"
