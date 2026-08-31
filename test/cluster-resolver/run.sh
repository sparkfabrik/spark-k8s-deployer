#!/usr/bin/env bash

# Table driven tests for scripts/resolve-cluster.
#
# The resolver parses YAML with yq4 and validates it with jv, so this suite must
# run where both are available. The deployer image ships them:
#
#   make test-cluster-resolver
#
# Two things are tested here. The resolver cases check what the resolver does
# with a given configuration and ref. The schema gate checks every fixture
# against schemas/cluster-config.schema.json, the copy of the schema the
# platform generator owns, in both directions: a fixture that should validate
# must validate, and a fixture that should be rejected must be rejected. That
# second direction is what turns a breaking schema sync into a red pipeline
# here instead of a failed deploy later.
#
# Exits non zero when any case fails.

set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -P "${TEST_DIR}/../.." && pwd)"
RESOLVER="${ROOT_DIR}/scripts/resolve-cluster"
FIXTURES_DIR="${TEST_DIR}/fixtures"
PWNED_MARKER="/tmp/spark-k8s-resolver-pwned"

# The generator owned schema, synced into this repository. SPARK_K8S_SCHEMA_COPY
# exists so the gate can be pointed at a copy that has not been merged yet.
SCHEMA_COPY="${SPARK_K8S_SCHEMA_COPY:-${ROOT_DIR}/schemas/cluster-config.schema.json}"

# The permissive schema used by the fixtures that exercise resolver tolerance.
TOLERANCE_SCHEMA="${TEST_DIR}/schemas/tolerance.schema.json"

# Fixtures that must validate against the generator schema. They carry `name`,
# `project_id`, `location`, `default` and `refs` on every entry and exactly one
# default cluster, which is what the generator emits.
SCHEMA_CONFORMING_FIXTURES="basic.yaml ordering.yaml globs.yaml regex.yaml dns.yaml bad-regex.yaml"

# Fixtures the generator schema must reject. Most exercise what the resolver
# does with a document nobody should emit; the rest are invalid on purpose.
# Note that bad-regex.yaml is deliberately NOT here: an unsupported regex
# construct is a valid string as far as the schema is concerned, so that
# fixture proves the resolver still guards what the schema cannot express.
SCHEMA_NON_CONFORMING_FIXTURES="no-default.yaml no-refs-no-default.yaml missing-fields.yaml scalar-refs.yaml injection.yaml two-defaults.yaml bad-version.yaml empty-clusters.yaml no-clusters-key.yaml malformed.yaml"

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

# Print the schema a given configuration must be validated against.
#
# A fixture classified as non-conforming gets the permissive schema, so its exit
# code comes from the resolver's own checks rather than from validation, which
# is what those cases are testing. Everything else gets the real copy, or
# nothing at all when the copy has not been synced yet, in which case the
# resolver skips validation exactly as it does in a job image without it.
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

# run_resolver <config> <tag> <branch>
#
# The GitLab Agent variables are cleared so the conflict warning does not
# depend on the environment the suite runs in.
run_resolver() {
  CI_COMMIT_TAG="${2}" \
    CI_COMMIT_BRANCH="${3}" \
    SPARK_K8S_CONFIG="${1}" \
    SPARK_K8S_CONFIG_SCHEMA="$(schema_for_config "${1}")" \
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

# Every fixture has to be classified, otherwise a fixture added later slips
# past the gate without anyone deciding which side of the contract it is on.
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

assert_exit "an unsupported regex construct fails the resolution" 1 \
  "$(fixture bad-regex.yaml)" "" "main"

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
# to remove before exiting.
assert_no_temporary_file_leak() {
  local description="an inline configuration leaves no temporary file behind"
  local before after

  before="$(find /tmp -maxdepth 1 -name 'spark_k8s_config.*' 2>/dev/null | wc -l)"
  run_resolver "$(cat "$(fixture basic.yaml)")" "" "main" >/dev/null
  after="$(find /tmp -maxdepth 1 -name 'spark_k8s_config.*' 2>/dev/null | wc -l)"

  if [ "${before}" != "${after}" ]; then
    report_fail "${description}" "temporary files went from ${before} to ${after}"
  else
    report_pass "${description}"
  fi
}

assert_eval_safety
assert_no_temporary_file_leak

printf '\n%s passed, %s failed\n' "${PASSED}" "${FAILED}"

if [ "${FAILED}" != "0" ]; then
  exit 1
fi
