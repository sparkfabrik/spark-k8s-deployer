# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- [2026.08.13] - The deployer image ships `just`, pinned to 1.58.0 and verified against the release SHA256 before install. A recent version is required because it rejects justfile forms that older versions silently accept.
- [2026.08.13] - The package e2e (`.sparkfabrik-pkg-e2e-test`) now loads the generated root justfile with `just --list` after the project is generated, through the new `.sparkfabrik-pkg-e2e-test-validate-justfile` step. `test -f` and `grep -q` pass on a justfile that `just` refuses to load, so a broken recipe attribute in a package fragment (a comment between an attribute and its recipe) shipped green; this fails the pipeline instead, and covers the whole class of justfile syntax errors, in the project file or an imported package fragment.
- [2026.05.08] - New portable GitLab CI template `templates/functions/gke-kubeconfig.yml` (`.gke-kubeconfig`) that generates a namespace-scoped GKE kubeconfig using WIF-authenticated gcloud credentials. Activated when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set. Supports `K8S_USE_DNS_ENDPOINT=1` for private clusters. Runs after `setup-gitlab-agent` so the gcloud context always takes precedence. Remotely includable, no Docker image dependency.

### Fixed

- [2026.07.30] - `.cloudsql-database-dump` now runs `gcloud sql export sql` asynchronously and tracks the Cloud SQL operation until it reaches `DONE`, instead of waiting synchronously. The synchronous call gave up after about ten minutes and failed the job even when the export completed on the Google Cloud side, which was easy to hit because the dump is always gzip compressed. Two optional variables size the tracking loop, `OPERATION_WAIT_TIMEOUT` (default 300 seconds per wait) and `OPERATION_WAIT_MAX_RETRIES` (default 12), and the job now carries a `timeout: 2h` so GitLab does not stop it before the wait budget runs out.
- [2026.06.18] - `.gke-kubeconfig` now skips gracefully (without failing the job) when `gcloud` is not available in the job image or is not authenticated, instead of exiting non-zero. This prevents build and test jobs that inherit the global `before_script` but do not need cluster access from failing when `K8S_CLUSTER_NAME` is set as a global CI/CD variable. Generation is gated on `K8S_CLUSTER_NAME` alone and is no longer coupled to `ENABLE_GCP_WIF`, so any gcloud authentication method (WIF, runner service account, service account key) is supported. It still fails fast when `gcloud` is authenticated but a required variable is missing or `get-credentials` fails.

### Changed

- [2025.10.23] - add support for additional docker registry via `ADDITIONAL_DOCKER_REGISTRY` variable.
