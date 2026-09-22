#!/usr/bin/env bash

# Table driven tests for scripts/resolve-cluster, plus the schema gate that checks every
# fixture against schemas/cluster-config.schema.json in both directions. Needs yq4 and jv.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -P "${TEST_DIR}/../.." && pwd)"
RESOLVER="${ROOT_DIR}/scripts/resolve-cluster"
WRAPPER="${TEST_DIR}/resolve-with-schema"
FIXTURES_DIR="${TEST_DIR}/fixtures"
PWNED_MARKER="/tmp/spark-k8s-resolver-pwned"

# The synced generator schema; SPARK_K8S_SCHEMA_COPY points the gate at an unmerged copy.
SCHEMA_COPY="${SPARK_K8S_SCHEMA_COPY:-${ROOT_DIR}/schemas/cluster-config.schema.json}"

# The permissive schema used by the fixtures that exercise resolver tolerance.
TOLERANCE_SCHEMA="${TEST_DIR}/schemas/tolerance.schema.json"

# The ref matching vectors shared with the platform generator, byte for byte the file
# that repository runs its own resolver against.
VECTORS="${TEST_DIR}/vectors.json"

# Fixtures that must validate against the generator schema. envs-tie.yaml is one of
# them: the schema cannot express that two environments must not claim a ref with the
# same force, so the resolver is what has to catch it.
SCHEMA_CONFORMING_FIXTURES="basic.yaml ordering.yaml globs.yaml regex.yaml dns.yaml bad-regex.yaml multi-refs.yaml bracket-shorthand.yaml lazy-regex.yaml envs-basic.yaml envs-tie.yaml"

# Fixtures the generator schema must reject. bad-regex.yaml is not here on purpose:
# a bad regex is a valid string to the schema, so it proves the resolver still guards it.
SCHEMA_NON_CONFORMING_FIXTURES="bad-dns-flag.yaml no-default.yaml no-refs-no-default.yaml missing-fields.yaml scalar-refs.yaml injection.yaml two-defaults.yaml bad-version.yaml empty-clusters.yaml no-clusters-key.yaml malformed.yaml envs-missing-fields.yaml envs-scalar-refs.yaml envs-no-refs.yaml envs-empty.yaml both-shapes.yaml"

PASSED=0
FAILED=0

if [ ! -x "${RESOLVER}" ]; then
  printf 'The resolver is not executable: %s\n' "${RESOLVER}" >&2
  exit 1
fi

if ! command -v yq4 >/dev/null 2>&1; then
  printf 'The yq4 command is required to run this suite.\n' >&2
  exit 1
fi

report_pass() {
  PASSED=$((PASSED + 1))
  printf '  ok    %s\n' "${1}"
}

report_fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s\n' "${1}"
  shift
  local line
  for line in "$@"; do
    printf '        %s\n' "${line}"
  done
}

fixture() {
  printf '%s/%s' "${FIXTURES_DIR}" "${1}"
}

# Non-conforming fixtures get the permissive schema, so their exit code comes from
# the resolver; everything else gets the real copy, or nothing before it is synced.
schema_for_config() {
  local config="${1}"
  local name

  if [ -f "${config}" ]; then
    name="$(basename "${config}")"
    case " ${SCHEMA_NON_CONFORMING_FIXTURES} " in
    *" ${name} "*)
      printf '%s' "${TOLERANCE_SCHEMA}"
      return 0
      ;;
    esac
  fi

  if [ -f "${SCHEMA_COPY}" ]; then
    printf '%s' "${SCHEMA_COPY}"
  fi
}

# invoke_resolver <config> <tag> <branch>: the real entrypoint for a production layout,
# the test wrapper when the fixture needs a schema the entrypoint would not find.
invoke_resolver() {
  local schema binary
  schema="$(schema_for_config "${1}")"
  binary="${RESOLVER}"
  if [ -n "${schema}" ] && [ "${schema}" != "${ROOT_DIR}/schemas/cluster-config.schema.json" ]; then
    binary="${WRAPPER}"
  fi
  CI_COMMIT_TAG="${2}" \
    CI_COMMIT_BRANCH="${3}" \
    SPARK_K8S_CONFIG="${1}" \
    RESOLVER_TEST_SCHEMA="${schema}" \
    "${binary}"
}

