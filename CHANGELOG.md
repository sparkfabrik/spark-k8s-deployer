# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- [2026.08.27] - New GitLab CI template `templates/functions/spark-k8s-cluster-resolver.yml` (`.spark-k8s-cluster-resolver`) that picks the target cluster at runtime from the git ref, out of the cluster list injected as the File type CI/CD variable `SPARK_K8S_CONFIG`, and exports `K8S_CLUSTER_NAME`, `GCP_PROJECT_ID`, `K8S_LOCATION` and `K8S_USE_DNS_ENDPOINT` for `.gke-kubeconfig`. The `clusters` list is scanned bottom-up, the last declared match wins and an unmatched ref falls back to the `default: true` entry. Patterns are globs, where `*` does not cross a slash and `**` does, or regular expressions when wrapped in slashes. Refs are normalized to `refs/heads/<branch>` or `refs/tags/<tag>`, so a tag never matches a branch rule. Wired into `.global-setup` before `.default-setup`. While `SPARK_K8S_CONFIG` is set the resolver owns the exported `K8S_*` variables and clears them before resolving, so a ref that owns no cluster cannot inherit them from plain CI/CD variables. It is a no-op when `SPARK_K8S_CONFIG` is unset, and skips without failing in job images that ship neither the deployer scripts, nor `bash`, nor `yq4`.
- [2026.08.27] - New `.spark-k8s-require-cluster` script reference that ends a cluster-dependent job successfully when no cluster owns the current ref, which is the case on merge request pipelines.
- [2026.08.27] - New cluster resolver test suite under `test/cluster-resolver`, runnable with `make test-cluster-resolver`, plus a `cluster-resolver` GitHub Actions job that lints the resolver scripts with `shellcheck` and runs the suite on every push and pull request.
- [2026.08.13] - The deployer image ships `just`, pinned to 1.58.0 and verified against the release SHA256 before install. A recent version is required because it rejects justfile forms that older versions silently accept.
- [2026.08.13] - The package e2e (`.sparkfabrik-pkg-e2e-test`) now loads the generated root justfile with `just --list` after the project is generated, through the new `.sparkfabrik-pkg-e2e-test-validate-justfile` step. `test -f` and `grep -q` pass on a justfile that `just` refuses to load, so a broken recipe attribute in a package fragment (a comment between an attribute and its recipe) shipped green; this fails the pipeline instead, and covers the whole class of justfile syntax errors, in the project file or an imported package fragment.
- [2026.05.08] - New portable GitLab CI template `templates/functions/gke-kubeconfig.yml` (`.gke-kubeconfig`) that generates a namespace-scoped GKE kubeconfig using WIF-authenticated gcloud credentials. Activated when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set. Supports `K8S_USE_DNS_ENDPOINT=1` for private clusters. Runs after `setup-gitlab-agent` so the gcloud context always takes precedence. Remotely includable, no Docker image dependency.

### Fixed

- [2026.07.30] - `.cloudsql-database-dump` now runs `gcloud sql export sql` asynchronously and tracks the Cloud SQL operation until it reaches `DONE`, instead of waiting synchronously. The synchronous call gave up after about ten minutes and failed the job even when the export completed on the Google Cloud side, which was easy to hit because the dump is always gzip compressed. Two optional variables size the tracking loop, `OPERATION_WAIT_TIMEOUT` (default 300 seconds per wait) and `OPERATION_WAIT_MAX_RETRIES` (default 12), and the job now carries a `timeout: 2h` so GitLab does not stop it before the wait budget runs out.
- [2026.06.18] - `.gke-kubeconfig` now skips gracefully (without failing the job) when `gcloud` is not available in the job image or is not authenticated, instead of exiting non-zero. This prevents build and test jobs that inherit the global `before_script` but do not need cluster access from failing when `K8S_CLUSTER_NAME` is set as a global CI/CD variable. Generation is gated on `K8S_CLUSTER_NAME` alone and is no longer coupled to `ENABLE_GCP_WIF`, so any gcloud authentication method (WIF, runner service account, service account key) is supported. It still fails fast when `gcloud` is authenticated but a required variable is missing or `get-credentials` fails.

### Changed

- [2026.08.27] - `setup-gitlab-agent` returns early while `SPARK_K8S_CONFIG` is set, so the cluster resolver and the GitLab Agent path are mutually exclusive. Agent variables set alongside the resolver are reported in the job log and ignored.
- [2026.08.27] - `.stop-deployment-template` and `.helm-rollback-template` no longer override `before_script` with an empty list: they now reference `.gitlab-helper-functions`, `.gcp-wif`, `.spark-k8s-cluster-resolver` and `.gke-kubeconfig`, and guard their script with `.spark-k8s-require-cluster`. Projects that include either job template on its own must also include those function templates.
- [2025.10.23] - add support for additional docker registry via `ADDITIONAL_DOCKER_REGISTRY` variable.
