## MODIFIED Requirements

### Requirement: kubeconfig-creation is image-only and legacy token-based
`create_kubeconfig()` in `scripts/src/functions.bash` SHALL implement only the token-based kubeconfig path (`KUBE_URL` + `KUBE_TOKEN` + optional `KUBE_CA_PEM`). WIF+GKE kubeconfig generation SHALL be handled exclusively by `templates/functions/gke-kubeconfig.yml`.

#### Scenario: Token-based path is the only path
- **WHEN** `create_kubeconfig()` is called under any combination of environment variables
- **THEN** it SHALL always use the token-based approach and SHALL NOT call `gcloud container clusters get-credentials`

### Requirement: Variable validation is legacy-only in image scripts
`ensure_deploy_variables()` in `scripts/src/functions.bash` SHALL validate only `KUBE_URL`, `KUBE_TOKEN`, `KUBE_NAMESPACE`, `CI_ENVIRONMENT_SLUG`, and `CI_ENVIRONMENT_URL`. GKE variable validation (`K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`) SHALL be handled exclusively by `check_gke_env()` in `gke-kubeconfig.yml`.

#### Scenario: Legacy variables validated
- **WHEN** `ensure_deploy_variables()` is called
- **THEN** it SHALL check `KUBE_URL`, `KUBE_TOKEN`, `KUBE_NAMESPACE`, `CI_ENVIRONMENT_SLUG`, `CI_ENVIRONMENT_URL` and exit 1 on any missing variable

#### Scenario: No GKE variable checks in image scripts
- **WHEN** `ensure_deploy_variables()` is called with `ENABLE_GCP_WIF=1`
- **THEN** it SHALL still validate only the legacy token variables, unchanged
