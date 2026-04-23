# Flink Service Account – RBAC Reference

<img src="../../images/shield_check.png" alt="Confluent Utility - SA Check" height="100px" style="float: left; margin-right: 20px;">


A Flink service account (SA) needs role bindings at three different scopes before it can successfully submit and run statements. Missing any one of them produces an *"insufficient permissions"* error even when the others are present.

## Required role bindings

| Scope | Role | Resource | Notes |
|---|---|---|---|
| Environment | `FlinkDeveloper` | — | Control-plane access; required for all statement operations |
| Kafka cluster | `DeveloperRead` | `Transactional-Id:_confluent-flink_` (prefix) | Exactly-once semantics |
| Kafka cluster | `DeveloperWrite` | `Transactional-Id:_confluent-flink_` (prefix) | Exactly-once semantics |
| Kafka cluster | `DeveloperRead` | `Topic:<source-topic>` | Required for SELECT |
| Kafka cluster | `DeveloperWrite` | `Topic:<sink-topic>` | Required for INSERT INTO / CTAS |
| Kafka cluster | `DeveloperManage` | `Topic:<prefix>` (prefix) | Required for CREATE TABLE / ALTER TABLE |
| Schema Registry | `DeveloperRead` | `Subject:<prefix>` (prefix) | Avro / Protobuf / JSON Schema reads |
| Schema Registry | `DeveloperWrite` | `Subject:<prefix>` (prefix) | Schema registration on write |

> **Tip:** The Schema Registry bindings are only required when topics use a schema format. Plain JSON without a schema does not need them.

---

## `cc-sa-check.sh` – inspect an existing SA

Read-only diagnostic script. It runs `confluent iam rbac role-binding list` at each required scope, prints the raw CLI output, and marks each expected binding as `✓` (found) or `✗` (missing). Makes no changes to your environment.

### Prerequisites

```bash
confluent login
confluent environment use <ENV_ID>
# jq – only needed when STATEMENT_NAME is set (auto-derives Flink cloud/region)
brew install jq
```

### Configuration

Set variables at the top of the script, or export them before running.

| Variable | Required | Description |
|---|---|---|
| `SA_ID` | yes | Service account ID to inspect, e.g. `sa-abc123` |
| `ENV_ID` | yes | Environment ID, e.g. `env-abc123` |
| `KAFKA_ID` | yes | Kafka cluster ID used as the Flink database, e.g. `lkc-abc123` |
| `SR_ID` | no | Schema Registry cluster ID; omit to skip the SR check |
| `STATEMENT_NAME` | no | Flink statement name; omit to skip the statement principal check |
| `COMPUTE_POOL_ID` | no | Used to auto-derive `CLOUD_PROVIDER_ID`/`CLOUD_PROVIDER_REGION` for the statement check |
| `CLOUD_PROVIDER_ID` | no | Override cloud provider, e.g. `aws` (auto-derived from `COMPUTE_POOL_ID` if set) |
| `CLOUD_PROVIDER_REGION` | no | Override region, e.g. `us-east-2` (auto-derived from `COMPUTE_POOL_ID` if set) |
| `TEST_TOPIC` | no | Topic name expected to have bindings (default: `flink_sa_test`) |
| `TABLE_PREFIX` | no | Topic/subject prefix expected to have bindings (default: `flink_sa_`) |

### Usage

**Minimum (required variables only):**

```bash
export SA_ID=sa-abc123 ENV_ID=env-abc123 KAFKA_ID=lkc-abc123
./cc-sa-check.sh
```

**Including Schema Registry:**

```bash
export SA_ID=sa-abc123 ENV_ID=env-abc123 KAFKA_ID=lkc-abc123 SR_ID=lsrc-abc123
./cc-sa-check.sh
```

**Including a statement principal check:**

```bash
export SA_ID=sa-abc123 ENV_ID=env-abc123 KAFKA_ID=lkc-abc123 \
  STATEMENT_NAME=my-flink-statement COMPUTE_POOL_ID=lfcp-abc123
./cc-sa-check.sh
```

### Sample output

```
Confluent Flink SA role-binding check
  SA:                  sa-abc123
  Environment:         env-abc123
  Kafka cluster:       lkc-abc123
  Schema Registry:     lsrc-abc123

── Check 1 – Environment-level bindings (FlinkDeveloper)
  ...
    ✓  FlinkDeveloper at environment scope

── Check 2 – Kafka cluster-level bindings (Transactional-Id and Topics)
  ...
    ✓  DeveloperRead  on Transactional-Id:_confluent-flink_ (prefix)
    ✓  DeveloperWrite on Transactional-Id:_confluent-flink_ (prefix)
    ✓  DeveloperRead  on Topic:flink_sa_test
    ✓  DeveloperWrite on Topic:flink_sa_test
    ✗  DeveloperManage on Topic:flink_sa_ (prefix)  ← NOT FOUND

── Check 3 – Schema Registry bindings (Subjects)
  ...
    ✓  DeveloperRead  on Subject:flink_sa_ (Cluster Type: Schema Registry, Logical Cluster: lsrc-abc123)
    ✓  DeveloperWrite on Subject:flink_sa_ (Cluster Type: Schema Registry, Logical Cluster: lsrc-abc123)

═══════════════════════════════════════════════════════════════════
  Result: 6 passed, 1 failed

  To apply missing bindings, run cc-sa-setup.sh or see the manual steps below.
═══════════════════════════════════════════════════════════════════
```

