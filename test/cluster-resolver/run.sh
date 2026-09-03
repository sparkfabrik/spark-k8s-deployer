#!/usr/bin/env bash

# Table driven tests for scripts/resolve-cluster.
#
# The resolver parses YAML with yq4, so this suite must run where yq4 is
# available. The deployer image ships it:
#
#   make test-cluster-resolver
#
# Exits non zero when any case fails.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -P "${TEST_DIR}/../.." && pwd)"
RESOLVER="${ROOT_DIR}/scripts/resolve-cluster"
FIXTURES_DIR="${TEST_DIR}/fixtures"
PWNED_MARKER="/tmp/spark-k8s-resolver-pwned"

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

# run_resolver <config> <tag> <branch>
#
# The GitLab Agent variables are cleared so the conflict warning does not
# depend on the environment the suite runs in.
run_resolver() {
  CI_COMMIT_TAG="${2}" \
    CI_COMMIT_BRANCH="${3}" \
    SPARK_K8S_CONFIG="${1}" \
    GITLAB_AGENT_ID="" \
    GITLAB_AGENT_PROJECT="" \
    DEVELOP_GITLAB_AGENT_ID="" \
    DEVELOP_GITLAB_AGENT_PROJECT="" \
    PRODUCTION_GITLAB_AGENT_ID="" \
    PRODUCTION_GITLAB_AGENT_PROJECT="" \
    "${RESOLVER}" 2>/dev/null
}

expected_exports() {
  printf "export K8S_CLUSTER_NAME='%s'\n" "${1}"
  printf "export GCP_PROJECT_ID='%s'\n" "${2}"
  printf "export K8S_LOCATION='%s'\n" "${3}"
  printf "export K8S_USE_DNS_ENDPOINT='%s'\n" "${4}"
  printf "export SPARK_K8S_CLUSTER_DNS_ENDPOINT='%s'\n" "${5}"
  printf "export DISABLE_GITLAB_AGENT='1'\n"
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

printf 'Cluster resolver test suite\n'

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
  "last-match" "p-last" "europe-west1" "0" ""

assert_cluster "a lower catch-all wins over a higher exact match" \
  "$(fixture ordering.yaml)" "" "develop" \
  "catch-all" "p-catch-all" "europe-west1" "0" ""

# Glob semantics: * does not cross a slash, ** does.
assert_cluster "a single star does not cross a slash" \
  "$(fixture globs.yaml)" "" "feature/login" \
  "single-star" "p-single" "europe-west1" "0" ""

assert_cluster "a double star crosses slashes" \
  "$(fixture globs.yaml)" "" "feature/login/sso" \
  "double-star" "p-double" "europe-west1" "0" ""

assert_cluster "a refs/tags pattern matches a tag" \
  "$(fixture globs.yaml)" "v1" "" \
  "tags-only" "p-tags" "europe-west1" "0" ""

assert_cluster "a refs/tags pattern does not match a branch of the same name" \
  "$(fixture globs.yaml)" "" "v1" \
  "fallback" "p-fallback" "europe-west1" "0" ""

# Regex form: a pattern without refs/ matches the short branch name only.
assert_cluster "a branch regex matches the short branch name" \
  "$(fixture regex.yaml)" "" "release-12" \
  "releases" "p-releases" "europe-west1" "0" ""

assert_cluster "a branch regex does not match a tag of the same name" \
  "$(fixture regex.yaml)" "release-12" "" \
  "fallback" "p-fallback" "europe-west1" "0" ""

assert_cluster "a regex mentioning refs/ matches the normalized ref" \
  "$(fixture regex.yaml)" "v3" "" \
  "version-tags" "p-version-tags" "europe-west1" "0" ""

assert_cluster "a regex merely containing refs/ still matches the short branch name" \
  "$(fixture regex.yaml)" "" "prefs/x" \
  "prefs-regex" "spark-prefs-project" "europe-west1" "0" ""

assert_exit "an unsupported regex construct fails the resolution" 1 \
  "$(fixture bad-regex.yaml)" "" "main"

assert_exit "a PCRE shorthand inside a bracket expression fails the resolution" 1 \
  "$(fixture bracket-shorthand.yaml)" "" "v12"

# Pattern errors must not depend on which entry the scan reaches: here the
# broken pattern sits above an entry that matches main.
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
  "explicit-off" "p-off" "europe-west1" "0" "gke-off.example.gke.goog"

assert_cluster "an explicit use_dns_endpoint true needs no endpoint" \
  "$(fixture dns.yaml)" "" "on-branch" \
  "explicit-on" "p-on" "europe-west1" "1" ""

assert_cluster "a declared endpoint without the flag enables it" \
  "$(fixture dns.yaml)" "" "other" \
  "inferred" "p-inferred" "europe-west1" "1" "gke-inferred.example.gke.goog"

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

# The output is eval'd by the CI wrapper, so it must survive a hostile cluster
# name without executing anything.
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

# An inline configuration is written to a temporary file, which the resolver has
# to remove before exiting. The resolver is pointed at a private TMPDIR, so the
# check cannot be flipped by an unrelated process touching the shared /tmp
# while the suite runs directly on a CI runner.
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

# The GitLab Agent and the resolver are mutually exclusive: agent variables set
# alongside SPARK_K8S_CONFIG produce a warning, the resolution still succeeds,
# and setup-gitlab-agent must not switch the kubectl context.
assert_agent_coexistence() {
  local description="agent variables alongside the resolver warn and are ignored"
  local output errors rc

  output="$(CI_COMMIT_TAG="" CI_COMMIT_BRANCH="main" \
    SPARK_K8S_CONFIG="$(fixture basic.yaml)" \
    GITLAB_AGENT_ID="7" GITLAB_AGENT_PROJECT="group/agents" \
    DEVELOP_GITLAB_AGENT_ID="" DEVELOP_GITLAB_AGENT_PROJECT="" \
    PRODUCTION_GITLAB_AGENT_ID="" PRODUCTION_GITLAB_AGENT_PROJECT="" \
    "${RESOLVER}" 2>/tmp/spark-k8s-resolver-agent.err)"
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
    # Invoked indirectly by setup-gitlab-agent, if the guard fails.
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

assert_eval_safety
assert_agent_coexistence
assert_agent_setup_skipped
assert_no_temporary_file_leak

printf '\n%s passed, %s failed\n' "${PASSED}" "${FAILED}"

if [ "${FAILED}" != "0" ]; then
  exit 1
fi
