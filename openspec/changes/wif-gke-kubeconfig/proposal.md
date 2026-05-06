## Why

The deployer currently supports kubeconfig generation only via static token credentials (`KUBE_URL` + `KUBE_TOKEN`) or via the GitLab Agent. Neither works with Workload Identity Federation (WIF), which eliminates static credentials in CI/CD pipelines. WIF authentication to GCP already exists in `gcp-wif.yml`, but there is no bridge from "authenticated to GCP" to "have a working kubeconfig scoped to a GKE cluster namespace."

## What Changes

- Extend `create_kubeconfig()` in `scripts/src/functions.bash` with a WIF+GKE branch: when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set, use `gcloud container clusters get-credentials` instead of token-based kubeconfig creation.
- Extend `ensure_deploy_variables()` in `scripts/src/functions.bash` with a WIF+GKE branch: validate GKE-specific variables (`K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `KUBE_NAMESPACE`) instead of `KUBE_URL`/`KUBE_TOKEN`.
- Wire a gated `create_kubeconfig` call in `templates/.gitlab-ci-template.yml` after `setup-gitlab-agent`, executing only when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set.
- Support `K8S_USE_DNS_ENDPOINT=1` to conditionally pass `--dns-endpoint` to `gcloud container clusters get-credentials` (for private GKE clusters using DNS endpoint access).
- Scope the resulting kubeconfig to `$KUBE_NAMESPACE` via `kubectl config set-context --current --namespace`.

## Capabilities

### New Capabilities

- `wif-gke-kubeconfig`: Kubeconfig generation for GKE clusters using WIF-based gcloud authentication, with namespace scoping and optional DNS endpoint support.

### Modified Capabilities

- `kubeconfig-creation`: The existing `create_kubeconfig()` and `ensure_deploy_variables()` functions gain a second execution path; the legacy token-based path is unchanged.

## Impact

- `scripts/src/functions.bash`: Two functions extended (`create_kubeconfig`, `ensure_deploy_variables`).
- `templates/.gitlab-ci-template.yml`: One new gated call added to the `.default-setup` before_script block.
- No changes to `gcp-wif.yml`, `setup-gitlab-agent()`, or any other templates.
- Backward compatible: pipelines without `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` are unaffected.
- Depends on CI/CD variables injected by the platform generator (see board#4348): `ENABLE_GCP_WIF`, `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `K8S_USE_DNS_ENDPOINT`, `KUBE_NAMESPACE`.
