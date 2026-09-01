#!/usr/bin/env bash

# This file contains functions and the few variables they use to return values
# to their caller. Nothing is executed here: sourcing this file makes all
# functions available without touching the environment.
#
# These functions implement the runtime ref-to-cluster resolver. They read the
# project cluster configuration pointed to by SPARK_K8S_CONFIG and pick the
# cluster that owns the current git ref, then print the variables consumed by
# the `.gke-kubeconfig` template as shell `export` lines on stdout.
#
# Diagnostics go to stderr, so stdout stays eval-able.

# Supported cluster configuration schema version.
RESOLVER_SUPPORTED_SCHEMA_VERSION=1

# Set by resolver_config_file to the configuration file to read.
RESOLVER_CONFIG_FILE=""

# Set by resolver_config_file when a temporary directory was created to hold
# the configuration, so the caller can remove it.
RESOLVER_TMP_CONFIG_DIR=""

# Set by resolve_cluster to the index of the selected cluster.
RESOLVER_SELECTED=""

_resolver_log() {
  printf '%s\n' "${*}" >&2
}

# Print the normalized ref of the current pipeline.
#
# Only CI_COMMIT_TAG and CI_COMMIT_BRANCH are read. CI_COMMIT_REF_NAME does not
# distinguish a tag from a branch, so with it a tag named "main" would match a
# branch rule. Prints nothing when the pipeline has no ref, which is the case
# for merge request pipelines.
resolver_normalized_ref() {
  if [ -n "${CI_COMMIT_TAG:-}" ]; then
    printf 'refs/tags/%s' "${CI_COMMIT_TAG}"
  elif [ -n "${CI_COMMIT_BRANCH:-}" ]; then
    printf 'refs/heads/%s' "${CI_COMMIT_BRANCH}"
  fi
}

# Print the ref namespace of the current pipeline: "tags", "heads" or nothing.
resolver_ref_kind() {
  if [ -n "${CI_COMMIT_TAG:-}" ]; then
    printf 'tags'
  elif [ -n "${CI_COMMIT_BRANCH:-}" ]; then
    printf 'heads'
  fi
}

_resolver_ere_escape_char() {
  case "${1}" in
  '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '[' | ']' | '*' | '?' | "\\")
    printf '\\%s' "${1}"
    ;;
  *)
    printf '%s' "${1}"
    ;;
  esac
}

# Translate a glob pattern into an anchored POSIX ERE.
#
# `*` does not cross a slash, `**` does, `?` matches a single non-slash
# character and a backslash escapes the next character. Bracket expressions are
# not supported: their brackets are translated to literals.
resolver_glob_to_ere() {
  local pattern="${1}"
  local length=${#pattern}
  local index=0
  local out=""
  local char next

  while [ "${index}" -lt "${length}" ]; do
    char="${pattern:index:1}"
    case "${char}" in
    "\\")
      index=$((index + 1))
      next="${pattern:index:1}"
      if [ -z "${next}" ]; then
        out="${out}\\\\"
      else
        out="${out}$(_resolver_ere_escape_char "${next}")"
      fi
      ;;
    '*')
      if [ "${pattern:index+1:1}" = "*" ]; then
        out="${out}.*"
        index=$((index + 1))
      else
        out="${out}[^/]*"
      fi
      ;;
    '?')
      out="${out}[^/]"
      ;;
    *)
      out="${out}$(_resolver_ere_escape_char "${char}")"
      ;;
    esac
    index=$((index + 1))
  done

  printf '^%s$' "${out}"
}

