# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- [2026.05.04] - WIF+GKE kubeconfig generation: `create_kubeconfig()` now supports a Workload Identity Federation path activated when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set. Uses `gcloud container clusters get-credentials` to generate a namespace-scoped kubeconfig with no static credentials. Supports `K8S_USE_DNS_ENDPOINT=1` for private GKE clusters using DNS endpoint access.

### Changed

- [2026.05.04] - `ensure_deploy_variables()` now validates GKE-specific variables (`K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `KUBE_NAMESPACE`) when running in WIF+GKE mode, instead of `KUBE_URL`/`KUBE_TOKEN`.
- [2025.10.23] - add support for additional docker registry via `ADDITIONAL_DOCKER_REGISTRY` variable.