# run_resolver <config> <tag> <branch>. Agent variables are cleared so the
# coexistence warning does not depend on the environment.
run_resolver() {
  GITLAB_AGENT_ID="" \
    GITLAB_AGENT_PROJECT="" \
    DEVELOP_GITLAB_AGENT_ID="" \
    DEVELOP_GITLAB_AGENT_PROJECT="" \
    PRODUCTION_GITLAB_AGENT_ID="" \
    PRODUCTION_GITLAB_AGENT_PROJECT="" \
    invoke_resolver "${1}" "${2}" "${3}" 2>/dev/null
}

expected_exports() {
  printf "export K8S_CLUSTER_NAME='%s'\n" "${1}"
  printf "export GCP_PROJECT_ID='%s'\n" "${2}"
  printf "export K8S_LOCATION='%s'\n" "${3}"
  printf "export K8S_USE_DNS_ENDPOINT='%s'\n" "${4}"
  printf "export SPARK_K8S_CLUSTER_DNS_ENDPOINT='%s'\n" "${5}"
  printf "export DISABLE_GITLAB_AGENT='1'\n"
}

# The environment shape adds KUBE_NAMESPACE after the cluster exports, so the output
# of a cluster shape document stays byte for byte what it was.
expected_env_exports() {
  expected_exports "${1}" "${2}" "${3}" "${4}" "${5}"
  printf "export KUBE_NAMESPACE='%s'\n" "${6}"
}

# assert_cluster <description> <config> <tag> <branch> <name> <project_id> \
#                <location> <use_dns_endpoint> <dns_endpoint>
assert_cluster() {
  local description="${1}"
  local config="${2}"
  local tag="${3}"
  local branch="${4}"
  local expected output rc

  expected="$(expected_exports "${5}" "${6}" "${7}" "${8}" "${9}")"
  output="$(run_resolver "${config}" "${tag}" "${branch}")"
  rc=$?

  if [ "${rc}" != "0" ]; then
    report_fail "${description}" "expected exit 0, got ${rc}"
    return
  fi
  if [ "${output}" != "${expected}" ]; then
    report_fail "${description}" "unexpected exports:" "${output}" "expected:" "${expected}"
    return
  fi

  report_pass "${description}"
}

# assert_env <description> <config> <tag> <branch> <cluster name> <project_id> \
#            <location> <use_dns_endpoint> <dns_endpoint> <namespace>
assert_env() {
  local description="${1}"
  local config="${2}"
  local tag="${3}"
  local branch="${4}"
  local expected output rc

  expected="$(expected_env_exports "${5}" "${6}" "${7}" "${8}" "${9}" "${10}")"
  output="$(run_resolver "${config}" "${tag}" "${branch}")"
  rc=$?

  if [ "${rc}" != "0" ]; then
    report_fail "${description}" "expected exit 0, got ${rc}"
    return
  fi
  if [ "${output}" != "${expected}" ]; then
    report_fail "${description}" "unexpected exports:" "${output}" "expected:" "${expected}"
    return
  fi

  report_pass "${description}"
}

# assert_exit <description> <expected exit code> <config> <tag> <branch>
assert_exit() {
  local description="${1}"
  local expected_rc="${2}"
  local config="${3}"
  local tag="${4}"
  local branch="${5}"
  local output rc

  output="$(run_resolver "${config}" "${tag}" "${branch}")"
  rc=$?

  if [ "${rc}" != "${expected_rc}" ]; then
    report_fail "${description}" "expected exit ${expected_rc}, got ${rc}"
    return
  fi
  if [ -n "${output}" ]; then
    report_fail "${description}" "expected no exports, got:" "${output}"
    return
  fi

  report_pass "${description}"
}

