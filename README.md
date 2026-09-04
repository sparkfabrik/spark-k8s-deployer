# Spark k8s deployer image

This images is intended to be used to build and deploy applications to a k8s cluster, from
within gitlab-ci.

This image includes:

- Docker client 20.10.7
- Docker-compose v2.23.1
- Google cloud sdk 422.0.0
- Helm 3.11.2 (helm3 binary)
- Deploy scripts on `scripts`
- Flux 0.26.2
- YQ4 4.14.2
- Stern 1.24.0
- AWS-cli 1.16.305
- Kubeconform v0.8.0

## Kubernetes Authentication

The deployer supports two authentication paths for cluster access.

### Legacy: token-based (KUBE_URL / KUBE_TOKEN)

Set the following CI/CD variables to use static token credentials:

| Variable         | Description                   |
| ---------------- | ----------------------------- |
| `KUBE_URL`       | Kubernetes API server URL     |
| `KUBE_TOKEN`     | Service account token         |
| `KUBE_CA_PEM`    | (Optional) CA certificate PEM |
| `KUBE_NAMESPACE` | Target namespace              |

### WIF + GKE (Workload Identity Federation)

When `ENABLE_GCP_WIF=1` and `K8S_CLUSTER_NAME` is set, the `.gke-kubeconfig` template
generates a namespace-scoped kubeconfig using WIF-authenticated gcloud credentials.
No static credentials are required.

