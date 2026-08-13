# Spark k8s deployer image

This images is intended to be used to build and deploy applications to a k8s cluster, from
within gitlab-ci.

This image includes:

- Docker client 29.6.1
- Docker-compose v2.23.1
- Google cloud sdk 422.0.0
- Helm 3.11.2 (helm3 binary)
- Deploy scripts on `scripts`
- Flux 0.26.2
- YQ4 4.14.2
- Stern 1.24.0
- AWS-cli 1.16.305

## Kubernetes Authentication

The deployer supports two authentication paths for cluster access.

### Legacy: token-based (KUBE_URL / KUBE_TOKEN)

Set the following CI/CD variables to use static token credentials:

| Variable | Description |
|---|---|
| `KUBE_URL` | Kubernetes API server URL |
| `KUBE_TOKEN` | Service account token |
| `KUBE_CA_PEM` | (Optional) CA certificate PEM |
| `KUBE_NAMESPACE` | Target namespace |

### WIF + GKE (Workload Identity Federation)

When `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set, the `.gke-kubeconfig` template
generates a namespace-scoped kubeconfig using WIF-authenticated gcloud credentials.
No static credentials are required.

This path is automatically activated when using the platform generator with a `wif` block
(see board#4348), which injects all required variables.

The `.gke-kubeconfig` template is self-contained and remotely includable independently
of the deployer image. It requires `.gcp-wif` to have run first (gcloud must be
authenticated before kubeconfig generation).

| Variable | Description |
|---|---|
| `ENABLE_GCP_WIF` | Set to `"1"` to enable WIF authentication |
| `K8S_CLUSTER_NAME` | GKE cluster name |
| `K8S_LOCATION` | GKE cluster location (region or zone) |
| `GCP_PROJECT_ID` | GCP project ID |
| `KUBE_NAMESPACE` | Target namespace (kubeconfig is scoped to this namespace) |
| `K8S_USE_DNS_ENDPOINT` | Set to `"1"` to pass `--dns-endpoint` (for private clusters with DNS endpoint access) |
| `WIF_*` | WIF pool/provider/SA variables injected by the generator |

> **Note:** The resulting kubeconfig is namespace-scoped: `kubectl get pods` defaults to
> `$KUBE_NAMESPACE`. The `.gke-kubeconfig` step runs after `setup-gitlab-agent`, so the
> gcloud context always overrides the agent context when both are configured.

### GitLab Agent

The GitLab Agent path (`setup-gitlab-agent`) is also supported. Set `DISABLE_GITLAB_AGENT=1`
to skip agent setup. When WIF+GKE is configured, `.gke-kubeconfig` runs after the agent
setup and its context takes precedence.