# Translate the inner part of a /regex/ pattern into a POSIX ERE.
#
# ERE has none of the PCRE shorthand classes, so the ones that appear in real
# GitLab configuration are expanded. Any other backslash shorthand, and any
# `(?...)` group, is rejected: silently matching nothing is worse than failing
# with the offending pattern in the log. The result is not anchored, so `^` and
# `$` behave as the author wrote them.
resolver_regex_to_ere() {
  local pattern="${1}"
  local length=${#pattern}
  local index=0
  local out=""
  local char next

  while [ "${index}" -lt "${length}" ]; do
    char="${pattern:index:1}"
    case "${char}" in
    "\\")
      index=$((index + 1))
      next="${pattern:index:1}"
      case "${next}" in
      'd') out="${out}[0-9]" ;;
      'D') out="${out}[^0-9]" ;;
      'w') out="${out}[A-Za-z0-9_]" ;;
      'W') out="${out}[^A-Za-z0-9_]" ;;
      's') out="${out}[[:space:]]" ;;
      'S') out="${out}[^[:space:]]" ;;
      '/') out="${out}/" ;;
      [A-Za-z0-9] | '')
        _resolver_log "Unsupported escape sequence '\\${next}' in regex pattern '/${pattern}/'."
        return 1
        ;;
      *) out="${out}\\${next}" ;;
      esac
      ;;
    '(')
      if [ "${pattern:index+1:1}" = "?" ]; then
        _resolver_log "Unsupported group '(?' in regex pattern '/${pattern}/'."
        return 1
      fi
      out="${out}("
      ;;
    *)
      out="${out}${char}"
      ;;
    esac
    index=$((index + 1))
  done

  printf '%s' "${out}"
}