This path is automatically activated when using the platform generator with a `wif` block
(see board#4348), which injects all required variables.

The `.gke-kubeconfig` template is self-contained and remotely includable independently
of the deployer image. It requires `.gcp-wif` to have run first (gcloud must be
authenticated before kubeconfig generation).

| Variable               | Description                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------- |
| `ENABLE_GCP_WIF`       | Set to `"1"` to enable WIF authentication                                             |
| `K8S_CLUSTER_NAME`     | GKE cluster name                                                                      |
| `K8S_LOCATION`         | GKE cluster location (region or zone)                                                 |
| `GCP_PROJECT_ID`       | GCP project ID                                                                        |
| `KUBE_NAMESPACE`       | Target namespace (kubeconfig is scoped to this namespace)                             |
| `K8S_USE_DNS_ENDPOINT` | Set to `"1"` to pass `--dns-endpoint` (for private clusters with DNS endpoint access) |
| `WIF_*`                | WIF pool/provider/SA variables injected by the generator                              |

> **Note:** The resulting kubeconfig is namespace-scoped: `kubectl get pods` defaults to
> `$KUBE_NAMESPACE`. The `.gke-kubeconfig` step runs after `setup-gitlab-agent`, so the
> gcloud context always overrides the agent context when both are configured.

### GitLab Agent

The GitLab Agent path (`setup-gitlab-agent`) is also supported. Set `DISABLE_GITLAB_AGENT=1`
to skip agent setup. When WIF+GKE is configured, `.gke-kubeconfig` runs after the agent
setup and its context takes precedence.

### Multi-cluster: runtime ref-to-cluster resolution

A project can deploy to more than one cluster without naming any of them in its
pipeline. The cluster is picked at runtime from the git ref by
`.spark-k8s-cluster-resolver`, which then exports the variables
`.gke-kubeconfig` already consumes, so the kubeconfig step runs unchanged.

The cluster list is injected as a CI/CD variable of type **File**,
`$SPARK_K8S_CONFIG`:

```yaml
version: 1
clusters:
  - name: example-dev
    default: true
    project_id: example-dev-project
    location: europe-west1
    dns_endpoint: gke-....gke.goog
  - name: example-prod
    refs: [main]
    project_id: example-prod-project
    location: europe-west1
    dns_endpoint: gke-....gke.goog
    use_dns_endpoint: true
```

| Key                | Description                                                                                                                       |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `version`          | Configuration schema version, currently `1`. Optional, defaults to `1`                                                            |
| `name`             | GKE cluster name, exported as `K8S_CLUSTER_NAME`                                                                                  |
| `project_id`       | GCP project ID, exported as `GCP_PROJECT_ID`                                                                                      |
| `location`         | Cluster region or zone, exported as `K8S_LOCATION`                                                                                |
| `refs`             | List of ref patterns this cluster owns                                                                                            |
| `default`          | Marks the cluster used when no pattern matches. At most one entry                                                                 |
| `dns_endpoint`     | DNS endpoint of the control plane, exported as `SPARK_K8S_CLUSTER_DNS_ENDPOINT`                                                   |
| `use_dns_endpoint` | Sets `K8S_USE_DNS_ENDPOINT`. Only `true` and `false` are accepted; when absent it is inferred from the presence of `dns_endpoint` |

`KUBE_NAMESPACE` is not part of the cluster configuration and must still be
provided by the project.

#### How a ref is matched

The ref is normalized before matching: `refs/tags/<tag>` when `CI_COMMIT_TAG` is
set, `refs/heads/<branch>` otherwise. `CI_COMMIT_REF_NAME` is never used, so a
tag named `main` cannot match a branch rule.

The `clusters` list is scanned **bottom-up** and the first entry with a matching
pattern wins, so the last declared match wins, gitignore style. There is no
specificity scoring. When nothing matches, the `default: true` entry is used.

Patterns are globs by default:

| Pattern        | Matches                                                                                       |
| -------------- | --------------------------------------------------------------------------------------------- |
| `main`         | the `main` branch, because a pattern without a leading `refs/` is prefixed with `refs/heads/` |
| `feature/*`    | `feature/login`, but not `feature/login/sso`: `*` does not cross a slash                      |
| `feature/**`   | `feature/login` and `feature/login/sso`: `**` crosses slashes                                 |
| `refs/tags/v*` | the tag `v1`, and no branch                                                                   |

Bracket expressions (`[abc]`) are not supported and match literally.

A pattern wrapped in slashes is a regular expression, following GitLab's own
convention. The PCRE shorthands `\d`, `\D`, `\w`, `\W`, `\s` and `\S` are
supported; any other backslash shorthand, and any `(?...)` group, fails the
resolution rather than silently matching nothing.

The regex form matches a different target than the glob form, and this asymmetry
is deliberate: a glob is prefixed with `refs/heads/` when it does not name a ref
namespace, while a user-written regex cannot be rewritten that way without
breaking unanchored patterns.

- A regex that does **not** mention `refs/` matches the **short branch name**,
  and only on branch pipelines. `/^release-\d+$/` matches the branch
  `release-12` and never a tag named `release-12`.
- A regex that **does** mention `refs/` matches the **normalized ref**.
  `/^refs\/tags\/v\d+$/` matches the tag `v3`. Mentioning means `refs/` at the
  start of the pattern or after a non-word character, so `/^prefs\/x$/` still
  matches the short branch name `prefs/x`.

#### Pipelines without a ref

Merge request pipelines have neither `CI_COMMIT_TAG` nor `CI_COMMIT_BRANCH`, so
there is no ref to resolve and the default cluster is deliberately **not** used.
The resolver exports nothing and cluster-dependent jobs skip. Reference
`.spark-k8s-require-cluster` as the first line of such a job's `script`:

```yaml
deploy:
  stage: deploy
  script:
    - !reference [.spark-k8s-require-cluster, script]
    - helm upgrade --install ...
```

That guard belongs in the job, never in a global `before_script`: GitLab
concatenates `before_script` and `script` into one shell script, so an `exit 0`
in the global chain would end every job in the pipeline successfully without
running its script.

#### Interaction with the GitLab Agent

While `$SPARK_K8S_CONFIG` is set the resolver owns the cluster choice and
`setup-gitlab-agent` does not run, so the two paths are mutually exclusive. The
resolver exports `DISABLE_GITLAB_AGENT=1`, and `setup-gitlab-agent` also returns
early on its own, which covers jobs that override the whole `before_script`.
Agent variables left over from a previous setup produce a warning in the job log
and are ignored.

#### When it does not run

- `$SPARK_K8S_CONFIG` unset: nothing happens, single-cluster behavior is
  untouched and existing projects see no change.
- Job image without the deployer scripts or without `yq4`, for example a Kaniko
  image inheriting the global `before_script`: the resolver skips without
  failing, exactly like `.gke-kubeconfig` does when `gcloud` is missing.

A configuration error, on the other hand, fails the job: invalid YAML, an
unsupported `version`, an empty or missing `clusters` list, more than one
default, a `refs` that is not a list (`refs: main` instead of `refs: [main]`), a
selected entry without `name`, `project_id` or `location`, an unsupported regex
construct, or a ref that matches nothing when no default is declared.

While `$SPARK_K8S_CONFIG` is set the resolver owns `K8S_CLUSTER_NAME`,
`GCP_PROJECT_ID`, `K8S_LOCATION` and `K8S_USE_DNS_ENDPOINT`: it clears them
before resolving, so a ref that owns no cluster cannot inherit them from plain
CI/CD variables and reach the wrong cluster. Projects that do not use the
resolver keep whatever they set.

#### Stop and rollback jobs

`.stop-deployment-template` and `.helm-rollback-template` resolve the cluster
too, so `helm uninstall` and `helm rollback` never run against a stale
kubeconfig. They reference `.gitlab-helper-functions`, `.gcp-wif`,
`.spark-k8s-cluster-resolver` and `.gke-kubeconfig`. Projects using
`.gitlab-ci-template.yml` already include all four; a project that includes
either job template on its own must add those four includes, or pipeline
creation fails on an unresolved `!reference`.

#### Tests

The resolver has a test suite covering ref normalization, glob and regex
semantics, ordering, the default fallback and the configuration errors. It needs
`yq4`, so it runs inside the deployer image:

```
make test-cluster-resolver
```
