## 1. Revert `scripts/src/functions.bash`

- [x] 1.1 Revert `create_kubeconfig()` to pre-change state: remove WIF+GKE branch, restore legacy token-only path
- [x] 1.2 Revert `ensure_deploy_variables()` to pre-change state: remove WIF+GKE branch, restore original legacy variable checks only

## 2. Create `templates/functions/gke-kubeconfig.yml`

- [x] 2.1 Define `check_gke_env()`: validate `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `KUBE_NAMESPACE` — print descriptive error and return 1 on any missing variable
- [x] 2.2 Define `generate_gke_kubeconfig()`: build `gcloud container clusters get-credentials` command as an array, conditionally append `--dns-endpoint` when `K8S_USE_DNS_ENDPOINT=1`, execute it, then call `kubectl config set-context --current --namespace="${KUBE_NAMESPACE}"`
- [x] 2.3 Add main execution block: emit `section_start "gke-kubeconfig" "GKE Kubeconfig"` and `print-banner` calls, gate on `ENABLE_GCP_WIF=1 && K8S_CLUSTER_NAME` set, call `check_gke_env` then `generate_gke_kubeconfig`, emit skip message when condition not met, close with `section_end` and `print-banner`

## 3. Wire into `templates/.gitlab-ci-template.yml`

- [x] 3.1 Add remote `include:` entry for `gke-kubeconfig.yml`
- [x] 3.2 Add `!reference [.gke-kubeconfig, before_script]` as the last entry in `.global-setup before_script`, after `.default-setup`
- [x] 3.3 Remove the gated `create_kubeconfig` call previously added inside `.default-setup` after `setup-gitlab-agent`

## 4. Validation

- [ ] 4.1 Manually test the WIF+GKE path against a GKE cluster provisioned by the generator: confirm `kubectl get pods` returns project pods and `kubectl get pods -n kube-system` is denied
- [ ] 4.2 Confirm a pipeline without `ENABLE_GCP_WIF` continues to work with the legacy token path unchanged
- [ ] 4.3 Confirm a pipeline with `ENABLE_GCP_WIF=1` but without `K8S_CLUSTER_NAME` skips silently without errors
- [ ] 4.4 Confirm that when both GitLab Agent and WIF+GKE are configured, the gcloud context is active after `before_script` completes
- [ ] 4.5 Test `K8S_USE_DNS_ENDPOINT=1` on a private cluster to confirm `--dns-endpoint` is passed and connectivity succeeds

## 5. Documentation

- [x] 5.1 Update `README.md` to reflect the new template-based approach and remove any reference to WIF branches in `functions.bash`
- [x] 5.2 Update `CHANGELOG.md` with the revised feature entry
