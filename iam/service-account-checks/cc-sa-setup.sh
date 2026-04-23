#!/usr/bin/env bash
# Confluent Flink Service Account – end-to-end setup (Section 2.1 of README.md)
#
# Prerequisites:
#   confluent login
#   confluent environment use <ENV_ID>   (or set ENV_ID below – the script does this automatically)
#   jq installed (brew install jq)
#
# Usage – either edit the defaults below, or export variables before running:
#   export ENV_ID=env-abc123 KAFKA_ID=lkc-abc123 ...
#   ./cc-sa-setup.sh
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
# Required
ENV_ID="${ENV_ID:-}"        # confluent environment list
KAFKA_ID="${KAFKA_ID:-}"    # confluent kafka cluster list

# Optional – leave empty to skip the associated step
SR_ID="${SR_ID:-}"              # Schema Registry cluster ID; empty → skip SR bindings
USER_ID="${USER_ID:-}"          # Your user ID (confluent iam user list); empty → skip Assigner step
COMPUTE_POOL_ID="${COMPUTE_POOL_ID:-}"  # Flink compute pool; empty → skip smoke test

# Flink routing – cloud/region used by describe/delete to reach the correct API
# endpoint. Leave empty to auto-derive from COMPUTE_POOL_ID (done in Step 7).
CLOUD_PROVIDER_ID="${CLOUD_PROVIDER_ID:-}"      # e.g. aws | azure | gcp
CLOUD_PROVIDER_REGION="${CLOUD_PROVIDER_REGION:-}"  # e.g. us-east-2

# Service account
# Set SA_ID to reuse an existing SA; leave empty to look up by SA_NAME or create a new one.
SA_NAME="${SA_NAME:-flink-sa-demo}"
SA_DESCRIPTION="${SA_DESCRIPTION:-Demo SA for Flink permissions debugging}"
SA_ID="${SA_ID:-}"

# Topic / table-prefix used for permissions and smoke test
TEST_TOPIC="${TEST_TOPIC:-flink_sa_test}"
TABLE_PREFIX="${TABLE_PREFIX:-flink_sa_}"

# Smoke-test statement name (must be unique within the environment and temporary as it will be cleaned up in the end)
STATEMENT_NAME="${STATEMENT_NAME:-flink-sa-smoke-test}"

# Feature flags
SKIP_TOPIC_CREATE="${SKIP_TOPIC_CREATE:-false}"      # true → skip kafka topic create
SKIP_SR_BINDINGS="${SKIP_SR_BINDINGS:-false}"        # true → skip Schema Registry bindings
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-true}"             # false → skip Step 7
CLEANUP_TEST_RESOURCES="${CLEANUP_TEST_RESOURCES:-false}"  # true → delete TEST_TOPIC and STATEMENT_NAME at the end
# ──────────────────────────────────────────────────────────────────────────────