A `✗` line points directly to the missing binding. Run `cc-sa-setup.sh` (see below) to apply it, or add it manually with `confluent iam rbac role-binding create`.

---

## `cc-sa-setup.sh` – create an SA and validate end-to-end *(bonus)*

End-to-end script that creates a new service account (or reuses an existing one), applies all required role bindings, creates a sandbox Kafka topic, and runs a smoke-test Flink SELECT statement to prove the full permission chain works. Idempotent: re-running it skips resources and bindings that already exist.

### Prerequisites

```bash
confluent login
brew install jq
```

### Configuration

| Variable | Required | Description |
|---|---|---|
| `ENV_ID` | yes | Environment ID |
| `KAFKA_ID` | yes | Kafka cluster ID |
| `SA_ID` | no | Reuse an existing SA by ID; leave empty to look up or create by `SA_NAME` |
| `SA_NAME` | no | Name for the new SA (default: `flink-sa-demo`) |
| `SR_ID` | no | Schema Registry cluster ID; omit to skip SR bindings |
| `USER_ID` | no | Your user ID; grants you the `Assigner` role so you can attach this SA to statements |
| `COMPUTE_POOL_ID` | no | Flink compute pool ID; required for the smoke-test step |
| `TEST_TOPIC` | no | Sandbox Kafka topic name (default: `flink_sa_test`) |
| `TABLE_PREFIX` | no | Topic/subject prefix for `DeveloperManage` and SR bindings (default: `flink_sa_`) |
| `SKIP_TOPIC_CREATE` | no | `true` to skip topic creation if it already exists externally |
| `SKIP_SR_BINDINGS` | no | `true` to skip Schema Registry bindings even if `SR_ID` is set |
| `RUN_SMOKE_TEST` | no | `false` to skip the Flink statement smoke test (default: `true`) |
| `CLEANUP_TEST_RESOURCES` | no | `true` to delete the test topic and statement at the end (default: `false`) |

### Usage

**Create a new SA with Kafka bindings only:**

```bash
export ENV_ID=env-abc123 KAFKA_ID=lkc-abc123
./cc-sa-setup.sh
```

**Reuse an existing SA, add Schema Registry bindings, run smoke test:**

```bash
export ENV_ID=env-abc123 KAFKA_ID=lkc-abc123 SR_ID=lsrc-abc123 \
  SA_ID=sa-abc123 USER_ID=u-abc123 COMPUTE_POOL_ID=lfcp-abc123
./cc-sa-setup.sh
```

**Run end-to-end and clean up test resources when done:**

```bash
export ENV_ID=env-abc123 KAFKA_ID=lkc-abc123 COMPUTE_POOL_ID=lfcp-abc123 \
  CLEANUP_TEST_RESOURCES=true
./cc-sa-setup.sh
```

### What it does (step by step)

| Step | Action |
|---|---|
| 1 | Create or look up the service account |
| 2 | Bind `FlinkDeveloper` at environment scope |
| 3 | Bind `DeveloperRead`/`Write` on `Transactional-Id:_confluent-flink_` (prefix) |
| 4 | Create the sandbox Kafka topic |
| 5 | Bind `DeveloperRead`/`Write` on the topic; `DeveloperManage` on the topic prefix |
| 5b | *(if `SR_ID` set)* Bind `DeveloperRead`/`Write` on Schema Registry subject prefix |
| 6 | *(if `USER_ID` set)* Grant you the `Assigner` role on the SA |
| 7 | *(if `COMPUTE_POOL_ID` set)* Submit a smoke-test `SELECT` and confirm status is COMPLETED |
| — | *(if `CLEANUP_TEST_RESOURCES=true`)* Delete the topic and statement |

After the setup succeeds, run `cc-sa-check.sh` with the same `SA_ID` to confirm all bindings are in place.

---

## References

- [Grant Role-Based Access for Flink SQL Statements](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/flink-rbac.html)
- [Predefined RBAC roles in Confluent Cloud](https://docs.confluent.io/cloud/current/security/access-control/rbac/predefined-rbac-roles.html)
- [Monitor and Manage Flink SQL Statements](https://docs.confluent.io/cloud/current/flink/operate-and-deploy/monitor-statements.html)
- [Manage workload identities on Confluent Cloud](https://docs.confluent.io/cloud/current/security/authenticate/workload-identities/manage-workload-identities.html)
