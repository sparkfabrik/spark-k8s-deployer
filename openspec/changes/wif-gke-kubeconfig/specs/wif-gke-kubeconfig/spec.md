## ADDED Requirements

### Requirement: GKE kubeconfig template is self-contained and remotely includable
The `templates/functions/gke-kubeconfig.yml` template SHALL define all its logic inline in `before_script` blocks, with no dependency on the Docker image or `scripts/src/functions.bash`. It SHALL be usable via `include: remote:` independently of the deployer image.

#### Scenario: Template included remotely without the image
- **WHEN** a project includes `gke-kubeconfig.yml` via `include: remote:` without using the spark-k8s-deployer image
- **THEN** all functions (`check_gke_env`, `generate_gke_kubeconfig`) SHALL be available in `before_script` without errors

### Requirement: GKE kubeconfig generation gated on ENABLE_GCP_WIF and K8S_CLUSTER_NAME
The `.gke-kubeconfig` `before_script` SHALL generate a GKE kubeconfig only when `ENABLE_GCP_WIF=1` AND `K8S_CLUSTER_NAME` is non-empty. In all other cases it SHALL skip silently with an informational message.

#### Scenario: Kubeconfig generated when both conditions are met
- **WHEN** `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set
- **THEN** `generate_gke_kubeconfig` SHALL be called and a valid kubeconfig SHALL be produced

#### Scenario: Skipped when ENABLE_GCP_WIF is not 1
- **WHEN** `ENABLE_GCP_WIF` is unset, empty, or `"0"`
- **THEN** the template SHALL print a skip message and exit without error

#### Scenario: Skipped when K8S_CLUSTER_NAME is absent
- **WHEN** `ENABLE_GCP_WIF=1` but `K8S_CLUSTER_NAME` is unset or empty
- **THEN** the template SHALL print a skip message and exit without error

#### Scenario: Skipped when gcloud is not available in the job image
- **WHEN** `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set but the `gcloud` command is not on `PATH` (e.g. a build or test job using an image without the Cloud SDK)
- **THEN** the template SHALL print a skip message and exit without error, so non-deploy jobs that inherit the global `before_script` are not failed

#### Scenario: Skipped when gcloud is present but not authenticated
- **WHEN** `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set and `gcloud` is available but no account is active (e.g. WIF authentication did not run or did not succeed)
- **THEN** the template SHALL print a skip message and exit without error

#### Scenario: Fails fast on a real generation error
- **WHEN** `ENABLE_GCP_WIF=1`, `K8S_CLUSTER_NAME` is set, `gcloud` is available and authenticated, but a required variable is missing or `gcloud container clusters get-credentials` fails
- **THEN** the template SHALL print a descriptive error and exit non-zero

### Requirement: GKE variable validation
`check_gke_env()` SHALL validate that `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, and `KUBE_NAMESPACE` are all non-empty. On any missing variable it SHALL print a descriptive error and return non-zero.

#### Scenario: All required variables present
- **WHEN** `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, and `KUBE_NAMESPACE` are all set
- **THEN** `check_gke_env()` SHALL return 0

#### Scenario: Missing required variable
- **WHEN** any of `K8S_LOCATION`, `GCP_PROJECT_ID`, or `KUBE_NAMESPACE` is unset
- **THEN** `check_gke_env()` SHALL print "Missing <VAR_NAME>." and return 1

### Requirement: Namespace-scoped kubeconfig
`generate_gke_kubeconfig()` SHALL use `gcloud container clusters get-credentials` to fetch cluster credentials, then scope the active context to `$KUBE_NAMESPACE` via `kubectl config set-context --current --namespace`.

#### Scenario: Kubeconfig scoped to KUBE_NAMESPACE
- **WHEN** `generate_gke_kubeconfig()` completes successfully
- **THEN** `kubectl get pods` (without `-n`) SHALL return results from `$KUBE_NAMESPACE` only

### Requirement: DNS endpoint support
When `K8S_USE_DNS_ENDPOINT=1`, `generate_gke_kubeconfig()` SHALL append `--dns-endpoint` to the `gcloud container clusters get-credentials` command.

#### Scenario: DNS endpoint flag appended when enabled
- **WHEN** `K8S_USE_DNS_ENDPOINT=1`
- **THEN** `gcloud container clusters get-credentials` SHALL include `--dns-endpoint`

#### Scenario: DNS endpoint flag omitted when not enabled
- **WHEN** `K8S_USE_DNS_ENDPOINT` is unset, empty, or `"0"`
- **THEN** `gcloud container clusters get-credentials` SHALL NOT include `--dns-endpoint`

### Requirement: CI log banner section
The `.gke-kubeconfig` `before_script` SHALL emit a `section_start`/`section_end` block (label: `gke-kubeconfig`) and `print-banner` calls for visibility in GitLab CI logs, consistent with the style used in `gcp-wif.yml`.

#### Scenario: Banner section emitted in CI log
- **WHEN** the template runs in a GitLab CI job
- **THEN** the CI log SHALL contain a collapsible section labelled `gke-kubeconfig`

### Requirement: Kubeconfig generated after GitLab Agent setup
The `.gke-kubeconfig` `before_script` reference SHALL be the last entry in `.global-setup`, after `.default-setup` (which contains `setup-gitlab-agent`), so the gcloud context always overrides the agent context.

#### Scenario: gcloud context overrides agent context
- **WHEN** both `setup-gitlab-agent` and `generate_gke_kubeconfig` execute in the same job
- **THEN** the active kubectl context after `before_script` completes SHALL be the one produced by `gcloud container clusters get-credentials`

## MODIFIED Requirements

### Requirement: kubeconfig-creation uses legacy token path only
`create_kubeconfig()` and `ensure_deploy_variables()` in `scripts/src/functions.bash` SHALL contain only the original token-based logic (`KUBE_URL` + `KUBE_TOKEN` + optional `KUBE_CA_PEM`). They SHALL have no WIF or GKE awareness.

#### Scenario: Legacy path unchanged
- **WHEN** `create_kubeconfig()` is called with `KUBE_URL`, `KUBE_TOKEN`, and `KUBE_NAMESPACE` set
- **THEN** it SHALL produce a kubeconfig identical to the pre-change behavior

#### Scenario: No WIF branch in image scripts
- **WHEN** `ENABLE_GCP_WIF=1` and `create_kubeconfig()` is called
- **THEN** it SHALL proceed with the token-based path regardless of `ENABLE_GCP_WIF`
