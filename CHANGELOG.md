# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- [2026.05.08] - New portable GitLab CI template `templates/functions/gke-kubeconfig.yml` (`.gke-kubeconfig`) that generates a namespace-scoped GKE kubeconfig using WIF-authenticated gcloud credentials. Activated when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set. Supports `K8S_USE_DNS_ENDPOINT=1` for private clusters. Runs after `setup-gitlab-agent` so the gcloud context always takes precedence. Remotely includable, no Docker image dependency.

### Changed

- [2025.10.23] - add support for additional docker registry via `ADDITIONAL_DOCKER_REGISTRY` variable.
