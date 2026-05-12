## Why

The deployer currently supports kubeconfig generation only via static token credentials (`KUBE_URL` + `KUBE_TOKEN`) or via the GitLab Agent. Neither works with Workload Identity Federation (WIF), which eliminates static credentials in CI/CD pipelines. WIF authentication to GCP already exists in `gcp-wif.yml`, but there is no bridge from "authenticated to GCP" to "have a working kubeconfig scoped to a GKE cluster namespace."

## What Changes

- Add a new self-contained GitLab CI template `templates/functions/gke-kubeconfig.yml` (`.gke-kubeconfig`) that generates a namespace-scoped GKE kubeconfig using WIF-authenticated gcloud credentials.
- Wire `.gke-kubeconfig` as the last step in the `.global-setup` `before_script` chain in `templates/.gitlab-ci-template.yml`, after `setup-gitlab-agent`, so the gcloud context always overrides the agent context when WIF+GKE is configured.
- Revert the WIF branches added to `create_kubeconfig()` and `ensure_deploy_variables()` in `scripts/src/functions.bash` — those functions return to their original legacy token-based state.
- Support `K8S_USE_DNS_ENDPOINT=1` to conditionally pass `--dns-endpoint` to `gcloud container clusters get-credentials` (for private GKE clusters using DNS endpoint access).
- Scope the resulting kubeconfig to `$KUBE_NAMESPACE` via `kubectl config set-context --current --namespace`.

## Capabilities

### New Capabilities

- `wif-gke-kubeconfig`: A portable, remotely-includable GitLab CI template that generates a namespace-scoped kubeconfig for GKE clusters using WIF-based gcloud authentication, with optional DNS endpoint support and CI log banner section.

### Modified Capabilities

- `kubeconfig-creation`: The `create_kubeconfig()` and `ensure_deploy_variables()` functions in `scripts/src/functions.bash` are reverted to legacy token-based only — no WIF awareness in the image scripts.

## Impact

- `templates/functions/gke-kubeconfig.yml`: New file. Self-contained, remotely includable, no Docker image dependency.
- `templates/.gitlab-ci-template.yml`: New remote `include:` entry + `!reference [.gke-kubeconfig, before_script]` added as last step in `.global-setup`. Gated `create_kubeconfig` call previously added to `.default-setup` is removed.
- `scripts/src/functions.bash`: `create_kubeconfig()` and `ensure_deploy_variables()` reverted to pre-change state.
- Backward compatible: pipelines without `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` are unaffected — the template skips silently.
- Depends on CI/CD variables injected by the platform generator (see board#4348): `ENABLE_GCP_WIF`, `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `K8S_USE_DNS_ENDPOINT`, `KUBE_NAMESPACE`.
