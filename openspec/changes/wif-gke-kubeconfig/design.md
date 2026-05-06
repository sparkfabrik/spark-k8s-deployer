## Context

The `spark-k8s-deployer` ops-base image is used in GitLab CI/CD pipelines to deploy applications to Kubernetes. It currently provides two methods for cluster access:

1. **Token-based** (`create_kubeconfig`): uses `KUBE_URL` + `KUBE_TOKEN` + `KUBE_CA_PEM` to build a kubeconfig from static credentials.
2. **GitLab Agent** (`setup-gitlab-agent`): uses `kubectl config use-context` to switch to an agent-managed context.

WIF authentication to GCP is already handled by `templates/functions/gcp-wif.yml` (`create_wif()`), which runs early in the `before_script` chain and leaves `gcloud` fully authenticated. What is missing is the step that converts that gcloud authentication into a namespace-scoped kubeconfig for a GKE cluster.

The platform generator (board#4348) injects the following variables into GitLab CI/CD when a project declares a `wif` block: `ENABLE_GCP_WIF`, `K8S_CLUSTER_NAME`, `K8S_LOCATION`, `GCP_PROJECT_ID`, `K8S_USE_DNS_ENDPOINT`, `KUBE_NAMESPACE`, `DISABLE_GITLAB_AGENT`, and the `WIF_*` set.

The `before_script` execution chain (defined in `templates/.gitlab-ci-template.yml`) runs in this order:
```
1. .gitlab-helper-functions   (section_start/end helpers)
2. .gcp-wif                   (WIF auth → gcloud authenticated)
3. .default-setup             (sources functions.bash → setup-gitlab-agent → job info)
```

By the time `.default-setup` runs, gcloud is already authenticated. No new auth step is needed.

## Goals / Non-Goals

**Goals:**
- Add a GKE kubeconfig generation path to `create_kubeconfig()` that activates when `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set.
- Scope the resulting kubeconfig to `$KUBE_NAMESPACE` (deny cross-namespace access).
- Support private clusters that use DNS endpoint access (`K8S_USE_DNS_ENDPOINT=1` → `--dns-endpoint`).
- Preserve full backward compatibility — pipelines without `ENABLE_GCP_WIF` or `K8S_CLUSTER_NAME` must be unaffected.
- Allow both GitLab Agent and WIF+GKE to coexist: agent runs first, gcloud-based kubeconfig overrides if the WIF+GKE condition is met.

**Non-Goals:**
- Changes to `gcp-wif.yml` — GCP auth is already working.
- Changes to `setup-gitlab-agent()` — already handles `DISABLE_GITLAB_AGENT` correctly.
- Supporting non-GKE clusters via WIF (e.g., EKS, AKS).
- Generator-side changes (handled in board#4348).

## Decisions

### 1. Extend `create_kubeconfig()` rather than creating a new function

**Decision:** Add a WIF+GKE branch inside the existing `create_kubeconfig()` function.

**Rationale:** All callers (`scripts/kubectl`, `scripts/destroy`, `templates/.gitlab-ci-template.yml`) already invoke `create_kubeconfig()`. Keeping a single entry point means no call-site changes. The function name remains semantically accurate — it creates a kubeconfig, regardless of method.

**Alternative considered:** A new `generate_kubeconfig_wif()` function called separately. Rejected because it would require updating all callers and introduces parallel naming confusion.

### 2. Branch condition: `ENABLE_GCP_WIF=1 && K8S_CLUSTER_NAME` is set

**Decision:** Gate the new path on both `ENABLE_GCP_WIF=1` (explicit opt-in) and `K8S_CLUSTER_NAME` being non-empty (cluster is actually configured).

**Rationale:** `ENABLE_GCP_WIF=1` alone is insufficient — a project might use WIF for GCR access only, without needing GKE access. Requiring `K8S_CLUSTER_NAME` avoids accidentally triggering cluster auth when no cluster is configured. Together they unambiguously signal "WIF + GKE deployment."

**Alternative considered:** Checking `K8S_CLUSTER_NAME` alone (duck-typing). Rejected because it could silently activate in non-WIF pipelines if `K8S_CLUSTER_NAME` is set for other reasons.

### 3. Execution order: GitLab Agent first, WIF+GKE second

**Decision:** `setup-gitlab-agent()` runs before `create_kubeconfig()`. If both produce a context, the gcloud-based kubeconfig is the final active context.

**Rationale:** The generator injects `DISABLE_GITLAB_AGENT=1` for WIF-enabled projects (board#4348), so in practice both will not be active simultaneously for generator-managed projects. But for manual configurations or migration scenarios, having gcloud win ensures the WIF path is authoritative when explicitly configured.

### 4. `K8S_USE_DNS_ENDPOINT` as a boolean flag

**Decision:** When `K8S_USE_DNS_ENDPOINT=1`, append `--dns-endpoint` to the `gcloud container clusters get-credentials` command.

**Rationale:** The platform generator sets this as `"1"`/`"0"` (board#4348). The `--dns-endpoint` flag instructs gcloud to use the cluster's DNS-based endpoint (Private Service Connect), required for private GKE clusters that do not expose a public IP. Making it a boolean avoids passing a URL — gcloud resolves the DNS endpoint automatically from cluster metadata.

### 5. `ensure_deploy_variables()` gets a parallel WIF branch

**Decision:** Extend `ensure_deploy_variables()` to validate GKE-specific variables when the WIF+GKE branch is active, instead of checking `KUBE_URL`/`KUBE_TOKEN`.

**Rationale:** `ensure_deploy_variables()` is called before `create_kubeconfig()` in scripts. Without updating it, WIF+GKE pipelines would fail with misleading "Missing KUBE_URL" errors. The branch condition mirrors `create_kubeconfig()`: `ENABLE_GCP_WIF=1 && K8S_CLUSTER_NAME` is set.

## Risks / Trade-offs

- **gcloud version dependency** → `--dns-endpoint` flag requires a sufficiently recent gcloud version. The Dockerfile pins `google-cloud-cli` at `550.0.0` which supports it. Risk is low but worth noting in release notes.
- **Namespace scoping is advisory, not enforced by RBAC** → `kubectl config set-context --current --namespace` scopes the default namespace for commands, but does not prevent cross-namespace access if the service account has cluster-wide permissions. True enforcement requires RBAC configuration on the GCP side, which is out of scope here. Mitigation: document this clearly.
- **`eval` in `create_kubeconfig()`** → Building the gcloud command as a string and running it via `eval` is used to handle the optional `--dns-endpoint` flag cleanly. Alternative: use an array and `"${cmd[@]}"`. Prefer array approach to avoid word-splitting risks.

## Migration Plan

No migration required. The change is purely additive:
- Existing pipelines continue using the legacy path unchanged.
- New WIF-enabled pipelines activate the new path automatically via generator-injected variables.
- No config changes required at the application project level beyond what board#4348 already produces.

**Rollback:** Revert the changes to `functions.bash` and `.gitlab-ci-template.yml`. No state is persisted between runs.

## Open Questions

- Should `create_kubeconfig()` in the WIF+GKE path export `KUBECONFIG` to a file (as the legacy path does) or rely on the default `~/.kube/config` written by `gcloud container clusters get-credentials`? The default gcloud behavior writes to `~/.kube/config`, which is fine for CI. The legacy path writes to `$(pwd)/kubeconfig` and sets `$KUBECONFIG`. For consistency, we could set `KUBECONFIG` explicitly after gcloud runs too — to be confirmed during implementation.