# ── Helpers ────────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
step() { echo; printf '── Step %s ──────────────────────────────────────────\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# Try to create a role binding; skip quietly if it already exists, fail loudly otherwise.
# Always prints the raw CLI output so silent exit-0 failures are visible.
bind_role() {
  local desc="$1"; shift
  log "Binding: ${desc}"
  local output exit_code=0
  output=$(confluent iam rbac role-binding create "$@" 2>&1) || exit_code=$?
  if [[ ${exit_code} -eq 0 ]]; then
    log "  Created."
    [[ -n "${output}" ]] && printf '%s\n' "${output}" | sed 's/^/    /'
  elif echo "${output}" | grep -qi "already exist\|is already\|duplicate\|conflict"; then
    log "  Already exists, skipping."
  else
    log "  ERROR – binding was NOT applied. Details:"
    printf '%s\n' "${output}" | sed 's/^/    /' >&2
    return 1
  fi
}
# ──────────────────────────────────────────────────────────────────────────────

# ── Pre-flight checks ──────────────────────────────────────────────────────────
[[ -z "${ENV_ID}" ]]   && die "ENV_ID is required. Set it at the top of this script or export it."
[[ -z "${KAFKA_ID}" ]] && die "KAFKA_ID is required. Set it at the top of this script or export it."

command -v confluent >/dev/null 2>&1 \
  || die "confluent CLI not found. See: https://docs.confluent.io/confluent-cli/current/install.html"
command -v jq >/dev/null 2>&1 \
  || die "jq is required for JSON parsing. Install with: brew install jq"
# ──────────────────────────────────────────────────────────────────────────────

echo "Confluent Flink SA setup  |  env: ${ENV_ID}  |  kafka: ${KAFKA_ID}"
confluent environment use "${ENV_ID}"

# ── Step 1: Service account ────────────────────────────────────────────────────
step "1 – Service account"
log "Purpose: create (or reuse) the identity that Flink statements will run as."
if [[ -n "${SA_ID}" ]]; then
  log "Using pre-configured SA_ID=${SA_ID}."
else
  log "Looking up service account named '${SA_NAME}'..."
  SA_ID=$(confluent iam service-account list --output json \
    | jq -r --arg n "${SA_NAME}" '.[] | select(.name == $n) | .id' \
    | head -1)
  if [[ -n "${SA_ID}" ]]; then
    log "Found existing SA: ${SA_ID}"
  else
    log "Creating service account '${SA_NAME}'..."
    log "What you should expect to see: a table with the new SA's ID and name."
    log "  The ID (e.g. sa-abc123) is captured automatically and used as the principal in all subsequent steps."
    SA_ID=$(confluent iam service-account create "${SA_NAME}" \
      --description "${SA_DESCRIPTION}" \
      --output json | jq -r '.id')
    log "Created SA: ${SA_ID}"
  fi
fi
log "SA_ID = ${SA_ID}"

# ── Step 2: FlinkDeveloper at environment scope ────────────────────────────────
step "2 – FlinkDeveloper (environment scope)"
log "Purpose: grant Flink control-plane access so the SA can submit and manage statements."
log "What you should expect to see: 'Created' (or 'Already exists' on re-runs)."
log "  Verify: confluent iam rbac role-binding list --principal User:${SA_ID} --environment ${ENV_ID}"
log "  → A row with Role=FlinkDeveloper, Scope=Environment ${ENV_ID}"
bind_role "FlinkDeveloper on env ${ENV_ID}" \
  --environment "${ENV_ID}" \
  --principal "User:${SA_ID}" \
  --role FlinkDeveloper

# ── Step 3: Transactional-ID permissions (required for exactly-once semantics) ─
step "3 – Transactional-ID permissions"
log "Purpose: grant read/write access to Flink's internal transaction state."
log "  These are required for exactly-once semantics in INSERT INTO and CTAS statements."
log "  Without them, statements fail even if FlinkDeveloper is present."
log "What you should expect to see: two 'Created' confirmations (DeveloperRead and DeveloperWrite)."
log "  Verify: confluent iam rbac role-binding list --principal User:${SA_ID} \\"
log "            --environment ${ENV_ID} --cloud-cluster ${KAFKA_ID} --inclusive"
log "  → Rows with DeveloperRead and DeveloperWrite on Transactional-Id:_confluent-flink_ (prefix)"
bind_role "DeveloperRead on Transactional-Id:_confluent-flink_ (prefix)" \
  --role DeveloperRead \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" \
  --cloud-cluster "${KAFKA_ID}" \
  --kafka-cluster "${KAFKA_ID}" \
  --resource "Transactional-Id:_confluent-flink_" \
  --prefix

bind_role "DeveloperWrite on Transactional-Id:_confluent-flink_ (prefix)" \
  --role DeveloperWrite \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" \
  --cloud-cluster "${KAFKA_ID}" \
  --kafka-cluster "${KAFKA_ID}" \
  --resource "Transactional-Id:_confluent-flink_" \
  --prefix

log "Verifying transactional-ID bindings are present in the system:"
confluent iam rbac role-binding list --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" --cloud-cluster "${KAFKA_ID}" --inclusive \
  || log "  WARNING: list returned non-zero (CLI may report this when no results exist yet)."

# ── Step 4: Test topic ─────────────────────────────────────────────────────────
step "4 – Test topic: ${TEST_TOPIC}"
log "Purpose: create a sandbox Kafka topic to use as the source table in the smoke-test SELECT."
log "What you should expect to see: topic created successfully, or 'already exists' on re-runs."
if [[ "${SKIP_TOPIC_CREATE}" == "true" ]]; then
  log "SKIP_TOPIC_CREATE=true – skipping."
elif confluent kafka topic describe "${TEST_TOPIC}" \
     --cluster "${KAFKA_ID}" \
     --environment "${ENV_ID}" \
     >/dev/null 2>&1; then
  log "Topic '${TEST_TOPIC}' already exists."
else
  log "Creating topic '${TEST_TOPIC}'..."
  confluent kafka topic create "${TEST_TOPIC}" \
    --cluster "${KAFKA_ID}" \
    --environment "${ENV_ID}"
  log "Created."
fi

# ── Step 5: Topic and Schema Registry permissions ──────────────────────────────
step "5 – Topic permissions (${TEST_TOPIC} | prefix ${TABLE_PREFIX})"
log "Purpose: grant the SA data-plane access to the test topic and a topic prefix."
log "  DeveloperRead  on Topic:${TEST_TOPIC}    – required for SELECT queries."
log "  DeveloperWrite on Topic:${TEST_TOPIC}    – required for INSERT INTO and CTAS."
log "  DeveloperManage on Topic:${TABLE_PREFIX} (prefix) – required for CREATE TABLE / ALTER TABLE."
log "What you should expect to see: three 'Created' confirmations."
log "  Verify: confluent iam rbac role-binding list --principal User:${SA_ID} \\"
log "            --environment ${ENV_ID} --cloud-cluster ${KAFKA_ID} --inclusive "
log "  → Rows for DeveloperRead and DeveloperWrite on Topic:${TEST_TOPIC},"
log "    and DeveloperManage on Topic:${TABLE_PREFIX} (prefix)"
bind_role "DeveloperRead on Topic:${TEST_TOPIC}" \
  --role DeveloperRead \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" \
  --cloud-cluster "${KAFKA_ID}" \
  --kafka-cluster "${KAFKA_ID}" \
  --resource "Topic:${TEST_TOPIC}"

bind_role "DeveloperWrite on Topic:${TEST_TOPIC}" \
  --role DeveloperWrite \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" \
  --cloud-cluster "${KAFKA_ID}" \
  --kafka-cluster "${KAFKA_ID}" \
  --resource "Topic:${TEST_TOPIC}"

bind_role "DeveloperManage on Topic:${TABLE_PREFIX} (prefix, for CREATE TABLE / CTAS)" \
  --role DeveloperManage \
  --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" \
  --cloud-cluster "${KAFKA_ID}" \
  --kafka-cluster "${KAFKA_ID}" \
  --resource "Topic:${TABLE_PREFIX}" \
  --prefix

log "Verifying topic bindings are present in the system:"
confluent iam rbac role-binding list --principal "User:${SA_ID}" \
  --environment "${ENV_ID}" --cloud-cluster "${KAFKA_ID}" --inclusive \
  || log "  WARNING: list returned non-zero (CLI may report this when no results exist yet)."

if [[ "${SKIP_SR_BINDINGS}" != "true" && -n "${SR_ID}" ]]; then
  step "5b – Schema Registry subject permissions (prefix ${TABLE_PREFIX})"
  log "Purpose: grant the SA access to Schema Registry subjects for schema validation on read/write."
  log "  DeveloperRead  – allows the SA to look up schemas when reading data."
  log "  DeveloperWrite – allows the SA to register schemas when writing data."
  log "What you should expect to see: two 'Created' confirmations."
  bind_role "DeveloperRead on Subject:${TABLE_PREFIX} (prefix)" \
    --role DeveloperRead \
    --principal "User:${SA_ID}" \
    --environment "${ENV_ID}" \
    --schema-registry-cluster "${SR_ID}" \
    --resource "Subject:${TABLE_PREFIX}" \
    --prefix

  bind_role "DeveloperWrite on Subject:${TABLE_PREFIX} (prefix)" \
    --role DeveloperWrite \
    --principal "User:${SA_ID}" \
    --environment "${ENV_ID}" \
    --schema-registry-cluster "${SR_ID}" \
    --resource "Subject:${TABLE_PREFIX}" \
    --prefix
fi

# ── Step 6: Assigner role so your user can attach this SA to Flink statements ──
step "6 – Assigner role"
if [[ -z "${USER_ID}" ]]; then
  log "USER_ID not set – skipping."
  log "Tip: run 'confluent iam user list', then set USER_ID and re-run."
  log "  Without this binding the Flink CLI/UI will not let you pick this SA when submitting statements."
else
  log "Purpose: allow user ${USER_ID} to submit Flink statements that run as this SA,"
  log "  while remaining logged in as themselves."
  log "What you should expect to see: 'Created' confirmation."
  log "  This lets you create statements that run with the SA's permissions while still logging in as yourself."
  bind_role "Assigner for user ${USER_ID} on ServiceAccount:${SA_ID}" \
    --principal "User:${USER_ID}" \
    --role Assigner \
    --resource "ServiceAccount:${SA_ID}"
fi

# ── Step 7: Smoke-test Flink statement ─────────────────────────────────────────
step "7 – Smoke-test Flink statement"
log "Purpose: validate the full permission chain by running a minimal SELECT under the SA's identity."
log "  This proves the pattern works before tightening to least-privilege."
if [[ "${RUN_SMOKE_TEST}" != "true" || -z "${COMPUTE_POOL_ID}" ]]; then
  log "Skipping smoke test."
  log "Set RUN_SMOKE_TEST=true and COMPUTE_POOL_ID to enable."
else
  # describe/delete route via the flink region context, not --compute-pool.
  # Auto-derive cloud/region from the compute pool when not explicitly set,
  # so the endpoint always matches where the statement was created.
  if [[ -z "${CLOUD_PROVIDER_ID}" || -z "${CLOUD_PROVIDER_REGION}" ]]; then
    log "Deriving Flink cloud/region from compute pool ${COMPUTE_POOL_ID}..."
    pool_json=$(confluent flink compute-pool describe "${COMPUTE_POOL_ID}" --output json)
    CLOUD_PROVIDER_ID=$(echo "${pool_json}" | jq -r '(.spec.cloud // .cloud // "") | ascii_downcase')
    CLOUD_PROVIDER_REGION=$(echo "${pool_json}" | jq -r '.spec.region // .region // ""')
    [[ -z "${CLOUD_PROVIDER_ID}" || -z "${CLOUD_PROVIDER_REGION}" ]] \
      && die "Could not derive cloud/region from compute pool. Set CLOUD_PROVIDER_ID and CLOUD_PROVIDER_REGION manually."
    log "  Cloud: ${CLOUD_PROVIDER_ID}  Region: ${CLOUD_PROVIDER_REGION}"
  fi
  confluent flink region use --cloud "${CLOUD_PROVIDER_ID}" --region "${CLOUD_PROVIDER_REGION}"

  run_create=true
  if stmt_output=$(confluent flink statement describe "${STATEMENT_NAME}" 2>/dev/null); then
    stmt_status=$(echo "${stmt_output}" \
      | awk -F'|' '/\| Status[[:space:]]+\|/{gsub(/[[:space:]]/, "", $3); print $3; exit}')
    if [[ "${stmt_status}" == "FAILED" ]]; then
      log "Statement '${STATEMENT_NAME}' is in FAILED state. Deleting to allow recreation..."
      confluent flink statement delete "${STATEMENT_NAME}" --force || true
    else
      log "Statement '${STATEMENT_NAME}' already exists (status: ${stmt_status:-unknown}):"
      echo "${stmt_output}"
      run_create=false
    fi
  fi

  if [[ "${run_create}" == "true" ]]; then
    SQL_CODE="SELECT * FROM \`${ENV_ID}\`.\`${KAFKA_ID}\`.\`${TEST_TOPIC}\` LIMIT 1;"
    log "Submitting: ${SQL_CODE}"
    log "What you should expect to see:"
    log "  Status: PENDING → RUNNING → COMPLETED, with no 'insufficient permissions' error."
    log "  In the describe output, the Account field should show '${SA_ID}', not your user ID."
    log "  If this SELECT succeeds but other DDL/DML still fails, the cause is almost always"
    log "  missing topic or subject role bindings for the specific tables in that query,"
    log "  not the FlinkDeveloper role itself."
    # --wait exits 0 even on FAILED; capture output to detect the status ourselves.
    create_output=$(confluent flink statement create "${STATEMENT_NAME}" \
      --service-account "${SA_ID}" \
      --compute-pool "${COMPUTE_POOL_ID}" \
      --database "${KAFKA_ID}" \
      --sql "${SQL_CODE}" \
      --wait 2>&1) || true
    echo "${create_output}"
    create_status=$(echo "${create_output}" \
      | awk -F'|' '/\| Status[[:space:]]+\|/{gsub(/[[:space:]]/, "", $3); print $3; exit}')
    if echo "${create_output}" | grep -qi "^Error:"; then
      log "Statement creation failed (see error above)."
    elif [[ "${create_status}" == "FAILED" ]]; then
      log "Statement ended in FAILED state. Dumping SA role bindings for diagnostics:"
      log "  Environment-level (FlinkDeveloper):"
      confluent iam rbac role-binding list --principal "User:${SA_ID}" --environment "${ENV_ID}"
      log "  Kafka cluster-level (transactional-id, topic):"
      confluent iam rbac role-binding list --principal "User:${SA_ID}" \
        --environment "${ENV_ID}" --cloud-cluster "${KAFKA_ID}" --kafka-cluster "${KAFKA_ID}"
    else
      log "Confirming Account field shows the SA (not your user):"
      confluent flink statement describe "${STATEMENT_NAME}"
    fi
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════════"
printf "  %-22s %s\n" "SA_ID:"           "${SA_ID}"
printf "  %-22s %s\n" "SA_NAME:"         "${SA_NAME}"
printf "  %-22s %s\n" "ENV_ID:"          "${ENV_ID}"
printf "  %-22s %s\n" "KAFKA_ID:"        "${KAFKA_ID}"
[[ -n "${SR_ID}" ]]           && printf "  %-22s %s\n" "SR_ID:"           "${SR_ID}"
[[ -n "${USER_ID}" ]]         && printf "  %-22s %s\n" "USER_ID:"         "${USER_ID}"
[[ -n "${COMPUTE_POOL_ID}" ]] && printf "  %-22s %s\n" "COMPUTE_POOL_ID:" "${COMPUTE_POOL_ID}"
printf "  %-22s %s\n" "TEST_TOPIC:"      "${TEST_TOPIC}"
printf "  %-22s %s\n" "TABLE_PREFIX:"    "${TABLE_PREFIX}"
echo "═══════════════════════════════════════════════════════════════════"
echo "Verify role bindings with:"
echo "  # Environment-level (FlinkDeveloper):"
echo "  confluent iam rbac role-binding list --principal User:${SA_ID} --environment ${ENV_ID}"
echo "  # Kafka cluster-level (transactional-id, topic):"
echo "  confluent iam rbac role-binding list --principal User:${SA_ID} --environment ${ENV_ID} --cloud-cluster ${KAFKA_ID} --inclusive"

# ── Cleanup (optional) ─────────────────────────────────────────────────────────
if [[ "${CLEANUP_TEST_RESOURCES}" != "true" ]]; then
  exit 0
fi

step "Cleanup – removing test resources"
log "CLEANUP_TEST_RESOURCES=true – deleting the Flink statement and Kafka topic created during this run."
log "The service account and its role bindings are kept; only the sandbox resources are removed."

# Flink statement – requires the regional endpoint to be configured.
if [[ -z "${COMPUTE_POOL_ID}" ]]; then
  log "COMPUTE_POOL_ID not set – skipping Flink statement cleanup."
else
  # Re-derive cloud/region if Step 7 was skipped and the variables were never populated.
  if [[ -z "${CLOUD_PROVIDER_ID}" || -z "${CLOUD_PROVIDER_REGION}" ]]; then
    log "Re-deriving Flink cloud/region from compute pool ${COMPUTE_POOL_ID} for cleanup..."
    pool_json=$(confluent flink compute-pool describe "${COMPUTE_POOL_ID}" --output json)
    CLOUD_PROVIDER_ID=$(echo "${pool_json}" | jq -r '(.spec.cloud // .cloud // "") | ascii_downcase')
    CLOUD_PROVIDER_REGION=$(echo "${pool_json}" | jq -r '.spec.region // .region // ""')
  fi
  confluent flink region use --cloud "${CLOUD_PROVIDER_ID}" --region "${CLOUD_PROVIDER_REGION}" 2>/dev/null || true

  log "Deleting Flink statement '${STATEMENT_NAME}'..."
  log "What you should expect to see: deletion confirmed, or 'not found' if already removed."
  if confluent flink statement delete "${STATEMENT_NAME}" --force 2>/dev/null; then
    log "  Deleted."
  else
    log "  Not found or already deleted – skipping."
  fi
fi

# Kafka topic
log "Deleting Kafka topic '${TEST_TOPIC}'..."
log "What you should expect to see: deletion confirmed, or 'not found' if already removed."
if confluent kafka topic delete "${TEST_TOPIC}" \
     --cluster "${KAFKA_ID}" --force \
     --environment "${ENV_ID}" 2>/dev/null; then
  log "  Deleted."
else
  log "  Not found or already deleted – skipping."
fi
