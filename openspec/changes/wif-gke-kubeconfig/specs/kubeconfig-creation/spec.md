## MODIFIED Requirements

### Requirement: Kubeconfig creation supports multiple authentication paths
`create_kubeconfig()` SHALL support two mutually exclusive execution paths selected at runtime:
1. **WIF+GKE path**: activated when `ENABLE_GCP_WIF=1` AND `K8S_CLUSTER_NAME` is non-empty. Uses `gcloud container clusters get-credentials`.
2. **Legacy token path**: activated in all other cases. Uses `KUBE_URL` + `KUBE_TOKEN` + optional `KUBE_CA_PEM`.

The function SHALL remain the single entry point for kubeconfig creation regardless of path.

#### Scenario: WIF+GKE path selected
- **WHEN** `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set
- **THEN** `create_kubeconfig()` SHALL use `gcloud container clusters get-credentials` and SHALL NOT use `KUBE_URL` or `KUBE_TOKEN`

#### Scenario: Legacy path selected when WIF is disabled
- **WHEN** `ENABLE_GCP_WIF` is unset, empty, or `"0"`
- **THEN** `create_kubeconfig()` SHALL use the existing token-based logic with `KUBE_URL`, `KUBE_TOKEN`, and optional `KUBE_CA_PEM`, unchanged

#### Scenario: Legacy path selected when K8S_CLUSTER_NAME is absent
- **WHEN** `ENABLE_GCP_WIF=1` but `K8S_CLUSTER_NAME` is unset or empty
- **THEN** `create_kubeconfig()` SHALL fall back to the legacy token-based path

### Requirement: Variable validation aligned with authentication path
`ensure_deploy_variables()` SHALL validate the variables appropriate for the active authentication path:
- **WIF+GKE path** (`ENABLE_GCP_WIF=1` AND `K8S_CLUSTER_NAME` set): validate `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `KUBE_NAMESPACE`.
- **Legacy path**: validate `KUBE_URL`, `KUBE_TOKEN`, `KUBE_NAMESPACE`, `CI_ENVIRONMENT_SLUG`, `CI_ENVIRONMENT_URL` (unchanged).

#### Scenario: WIF+GKE variable validation passes
- **WHEN** `ENABLE_GCP_WIF=1`, `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, and `KUBE_NAMESPACE` are all set
- **THEN** `ensure_deploy_variables()` SHALL return 0 without printing any error

#### Scenario: WIF+GKE variable validation fails on missing variable
- **WHEN** `ENABLE_GCP_WIF=1`, `K8S_CLUSTER_NAME` is set, but `K8S_LOCATION` is missing
- **THEN** `ensure_deploy_variables()` SHALL print "Missing K8S_LOCATION." and exit with code 1

#### Scenario: Legacy validation unchanged
- **WHEN** `ENABLE_GCP_WIF` is not `"1"`
- **THEN** `ensure_deploy_variables()` SHALL behave exactly as before this change
