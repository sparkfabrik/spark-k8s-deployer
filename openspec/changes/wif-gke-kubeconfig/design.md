## Context

The `spark-k8s-deployer` ops-base image is used in GitLab CI/CD pipelines to deploy applications to Kubernetes. It currently provides two methods for cluster access:

1. **Token-based** (`create_kubeconfig`): uses `KUBE_URL` + `KUBE_TOKEN` + `KUBE_CA_PEM` to build a kubeconfig from static credentials. Lives in `scripts/src/functions.bash` (baked into the Docker image).
2. **GitLab Agent** (`setup-gitlab-agent`): uses `kubectl config use-context` to switch to an agent-managed context. Also lives in `scripts/src/functions.bash`.

WIF authentication to GCP is handled by `templates/functions/gcp-wif.yml` (`create_wif()`), which runs early in the `before_script` chain and leaves `gcloud` fully authenticated. This template is **self-contained and remotely includable** — it has no dependency on the Docker image.

The existing template portability pattern is:
- `templates/functions/*.yml` → functions defined inline in YAML `before_script`, includable via `include: remote:` independently of the image.
- `scripts/src/functions.bash` → functions baked into the image, only available when running inside the deployer container.

The initial implementation of this change broke this pattern by adding WIF+GKE logic to `functions.bash`. This design corrects that by introducing a new portable template following the same convention as `gcp-wif.yml`.

The `before_script` execution chain (defined in `templates/.gitlab-ci-template.yml`) runs in this order:
```
1. .gitlab-helper-functions   (section_start/end helpers)
2. .gcp-wif                   (WIF auth → gcloud authenticated)
3. .default-setup             (sources functions.bash → setup-gitlab-agent → job info)
4. .gke-kubeconfig            (GKE kubeconfig generation — NEW, runs last)
```

Running `.gke-kubeconfig` last — after `setup-gitlab-agent` — ensures the gcloud-based kubeconfig always overrides the agent context, providing a safety net for users who forget to set `DISABLE_GITLAB_AGENT=1`.

## Goals / Non-Goals

**Goals:**
- Introduce a portable, remotely-includable `gke-kubeconfig.yml` template that generates a GKE kubeconfig using WIF-authenticated gcloud — no image dependency.
- Run kubeconfig generation **after** `setup-gitlab-agent` so gcloud context always wins.
- Support `K8S_USE_DNS_ENDPOINT=1` for private clusters.
- Scope the kubeconfig to `$KUBE_NAMESPACE`.
- Emit a CI log banner section for visibility.
- Revert `functions.bash` to its pre-change state — no WIF awareness in image scripts.
- Preserve full backward compatibility.

**Non-Goals:**
- Changes to `gcp-wif.yml` (handles GCP auth, stays as-is).
- Changes to `setup-gitlab-agent()` (works correctly, stays as-is).
- Supporting non-GKE clusters via WIF.
- Generator-side changes (handled in board#4348).

## Decisions

### 1. Separate template (`gke-kubeconfig.yml`) rather than extending `gcp-wif.yml`

**Decision:** New file `templates/functions/gke-kubeconfig.yml` with anchor `.gke-kubeconfig`.

**Rationale:** Separation of concerns. `gcp-wif.yml` handles GCP authentication; `gke-kubeconfig.yml` handles cluster access. They can be used independently — a project might use WIF for Artifact Registry access only, without needing GKE access. A separate template makes each file's responsibility explicit and mirrors the existing split between `gcp-wif.yml` and `gitlab-helper-functions.yml`.

**Alternative considered:** Extending `gcp-wif.yml` with the kubeconfig logic. Rejected because it couples two distinct concerns (auth vs. cluster access) in one file, making the template harder to reason about and reuse independently.

### 2. `.gke-kubeconfig` runs last in the `before_script` chain

**Decision:** `!reference [.gke-kubeconfig, before_script]` is added as the final step in `.global-setup`, after `.default-setup` (which contains `setup-gitlab-agent`).

**Rationale:** When a user forgets to set `DISABLE_GITLAB_AGENT=1`, the agent may configure its own kubeconfig context. Running `.gke-kubeconfig` after ensures the gcloud-based context always overrides, making WIF+GKE the authoritative path when configured. This is a deliberate safety net.

**Alternative considered:** Running before `setup-gitlab-agent` (inside `.gcp-wif` or between steps 2 and 3). Rejected because agent setup could then override the gcloud context, producing the opposite of the desired behavior.

### 3. No WIF awareness in `functions.bash`

**Decision:** Revert `create_kubeconfig()` and `ensure_deploy_variables()` to their pre-change state. No WIF branch, no GKE variables checked.

**Rationale:** The image scripts are called by `scripts/kubectl` and `scripts/destroy` for token-based pipelines only. Adding WIF awareness there breaks the portability pattern — the logic should live in a template, not baked into the image. The template approach covers all use cases without image changes.

### 4. Branch condition: `ENABLE_GCP_WIF=1 && K8S_CLUSTER_NAME` is set

**Decision:** Gate `generate_gke_kubeconfig` on both `ENABLE_GCP_WIF=1` (explicit opt-in) and `K8S_CLUSTER_NAME` being non-empty.

**Rationale:** Same reasoning as before — `ENABLE_GCP_WIF=1` alone is insufficient since a project might use WIF for GCR/Artifact Registry without needing GKE access. `K8S_CLUSTER_NAME` unambiguously signals cluster intent.

### 5. `K8S_USE_DNS_ENDPOINT` as a boolean flag

**Decision:** When `K8S_USE_DNS_ENDPOINT=1`, append `--dns-endpoint` to the `gcloud container clusters get-credentials` command.

**Rationale:** The platform generator sets this as `"1"`/`"0"` (board#4348). The `--dns-endpoint` flag instructs gcloud to use the cluster's DNS-based endpoint (Private Service Connect), required for private GKE clusters.

## Risks / Trade-offs

- **`gcloud` must be authenticated before `.gke-kubeconfig` runs** → guaranteed by `.gcp-wif` running earlier in the chain. If `ENABLE_GCP_WIF=0` but `K8S_CLUSTER_NAME` is set, the template skips silently (gate condition not met). No risk.
- **Execution order dependency** → `.gke-kubeconfig` must always be the last `!reference` in `.global-setup`. If a future template is added after it, it could inadvertently switch the active context. Mitigation: document the ordering constraint clearly.
- **Namespace scoping is advisory, not enforced by RBAC** → `kubectl config set-context --current --namespace` sets the default namespace for commands but does not prevent cross-namespace access if the service account has cluster-wide permissions. True enforcement requires RBAC on the GCP side.

## Migration Plan

No migration required. The change is purely additive for new WIF-enabled pipelines. The revert of `functions.bash` removes the previously merged WIF branches, restoring the original behavior for all existing pipelines.

**Rollback:** Remove `gke-kubeconfig.yml` and its `include:` + `!reference` entries from `.gitlab-ci-template.yml`. No state is persisted between runs.

## Open Questions

None — all design decisions from the previous iteration are resolved.