# Every fixture must be classified, or a later one slips past the gate.
assert_every_fixture_classified() {
  local description="every fixture is classified for the schema gate"
  local path name unclassified=""

  for path in "${FIXTURES_DIR}"/*.yaml; do
    name="$(basename "${path}")"
    case " ${SCHEMA_CONFORMING_FIXTURES} ${SCHEMA_NON_CONFORMING_FIXTURES} " in
    *" ${name} "*) ;;
    *) unclassified="${unclassified} ${name}" ;;
    esac
  done

  if [ -n "${unclassified}" ]; then
    report_fail "${description}" "not in either list:${unclassified}"
  else
    report_pass "${description}"
  fi
}

# assert_schema_verdict <fixture> <valid|invalid>
assert_schema_verdict() {
  local name="${1}"
  local expectation="${2}"
  local description="schema ${expectation}: ${name}"
  local output

  if output="$(jv "${SCHEMA_COPY}" "$(fixture "${name}")" 2>&1)"; then
    if [ "${expectation}" = "valid" ]; then
      report_pass "${description}"
    else
      report_fail "${description}" "the schema accepted a document it must reject"
    fi
    return
  fi

  if [ "${expectation}" = "invalid" ]; then
    report_pass "${description}"
  else
    report_fail "${description}" "the schema rejected a document it must accept:" "${output}"
  fi
}

run_schema_gate() {
  local name

  if [ ! -f "${SCHEMA_COPY}" ]; then
    printf '\n  skip  schema gate: %s has not been synced yet\n\n' "${SCHEMA_COPY}"
    return 0
  fi
  if ! command -v jv >/dev/null 2>&1; then
    printf '\n  skip  schema gate: the jv command is not available\n\n'
    return 0
  fi

  printf '\nSchema gate against %s\n' "${SCHEMA_COPY}"

  if output="$(jv "${SCHEMA_COPY}" 2>&1)"; then
    report_pass "the schema itself compiles against draft 2020-12"
  else
    report_fail "the schema itself compiles against draft 2020-12" "${output}"
  fi

  for name in ${SCHEMA_CONFORMING_FIXTURES}; do
    assert_schema_verdict "${name}" "valid"
  done
  for name in ${SCHEMA_NON_CONFORMING_FIXTURES}; do
    assert_schema_verdict "${name}" "invalid"
  done
  printf '\n'
}

printf 'Cluster resolver test suite\n'

assert_every_fixture_classified
run_schema_gate

# Ref normalization: a tag never matches a branch rule.
assert_cluster "branch main matches the main rule" \
  "$(fixture basic.yaml)" "" "main" \
  "example-prod" "example-prod-project" "europe-west1" "1" "gke-prod.example.gke.goog"

assert_cluster "a tag named main does not match the main branch rule" \
  "$(fixture basic.yaml)" "main" "" \
  "example-dev" "example-dev-project" "europe-west1" "1" "gke-dev.example.gke.goog"

assert_cluster "an unmatched branch falls back to the default cluster" \
  "$(fixture basic.yaml)" "" "feature/login" \
  "example-dev" "example-dev-project" "europe-west1" "1" "gke-dev.example.gke.goog"

# Merge request pipelines have no ref at all: no cluster, and no default.
assert_exit "a pipeline without branch or tag resolves nothing" 3 \
  "$(fixture basic.yaml)" "" ""

# Bottom up scan: the last declared match wins.
assert_cluster "the last declared matching cluster wins" \
  "$(fixture ordering.yaml)" "" "main" \
  "last-match" "spark-last-project" "europe-west1" "0" ""

assert_cluster "a lower catch-all wins over a higher exact match" \
  "$(fixture ordering.yaml)" "" "develop" \
  "catch-all" "spark-catch-all-project" "europe-west1" "0" ""

# Glob semantics: * does not cross a slash, ** does.
assert_cluster "a single star does not cross a slash" \
  "$(fixture globs.yaml)" "" "feature/login" \
  "single-star" "spark-single-project" "europe-west1" "0" ""

assert_cluster "a double star crosses slashes" \
  "$(fixture globs.yaml)" "" "feature/login/sso" \
  "double-star" "spark-double-project" "europe-west1" "0" ""

assert_cluster "a refs/tags pattern matches a tag" \
  "$(fixture globs.yaml)" "v1" "" \
  "tags-only" "spark-tags-project" "europe-west1" "0" ""

assert_cluster "a refs/tags pattern does not match a branch of the same name" \
  "$(fixture globs.yaml)" "" "v1" \
  "fallback" "spark-fallback-project" "europe-west1" "0" ""

# Regex form: a pattern without refs/ matches the short branch name only.
assert_cluster "a branch regex matches the short branch name" \
  "$(fixture regex.yaml)" "" "release-12" \
  "releases" "spark-releases-project" "europe-west1" "0" ""

assert_cluster "a branch regex does not match a tag of the same name" \
  "$(fixture regex.yaml)" "release-12" "" \
  "fallback" "spark-fallback-project" "europe-west1" "0" ""

assert_cluster "a regex mentioning refs/ matches the normalized ref" \
  "$(fixture regex.yaml)" "v3" "" \
  "version-tags" "spark-version-tags-proj" "europe-west1" "0" ""

assert_cluster "a regex merely containing refs/ still matches the short branch name" \
  "$(fixture regex.yaml)" "" "prefs/x" \
  "prefs-regex" "spark-prefs-project" "europe-west1" "0" ""

assert_exit "an unsupported regex construct fails the resolution" 1 \
  "$(fixture bad-regex.yaml)" "" "main"

assert_exit "a PCRE shorthand inside a bracket expression fails the resolution" 1 \
  "$(fixture bracket-shorthand.yaml)" "" "v12"

# A pattern error must not depend on the ref: here the broken pattern sits above a match.
assert_exit "an unsupported pattern fails even when a lower entry matches" 1 \
  "$(fixture lazy-regex.yaml)" "" "main"

# A refs list with several patterns: every element has to be considered.
assert_cluster "the first pattern of a multi-pattern list matches" \
  "$(fixture multi-refs.yaml)" "" "main" \
  "multi" "spark-multi-project" "europe-west1" "0" ""

assert_cluster "the middle pattern of a multi-pattern list matches" \
  "$(fixture multi-refs.yaml)" "" "release/1" \
  "multi" "spark-multi-project" "europe-west1" "0" ""

assert_cluster "the last pattern of a multi-pattern list matches" \
  "$(fixture multi-refs.yaml)" "" "hotfix/a/b" \
  "multi" "spark-multi-project" "europe-west1" "0" ""

assert_cluster "a ref matching none of a multi-pattern list falls back" \
  "$(fixture multi-refs.yaml)" "" "develop" \
  "fallback" "spark-fallback-project" "europe-west1" "0" ""

# DNS endpoint flag.
assert_cluster "an explicit use_dns_endpoint false wins over a declared endpoint" \
  "$(fixture dns.yaml)" "" "off-branch" \
  "explicit-off" "spark-explicit-off-proj" "europe-west1" "0" "gke-off.example.gke.goog"

assert_cluster "an explicit use_dns_endpoint true needs no endpoint" \
  "$(fixture dns.yaml)" "" "on-branch" \
  "explicit-on" "spark-explicit-on-proj" "europe-west1" "1" ""

assert_cluster "a declared endpoint without the flag enables it" \
  "$(fixture dns.yaml)" "" "other" \
  "inferred" "spark-inferred-project" "europe-west1" "1" "gke-inferred.example.gke.goog"

assert_exit "an unrecognized use_dns_endpoint value is an error" 1 \
  "$(fixture bad-dns-flag.yaml)" "" "main"

# Entries with neither refs nor default are never selected.
assert_cluster "an entry with no refs and no default is never selected" \
  "$(fixture no-refs-no-default.yaml)" "" "main" \
  "fallback" "p-fallback" "europe-west1" "0" ""

# Configuration errors.
assert_exit "no match and no default cluster is an error" 1 \
  "$(fixture no-default.yaml)" "" "develop"

assert_cluster "no default cluster is fine as long as a rule matches" \
  "$(fixture no-default.yaml)" "" "main" \
  "only-main" "p-only-main" "europe-west1" "0" ""

assert_exit "two default clusters are an error" 1 \
  "$(fixture two-defaults.yaml)" "" "main"

assert_exit "a scalar refs instead of a list is an error" 1 \
  "$(fixture scalar-refs.yaml)" "" "main"

assert_exit "a selected entry missing required fields is an error" 1 \
  "$(fixture missing-fields.yaml)" "" "main"

assert_exit "malformed YAML is an error" 1 \
  "$(fixture malformed.yaml)" "" "main"

assert_exit "an unsupported schema version is an error" 1 \
  "$(fixture bad-version.yaml)" "" "main"

assert_exit "an empty clusters list is an error" 1 \
  "$(fixture empty-clusters.yaml)" "" "main"

assert_exit "a configuration without a clusters list is an error" 1 \
  "$(fixture no-clusters-key.yaml)" "" "main"

assert_exit "an unreadable configuration path is an error" 1 \
  "/nonexistent/spark-k8s-config.yaml" "" "main"

assert_exit "an unset configuration is an error" 1 \
  "" "" "main"

# The variable may hold inline YAML instead of a path, which is what makes the
# resolver drivable outside GitLab.
assert_cluster "inline YAML is accepted instead of a path" \
  "$(cat "$(fixture basic.yaml)")" "" "main" \
  "example-prod" "example-prod-project" "europe-west1" "1" "gke-prod.example.gke.goog"

# The environment shape: one entry per environment, the most specific match wins and
# the namespace comes from the resolved entry.
assert_env "an environment shape document exports the namespace of the match" \
  "$(fixture envs-basic.yaml)" "" "main" \
  "example-prod" "example-prod-project" "europe-west1" "1" "gke-prod.example.gke.goog" "example-prod"

assert_env "a more specific pattern wins over a catch-all declared before it" \
  "$(fixture envs-basic.yaml)" "" "release/1" \
  "example-prod" "example-prod-project" "europe-west1" "1" "gke-prod.example.gke.goog" "example-stage"

assert_env "the explicit catch-all takes the branches nothing else claims" \
  "$(fixture envs-basic.yaml)" "" "feature/login/sso" \
  "example-dev" "example-dev-project" "europe-west1" "1" "gke-dev.example.gke.goog" "example-dev"

assert_env "a refs/tags pattern claims the tag" \
  "$(fixture envs-basic.yaml)" "v1.2.3" "" \
  "example-prod" "example-prod-project" "europe-west1" "1" "gke-prod.example.gke.goog" "example-prod"

assert_exit "a tag no environment claims resolves nothing" 3 \
  "$(fixture envs-basic.yaml)" "release/1" ""

assert_exit "a pipeline without branch or tag resolves no environment" 3 \
  "$(fixture envs-basic.yaml)" "" ""

assert_exit "two environments matching at equal rank are an error" 1 \
  "$(fixture envs-tie.yaml)" "" "release/1"

assert_exit "an environment entry without a namespace is an error" 1 \
  "$(fixture envs-missing-fields.yaml)" "" "main"

assert_exit "an environment with a scalar refs is an error" 1 \
  "$(fixture envs-scalar-refs.yaml)" "" "main"

assert_exit "an environment without a refs list is an error" 1 \
  "$(fixture envs-no-refs.yaml)" "" "main"

assert_exit "an empty envs list is an error" 1 \
  "$(fixture envs-empty.yaml)" "" "main"

assert_exit "a document carrying both shapes is an error" 1 \
  "$(fixture both-shapes.yaml)" "" "main"

# The vectors shared with the platform generator. Each scenario becomes an
# environment shape document with invented connection data, run once in the declared
# order and once reversed: specificity decides, so the order must not matter.
vectors_document() {
  jq --argjson index "${1}" --arg order "${2}" '
    .scenarios[$index].envs
    | (if $order == "reversed" then reverse else . end)
    | {envs: [.[] | {
        env: .name,
        namespace: ("ns-" + .name),
        name: ("cluster-" + .name),
        project_id: ("example-" + .name + "-project"),
        location: "europe-west1",
        refs: .refs
      }]}
  ' "${VECTORS}"
}

# A generated document must satisfy the generator schema, or the vectors and the
# schema have drifted apart.
assert_generated_document_validates() {
  local description="the generated document is valid: ${1}"
  local output

  if [ ! -f "${SCHEMA_COPY}" ] || ! command -v jv >/dev/null 2>&1; then
    return 0
  fi

  if output="$(jv "${SCHEMA_COPY}" "${2}" 2>&1)"; then
    report_pass "${description}"
  else
    report_fail "${description}" "${output}"
  fi
}

run_vectors() {
  local dir count index order name config case_count case_index ref env tag branch description

  if [ ! -f "${VECTORS}" ]; then
    report_fail "the shared vectors file is present" "${VECTORS} is missing"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '\n  skip  shared vectors: the jq command is not available\n\n'
    return 0
  fi

  printf '\nShared ref matching vectors from %s\n' "${VECTORS}"

  dir="$(mktemp -d)"
  count="$(jq '.scenarios | length' "${VECTORS}")"

  index=0
  while [ "${index}" -lt "${count}" ]; do
    name="$(jq -r --argjson index "${index}" '.scenarios[$index].name' "${VECTORS}")"
    case_count="$(jq --argjson index "${index}" '.scenarios[$index].cases | length' "${VECTORS}")"

    for order in declared reversed; do
      config="${dir}/scenario-${index}-${order}.yaml"
      vectors_document "${index}" "${order}" >"${config}"
      assert_generated_document_validates "${name} (${order})" "${config}"

      case_index=0
      while [ "${case_index}" -lt "${case_count}" ]; do
        ref="$(jq -r --argjson index "${index}" --argjson case "${case_index}" \
          '.scenarios[$index].cases[$case].ref' "${VECTORS}")"
        env="$(jq -r --argjson index "${index}" --argjson case "${case_index}" \
          '.scenarios[$index].cases[$case].env // ""' "${VECTORS}")"
        description="${name} (${order}): ${ref}"
        tag=""
        branch=""

        case "${ref}" in
        refs/tags/*) tag="${ref#refs/tags/}" ;;
        refs/heads/*) branch="${ref#refs/heads/}" ;;
        *)
          report_fail "${description}" "the vectors carry a ref that is neither a branch nor a tag"
          case_index=$((case_index + 1))
          continue
          ;;
        esac

        if [ -z "${env}" ]; then
          assert_exit "${description} resolves nothing" 3 "${config}" "${tag}" "${branch}"
        else
          assert_env "${description} resolves ${env}" "${config}" "${tag}" "${branch}" \
            "cluster-${env}" "example-${env}-project" "europe-west1" "0" "" "ns-${env}"
        fi

        case_index=$((case_index + 1))
      done
    done

    index=$((index + 1))
  done

  rm -rf "${dir}"
  printf '\n'
}

run_vectors

# The output is eval'd by the CI wrapper, so a hostile cluster name must not execute.
assert_eval_safety() {
  local description="eval of the exports does not execute a hostile cluster name"
  local output
  local expected_name="evil'; touch ${PWNED_MARKER}; '"

  rm -f "${PWNED_MARKER}"
  output="$(run_resolver "$(fixture injection.yaml)" "" "main")"

  (
    eval "${output}"
    if [ "${K8S_CLUSTER_NAME}" != "${expected_name}" ]; then
      printf 'name mismatch: %s\n' "${K8S_CLUSTER_NAME}"
      exit 1
    fi
  ) >/tmp/spark-k8s-resolver-eval.log 2>&1
  local rc=$?

  if [ "${rc}" != "0" ]; then
    report_fail "${description}" "$(cat /tmp/spark-k8s-resolver-eval.log)"
  elif [ -e "${PWNED_MARKER}" ]; then
    report_fail "${description}" "the injected command was executed"
  else
    report_pass "${description}"
  fi

  rm -f "${PWNED_MARKER}" /tmp/spark-k8s-resolver-eval.log
}

# The resolver must remove the temporary file it writes for an inline configuration.
# A private TMPDIR keeps the check deterministic on a shared runner.
assert_no_temporary_file_leak() {
  local description="an inline configuration leaves no temporary file behind"
  local tmpdir leftover

  tmpdir="$(mktemp -d)"
  TMPDIR="${tmpdir}" run_resolver "$(cat "$(fixture basic.yaml)")" "" "main" >/dev/null
  leftover="$(find "${tmpdir}" -mindepth 1 2>/dev/null | wc -l)"
  rm -rf "${tmpdir}"

  if [ "${leftover}" != "0" ]; then
    report_fail "${description}" "${leftover} temporary entries left behind"
  else
    report_pass "${description}"
  fi
}

# Agent variables alongside SPARK_K8S_CONFIG must warn, still resolve, and never switch context.
assert_agent_coexistence() {
  local description="agent variables alongside the resolver warn and are ignored"
  local output errors rc

  output="$(GITLAB_AGENT_ID="7" GITLAB_AGENT_PROJECT="group/agents" \
    DEVELOP_GITLAB_AGENT_ID="" DEVELOP_GITLAB_AGENT_PROJECT="" \
    PRODUCTION_GITLAB_AGENT_ID="" PRODUCTION_GITLAB_AGENT_PROJECT="" \
    invoke_resolver "$(fixture basic.yaml)" "" "main" 2>/tmp/spark-k8s-resolver-agent.err)"
  rc=$?
  errors="$(cat /tmp/spark-k8s-resolver-agent.err)"
  rm -f /tmp/spark-k8s-resolver-agent.err

  if [ "${rc}" != "0" ]; then
    report_fail "${description}" "expected exit 0, got ${rc}"
  elif ! printf '%s' "${output}" | grep -q "^export DISABLE_GITLAB_AGENT='1'$"; then
    report_fail "${description}" "DISABLE_GITLAB_AGENT=1 was not exported"
  elif ! printf '%s' "${errors}" | grep -q "GITLAB_AGENT_ID is set together with SPARK_K8S_CONFIG"; then
    report_fail "${description}" "no warning about GITLAB_AGENT_ID on stderr"
  else
    report_pass "${description}"
  fi
}

assert_agent_setup_skipped() {
  local description="setup-gitlab-agent does not switch context while the resolver is active"
  local output

  output="$(
    # Invoked by setup-gitlab-agent only if the guard fails.
    # shellcheck disable=SC2317
    kubectl() { printf 'KUBECTL CALLED: %s\n' "$*"; return 1; }
    export -f kubectl
    SPARK_K8S_CONFIG="/nonexistent/config.yaml" GITLAB_AGENT_ID="7" GITLAB_AGENT_PROJECT="group/agents" \
      CI_COMMIT_REF_SLUG="main" KUBE_NAMESPACE="ns" \
      bash -c 'source "'"${ROOT_DIR}"'/scripts/src/functions.bash"; setup-gitlab-agent' 2>&1
  )"

  if printf '%s' "${output}" | grep -q "KUBECTL CALLED"; then
    report_fail "${description}" "kubectl was invoked:" "${output}"
  elif ! printf '%s' "${output}" | grep -q "cluster resolver is active"; then
    report_fail "${description}" "no resolver notice in the output"
  else
    report_pass "${description}"
  fi
}

# The CI wrapper around the resolver: the before_script of .spark-k8s-cluster-resolver,
# extracted from the template and run under sh, the shell a job image without bash has.
TEMPLATE="${ROOT_DIR}/templates/functions/spark-k8s-cluster-resolver.yml"
SH_BIN="$(command -v sh)"

# run_before_script <resolver path> <path> <tag> <branch> [config]: runs the wrapper
# with the single-value variables preset, /scripts/resolve-cluster rewritten to
# <resolver path> and PATH set to <path>, then prints the resulting variables, pipe
# separated. Standard error is kept: the resolver logs the resolved environment there.
run_before_script() {
  local body
  body="$(yq4 '.[".spark-k8s-cluster-resolver"].before_script[0]' "${TEMPLATE}" |
    sed "s|/scripts/resolve-cluster|${1}|g")"
  # The trailing printf is appended verbatim: the child shell expands it.
  # shellcheck disable=SC2016
  PATH="${2}" \
    K8S_CLUSTER_NAME="legacy-cluster" \
    GCP_PROJECT_ID="legacy-project" \
    K8S_LOCATION="europe-west1" \
    K8S_USE_DNS_ENDPOINT="0" \
    KUBE_NAMESPACE="legacy-namespace" \
    SPARK_K8S_CONFIG="${5:-$(fixture basic.yaml)}" \
    CI_COMMIT_TAG="${3}" \
    CI_COMMIT_BRANCH="${4}" \
    GITLAB_AGENT_ID="" \
    GITLAB_AGENT_PROJECT="" \
    "${SH_BIN}" -c "${body}"'
printf "%s|%s|%s|%s|%s|%s|%s\n" "${K8S_CLUSTER_NAME:-}" "${GCP_PROJECT_ID:-}" \
  "${K8S_LOCATION:-}" "${K8S_USE_DNS_ENDPOINT:-}" "${DISABLE_GITLAB_AGENT:-}" \
  "${SPARK_K8S_CLUSTER_RESOLVED:-}" "${KUBE_NAMESPACE:-}"' 2>&1
}

# assert_before_script <description> <resolver path> <path> <tag> <branch> \
#                      <expected variables> <expected log fragment> [config]
assert_before_script() {
  local description="${1}"
  local output rc variables

  output="$(run_before_script "${2}" "${3}" "${4}" "${5}" "${8:-}")"
  rc=$?
  variables="$(printf '%s\n' "${output}" | tail -n 1)"

  if [ "${rc}" != "0" ]; then
    report_fail "${description}" "expected exit 0, got ${rc}:" "${output}"
  elif [ "${variables}" != "${6}" ]; then
    report_fail "${description}" "unexpected variables: ${variables}" "expected: ${6}"
  elif ! printf '%s' "${output}" | grep -qF -- "${7}"; then
    report_fail "${description}" "log does not contain '${7}':" "${output}"
  else
    report_pass "${description}"
  fi
}

# A skip must not touch the single-value variables: a job image without the resolver
# keeps deploying to the cluster they describe (spark-data-hub, 2026-09-04).
PRESERVED="legacy-cluster|legacy-project|europe-west1|0||0|legacy-namespace"

assert_before_script "a job image without the resolver keeps the single-value variables" \
  "${TEST_DIR}/no-such-resolve-cluster" "${PATH}" "" "main" \
  "${PRESERVED}" "not available in this job image"

assert_before_script "a job image without bash keeps the single-value variables" \
  "${RESOLVER}" "" "" "main" \
  "${PRESERVED}" "bash is not available"

assert_before_script "a resolved ref replaces the single-value variables" \
  "${RESOLVER}" "${PATH}" "" "main" \
  "example-prod|example-prod-project|europe-west1|1|1|1|legacy-namespace" "Resolved cluster: example-prod"

assert_before_script "a ref that owns no cluster clears the single-value variables" \
  "${RESOLVER}" "${PATH}" "" "" \
  "|||||0|legacy-namespace" "No cluster owns the current ref"

# The environment shape owns KUBE_NAMESPACE as well, and the resolver logs the
# environment it resolved, because its name is not exported.
assert_before_script "a resolved environment replaces the namespace too" \
  "${RESOLVER}" "${PATH}" "" "main" \
  "example-prod|example-prod-project|europe-west1|1|1|1|example-prod" \
  "Resolved environment: prod (namespace example-prod, cluster example-prod, project example-prod-project, location europe-west1)" \
  "$(fixture envs-basic.yaml)"

assert_before_script "a ref no environment claims keeps the project namespace" \
  "${RESOLVER}" "${PATH}" "release/1" "" \
  "|||||0|legacy-namespace" "No cluster owns the current ref" \
  "$(fixture envs-basic.yaml)"

assert_eval_safety
assert_agent_coexistence
assert_agent_setup_skipped
assert_no_temporary_file_leak

printf '\n%s passed, %s failed\n' "${PASSED}" "${FAILED}"

if [ "${FAILED}" != "0" ]; then
  exit 1
fi