# Return 0 when the pattern owns the given ref, 1 when it does not and 2 when
# the pattern itself is invalid.
#
# A glob always matches the normalized ref, prefixed with refs/heads/ when the
# pattern does not already name a ref namespace. A /regex/ that mentions refs/
# matches the normalized ref as well; a /regex/ that does not matches the short
# branch name and only on branch pipelines. That asymmetry is what keeps
# `/^release-\d+$/` from matching a tag named release-1, without rewriting a
# user supplied pattern.
resolver_pattern_matches() {
  local pattern="${1}"
  local ref="${2}"
  local kind="${3}"
  local ere target

  if [ -z "${pattern}" ]; then
    return 1
  fi

  if [ "${#pattern}" -ge 2 ] && [ "${pattern:0:1}" = "/" ] && [ "${pattern: -1}" = "/" ]; then
    if ! ere="$(resolver_regex_to_ere "${pattern:1:${#pattern}-2}")"; then
      return 2
    fi
    # "Mentions refs/" means refs/ at the start of the expression or preceded
    # by a non-word character, not a plain substring: with a substring test a
    # pattern like /^prefs\/x$/ would be matched against the normalized ref
    # and silently never match the prefs/x branch.
    if printf '%s' "${ere}" | grep -Eq '(^|[^A-Za-z0-9_])refs/'; then
      target="${ref}"
    else
      if [ "${kind}" != "heads" ]; then
        return 1
      fi
      target="${ref#refs/heads/}"
    fi
  else
    case "${pattern}" in
    refs/*) ere="$(resolver_glob_to_ere "${pattern}")" ;;
    *) ere="$(resolver_glob_to_ere "refs/heads/${pattern}")" ;;
    esac
    target="${ref}"
  fi

  printf '%s' "${target}" | grep -Eq -- "${ere}"
}

# Set RESOLVER_CONFIG_FILE to the configuration file to read.
#
# A GitLab File type variable holds a path, not the content. When the value is
# not a readable file it is treated as inline YAML and materialized, which also
# keeps the resolver easy to drive from tests.
#
# Either way the configuration is reached through a path whose name ends in
# .yaml, because jv picks its parser from the file extension and a File type
# variable lands on an extensionless path, where it would be read as JSON. An
# already suffixed path is used as is; anything else is linked or written into
# a temporary directory.
#
# The result is returned through a global rather than printed: a command
# substitution would run this in a subshell, and the temporary directory
# recorded in RESOLVER_TMP_CONFIG_DIR would be lost together with it, leaving
# the directory behind.
resolver_config_file() {
  local value="${1}"
  local dir target

  RESOLVER_CONFIG_FILE=""

  case "${value}" in
  *.yaml | *.yml)
    if [ -f "${value}" ] && [ -r "${value}" ]; then
      RESOLVER_CONFIG_FILE="${value}"
      return 0
    fi
    ;;
  esac

  if ! dir="$(mktemp -d -t spark_k8s_config.XXXXXX)"; then
    _resolver_log "Cannot create a temporary directory for the cluster configuration."
    return 1
  fi
  # Consumed by the caller, which removes the directory on exit.
  # shellcheck disable=SC2034
  RESOLVER_TMP_CONFIG_DIR="${dir}"
  target="${dir}/cluster-config.yaml"

  if [ -f "${value}" ] && [ -r "${value}" ]; then
    if ! ln -s "${value}" "${target}"; then
      _resolver_log "Cannot link the cluster configuration into ${dir}."
      return 1
    fi
  elif ! (
    umask 077
    printf '%s\n' "${value}" >"${target}"
  ); then
    _resolver_log "Cannot write the inline cluster configuration to ${target}."
    return 1
  fi

  RESOLVER_CONFIG_FILE="${target}"
}

# Print the path of the cluster configuration schema, if one is available.
#
# SPARK_K8S_CONFIG_SCHEMA overrides the location. The test suite uses it to
# point the resolver at a deliberately permissive schema for the fixtures that
# exercise the resolver's own tolerance. There is no variable to turn
# validation off: an opt-out would be set by the first project that wants a
# deploy out despite a broken configuration, which is exactly the case this is
# here to stop.
resolver_schema_file() {
  local candidate

  if [ -n "${SPARK_K8S_CONFIG_SCHEMA:-}" ]; then
    printf '%s' "${SPARK_K8S_CONFIG_SCHEMA}"
    return 0
  fi

  for candidate in "/schemas/cluster-config.schema.json" \
    "${DEPLOY_ROOT_DIR:-}/../schemas/cluster-config.schema.json"; do
    if [ -f "${candidate}" ] && [ -r "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
}

# Validate the configuration against the schema owned by the platform
# generator, and fail on any violation.
#
# A missing validator or a missing schema copy is a warning, not a failure:
# this mirrors the contract of the CI template, which degrades to the previous
# behavior when the job image lacks tooling. The structural checks below still
# cover what makes a wrong resolution dangerous, and the generator validates
# every document it emits at the source.
resolver_validate_schema() {
  local file="${1}"
  local schema output

  schema="$(resolver_schema_file)"
  if [ -z "${schema}" ]; then
    _resolver_log "Schema validation skipped: no cluster configuration schema available."
    return 0
  fi

  if ! command -v jv >/dev/null 2>&1; then
    _resolver_log "Schema validation skipped: the jv command is not available."
    return 0
  fi

  if output="$(jv "${schema}" "${file}" 2>&1)"; then
    return 0
  fi

  _resolver_log "The cluster configuration does not match ${schema}:"
  _resolver_log "${output}"
  return 1
}

# Validate the configuration file: parseable YAML, a supported schema version,
# a non empty `clusters` sequence, at most one default cluster and a list in
# every declared `refs`.
resolver_check_config() {
  local file="${1}"
  local version kind length default_count scalar_refs_count

  if ! version="$(yq4 e '.version // 1' "${file}" 2>/dev/null)"; then
    _resolver_log "The cluster configuration is not valid YAML."
    return 1
  fi
  if [ "${version}" != "${RESOLVER_SUPPORTED_SCHEMA_VERSION}" ]; then
    _resolver_log "Unsupported cluster configuration version '${version}', this resolver supports version ${RESOLVER_SUPPORTED_SCHEMA_VERSION}."
    return 1
  fi

  kind="$(yq4 e '.clusters | tag' "${file}" 2>/dev/null)"
  if [ "${kind}" != "!!seq" ]; then
    _resolver_log "The cluster configuration has no 'clusters' list."
    return 1
  fi

  length="$(yq4 e '.clusters | length' "${file}" 2>/dev/null)"
  if [ "${length}" = "0" ]; then
    _resolver_log "The cluster configuration declares an empty 'clusters' list."
    return 1
  fi

  # An empty count means the yq4 invocation itself failed. Without this guard
  # the -gt test below errors and the `if` treats that as false, so a transient
  # parser failure would pass validation instead of failing it.
  default_count="$(yq4 e '[.clusters[] | select(.default == true)] | length' "${file}" 2>/dev/null)"
  if [ -z "${default_count}" ]; then
    _resolver_log "Cannot count the default clusters in the configuration."
    return 1
  fi
  if [ "${default_count}" -gt 1 ]; then
    _resolver_log "The cluster configuration declares ${default_count} default clusters, only one is allowed."
    return 1
  fi

  # `refs: main` instead of `refs: [main]` yields no patterns at all, so the
  # entry would be skipped in silence and the default cluster chosen instead.
  scalar_refs_count="$(yq4 e '[.clusters[] | select(has("refs") and (.refs | tag) != "!!seq")] | length' "${file}" 2>/dev/null)"
  if [ -z "${scalar_refs_count}" ]; then
    _resolver_log "Cannot check the refs lists in the configuration."
    return 1
  fi
  if [ "${scalar_refs_count}" != "0" ]; then
    _resolver_log "The cluster configuration declares ${scalar_refs_count} clusters whose 'refs' is not a list."
    return 1
  fi

  return 0
}

# Print the number of declared clusters.
resolver_cluster_count() {
  yq4 e '.clusters | length' "${1}"
}

# Print a scalar field of a cluster, empty when it is not declared.
#
# The `//` alternative operator is not used on purpose: in yq, as in jq, it also
# replaces `false`, which would silently turn `use_dns_endpoint: false` into the
# default. A missing field prints `null` instead, and that is mapped to empty
# here.
resolver_cluster_field() {
  local value

  value="$(yq4 e ".clusters[${2}].${3}" "${1}")" || return 1
  if [ "${value}" = "null" ]; then
    printf ''
    return 0
  fi
  printf '%s' "${value}"
}

# Print the ref patterns of a cluster, one per line. A git ref name cannot
# contain a newline, so the list round trips safely.
resolver_cluster_refs() {
  yq4 e "(.clusters[${2}].refs // [])[]" "${1}"
}

# Print the index of the cluster flagged as default, if any.
resolver_default_index() {
  yq4 e '.clusters | to_entries | .[] | select(.value.default == true) | .key' "${1}"
}

# Warn when the GitLab Agent variables are set together with the resolver.
#
# The resolver wins: it exports DISABLE_GITLAB_AGENT=1 and `setup-gitlab-agent`
# refuses to run while SPARK_K8S_CONFIG is set. Once every agent path project
# has migrated this can become a hard failure by replacing the `return 0` below
# with `return 1`; the caller already treats a non zero return as fatal.
resolver_warn_on_agent_variables() {
  local var_name
  local found=0

  for var_name in GITLAB_AGENT_ID GITLAB_AGENT_PROJECT \
    DEVELOP_GITLAB_AGENT_ID DEVELOP_GITLAB_AGENT_PROJECT \
    PRODUCTION_GITLAB_AGENT_ID PRODUCTION_GITLAB_AGENT_PROJECT; do
    if [ -n "${!var_name:-}" ]; then
      _resolver_log "Warning: ${var_name} is set together with SPARK_K8S_CONFIG."
      found=1
    fi
  done

  if [ "${found}" = "1" ]; then
    _resolver_log "Warning: the cluster resolver takes precedence, the GitLab Agent will not be used."
  fi

  return 0
}


_resolver_emit_export() {
  local value="${2//\'/\'\\\'\'}"
  printf "export %s='%s'\n" "${1}" "${value}"
}

# Print the export lines for the cluster at the given index.
#
# The DNS endpoint is exported for downstream use but never logged: it
# identifies a private control plane and a job log is not a good place for it.
resolver_emit_selected() {
  local file="${1}"
  local index="${2}"
  local name project_id location dns_endpoint use_dns_endpoint
  local use_dns_flag="0"
  local missing=""

  name="$(resolver_cluster_field "${file}" "${index}" "name")"
  project_id="$(resolver_cluster_field "${file}" "${index}" "project_id")"
  location="$(resolver_cluster_field "${file}" "${index}" "location")"
  dns_endpoint="$(resolver_cluster_field "${file}" "${index}" "dns_endpoint")"
  use_dns_endpoint="$(resolver_cluster_field "${file}" "${index}" "use_dns_endpoint")"

  [ -n "${name}" ] || missing="${missing} name"
  [ -n "${project_id}" ] || missing="${missing} project_id"
  [ -n "${location}" ] || missing="${missing} location"
  if [ -n "${missing}" ]; then
    _resolver_log "The selected cluster entry is missing required fields:${missing}."
    return 1
  fi

  case "${use_dns_endpoint}" in
  true) use_dns_flag="1" ;;
  false) use_dns_flag="0" ;;
  '')
    # No explicit flag: infer it from the presence of a dns_endpoint, so a
    # configuration written before the flag existed keeps working.
    if [ -n "${dns_endpoint}" ]; then
      use_dns_flag="1"
    fi
    ;;
  *)
    # A value like "1", yes or on reaches this branch as a string. Falling
    # into the infer branch would silently replace what the author asked for
    # with a guess, so it is an error instead.
    _resolver_log "The cluster '${name}' declares an unrecognized use_dns_endpoint value '${use_dns_endpoint}', only true and false are accepted."
    return 1
    ;;
  esac

  _resolver_emit_export "K8S_CLUSTER_NAME" "${name}"
  _resolver_emit_export "GCP_PROJECT_ID" "${project_id}"
  _resolver_emit_export "K8S_LOCATION" "${location}"
  _resolver_emit_export "K8S_USE_DNS_ENDPOINT" "${use_dns_flag}"
  _resolver_emit_export "SPARK_K8S_CLUSTER_DNS_ENDPOINT" "${dns_endpoint}"
  _resolver_emit_export "DISABLE_GITLAB_AGENT" "1"
}

# Resolve the cluster that owns the current ref and print its export lines.
#
# Returns 0 when a cluster was selected, 3 when the pipeline has no ref to
# resolve and 1 on any configuration error.
resolve_cluster() {
  local file ref kind count index pattern rc name

  if [ -z "${SPARK_K8S_CONFIG:-}" ]; then
    _resolver_log "SPARK_K8S_CONFIG is not set, there is nothing to resolve."
    return 1
  fi

  if ! command -v yq4 >/dev/null 2>&1; then
    _resolver_log "The yq4 command is not available, the cluster configuration cannot be parsed."
    return 1
  fi

  if ! resolver_config_file "${SPARK_K8S_CONFIG}"; then
    return 1
  fi
  file="${RESOLVER_CONFIG_FILE}"

  # The schema speaks before the structural checks, so an operator sees the
  # exact JSON Pointer into their document rather than the coarser message
  # below. It runs after resolver_config_file so an inline configuration is
  # validated too, not only a File type variable.
  if ! resolver_validate_schema "${file}"; then
    return 1
  fi

  if ! resolver_check_config "${file}"; then
    return 1
  fi

  ref="$(resolver_normalized_ref)"
  kind="$(resolver_ref_kind)"

  # Merge request pipelines have neither CI_COMMIT_TAG nor CI_COMMIT_BRANCH.
  # There is no ref to resolve, and falling back to the default cluster here
  # would deploy a merge request to whatever cluster is marked default.
  if [ -z "${ref}" ]; then
    _resolver_log "The pipeline has no branch or tag ref, no cluster can be resolved."
    return 3
  fi

  count="$(resolver_cluster_count "${file}")"
  RESOLVER_SELECTED=""

  # Scan bottom up, so the first match is the last declared one.
  index=$((count - 1))
  while [ "${index}" -ge 0 ]; do
    while IFS= read -r pattern; do
      [ -n "${pattern}" ] || continue
      resolver_pattern_matches "${pattern}" "${ref}" "${kind}"
      rc=$?
      if [ "${rc}" = "2" ]; then
        return 1
      fi
      if [ "${rc}" = "0" ]; then
        RESOLVER_SELECTED="${index}"
        name="$(resolver_cluster_field "${file}" "${index}" "name")"
        _resolver_log "The ref '${ref}' matches the pattern '${pattern}' of cluster '${name}'."
        break
      fi
    done < <(resolver_cluster_refs "${file}" "${index}")

    [ -z "${RESOLVER_SELECTED}" ] || break
    index=$((index - 1))
  done

  if [ -z "${RESOLVER_SELECTED}" ]; then
    RESOLVER_SELECTED="$(resolver_default_index "${file}")"
    if [ -z "${RESOLVER_SELECTED}" ]; then
      _resolver_log "The ref '${ref}' matches no cluster and the configuration declares no default cluster."
      return 1
    fi
    _resolver_log "The ref '${ref}' matches no cluster, using the default one."
  fi

  resolver_warn_on_agent_variables || return 1
  resolver_emit_selected "${file}" "${RESOLVER_SELECTED}"
}
