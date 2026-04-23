# Confluent Utility Belt

<img src="images/belt.png" alt="Confluent Utility Belt" height="100px" style="float: right;margin-left: 20px; margin-right: 20px;">

A collection of scripts and tools for operating and troubleshooting [Confluent Cloud](https://confluent.io) environments — covering IAM, Flink SQL, Kafka connectivity, and Kubernetes integrations.


## Tools

### [IAM / Service Account Checks](iam/service-account-checks/)

Shell scripts for managing and validating Confluent Cloud Flink service account RBAC bindings.

| Script | Description |
|---|---|
| `cc-sa-check.sh` | Read-only diagnostic — lists role bindings at every required scope and flags missing ones |
| `cc-sa-setup.sh` | End-to-end setup — creates a service account, applies all required bindings, and runs a smoke-test Flink statement |

---

### [Kubernetes / Kafka Connectivity Test](kubernetes/kafka-k8s-kcat-test/)

Kubernetes manifests and a step-by-step guide for validating network connectivity and authentication from a Kubernetes cluster (EKS, AKS, GKE, …) to a Confluent Cloud Kafka cluster using [kcat](https://github.com/edenhill/kcat).

Covers: network reachability, firewall rules, API key authentication, and topic-level access — before deploying heavier workloads.
