## 1. Extend `ensure_deploy_variables()`

- [x] 1.1 Add WIF+GKE branch in `scripts/src/functions.bash`: when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set, validate `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, and `KUBE_NAMESPACE` instead of `KUBE_URL`/`KUBE_TOKEN`
- [x] 1.2 Verify legacy path is unchanged: pipelines without `ENABLE_GCP_WIF=1` still validate `KUBE_URL`, `KUBE_TOKEN`, `KUBE_NAMESPACE`, `CI_ENVIRONMENT_SLUG`, `CI_ENVIRONMENT_URL`

## 2. Extend `create_kubeconfig()`

- [x] 2.1 Add WIF+GKE branch in `scripts/src/functions.bash`: when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set, build and run `gcloud container clusters get-credentials $K8S_CLUSTER_NAME --location $K8S_LOCATION --project $GCP_PROJECT_ID` using an array (not `eval`) to avoid word-splitting
- [x] 2.2 Conditionally append `--dns-endpoint` when `K8S_USE_DNS_ENDPOINT=1`
- [x] 2.3 Scope the kubeconfig context to `$KUBE_NAMESPACE` via `kubectl config set-context --current --namespace=$KUBE_NAMESPACE`
- [x] 2.4 Verify legacy token-based path is unchanged when WIF+GKE condition is not met

## 3. Wire into `.gitlab-ci-template.yml`

- [x] 3.1 In `templates/.gitlab-ci-template.yml`, after the `setup-gitlab-agent` section block, add a gated call to `create_kubeconfig` that runs only when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set
- [x] 3.2 Wrap the call in a `section_start`/`section_end` block (label: `kubeconfig`, title: `Generate kubeconfig`) consistent with surrounding sections

## 4. Validation

- [ ] 4.1 Manually test the WIF+GKE path against a GKE cluster provisioned by the generator: confirm `kubectl get pods` returns project pods and `kubectl get pods -n kube-system` is denied (or returns empty/error due to namespace scoping)
- [ ] 4.2 Confirm a pipeline without `ENABLE_GCP_WIF` continues to work with the legacy token path
- [ ] 4.3 Confirm a pipeline with `ENABLE_GCP_WIF=1` but without `K8S_CLUSTER_NAME` falls back to the legacy path without errors
- [ ] 4.4 Test `K8S_USE_DNS_ENDPOINT=1` on a private cluster to confirm `--dns-endpoint` is passed and connectivity succeeds

## 5. Documentation

- [x] 5.1 Update `README.md` or relevant docs to document the new WIF+GKE variables (`K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `K8S_USE_DNS_ENDPOINT`) and their behavior
- [x] 5.2 Update `CHANGELOG.md` with the new feature entry
