#!/usr/bin/env bash

# Runtime ref-to-cluster resolver: reads SPARK_K8S_CONFIG, picks the cluster that
# owns the current ref and prints `export` lines on stdout, diagnostics on stderr.

# Supported cluster configuration schema version.
RESOLVER_SUPPORTED_SCHEMA_VERSION=1

# Set by resolver_config_file to the configuration file to read.
RESOLVER_CONFIG_FILE=""

# Set by resolver_config_file when the configuration was materialized into a
# temporary file, so the caller can remove it.
RESOLVER_TMP_CONFIG_FILE=""

# Set by resolve_cluster to the index of the selected cluster.
RESOLVER_SELECTED=""

_resolver_log() {
  printf '%s\n' "${*}" >&2
}

# Print refs/tags/<tag> or refs/heads/<branch>, nothing on merge request pipelines.
# CI_COMMIT_REF_NAME is never read: a tag named main must not match a branch rule.
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

# Translate a glob into an anchored POSIX ERE: `*` does not cross a slash, `**` does,
# `?` is one non-slash character, `\` escapes. Bracket expressions stay literal.
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

# Translate the inner part of a /regex/ into POSIX ERE, expanding \d \D \w \W \s \S
# and rejecting any other shorthand or `(?` group. The result is not anchored.
resolver_regex_to_ere() {
  local pattern="${1}"
  local length=${#pattern}
  local index=0
  local out=""
  local char next
  # Start index of the open bracket expression, or -1: a shorthand inside `[...]`
  # would become `[[0-9]]`, which never matches.
  local bracket_start=-1

  while [ "${index}" -lt "${length}" ]; do
    char="${pattern:index:1}"
    case "${char}" in
    "\\")
      index=$((index + 1))
      next="${pattern:index:1}"
      case "${next}" in
      d | D | w | W | s | S)
        if [ "${bracket_start}" -ge 0 ]; then
          _resolver_log "Unsupported escape sequence '\\${next}' inside a bracket expression in regex pattern '/${pattern}/'."
          return 1
        fi
        ;;
      esac
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
      if [ "${bracket_start}" -lt 0 ] && [ "${pattern:index+1:1}" = "?" ]; then
        _resolver_log "Unsupported group '(?' in regex pattern '/${pattern}/'."
        return 1
      fi
      out="${out}("
      ;;
    '[')
      if [ "${bracket_start}" -lt 0 ]; then
        bracket_start=${index}
      fi
      out="${out}["
      ;;
    ']')
      # A `]` right after `[` or `[^` is a literal member, not the closing
      # bracket, so only a later `]` ends the expression.
      if [ "${bracket_start}" -ge 0 ]; then
        if [ "${index}" -ne "$((bracket_start + 1))" ] &&
          ! { [ "${index}" -eq "$((bracket_start + 2))" ] && [ "${pattern:bracket_start+1:1}" = "^" ]; }; then
          bracket_start=-1
        fi
      fi
      out="${out}]"
      ;;
    *)
      out="${out}${char}"
      ;;
    esac
    index=$((index + 1))
  done

  printf '%s' "${out}"
}

# Return 0 when the pattern uses the /regex/ form.
_resolver_is_regex_pattern() {
  [ "${#1}" -ge 2 ] && [ "${1:0:1}" = "/" ] && [ "${1: -1}" = "/" ]
}

# Translate every regex pattern up front, so an unsupported pattern fails on every
# ref instead of only on the refs that reach that entry.
resolver_check_patterns() {
  local file="${1}"
  local count index pattern

  count="$(resolver_cluster_count "${file}")"
  if [ -z "${count}" ]; then
    _resolver_log "Cannot count the clusters in the configuration."
    return 1
  fi

  index=0
  while [ "${index}" -lt "${count}" ]; do
    while IFS= read -r pattern; do
      if _resolver_is_regex_pattern "${pattern}"; then
        resolver_regex_to_ere "${pattern:1:${#pattern}-2}" >/dev/null || return 1
      fi
    done < <(resolver_cluster_refs "${file}" "${index}")
    index=$((index + 1))
  done

  return 0
}

# Return 0 when the pattern owns the ref, 1 when not, 2 when the pattern is invalid.
# A glob matches the normalized ref; a /regex/ only if it mentions refs/, else the short name.
resolver_pattern_matches() {
  local pattern="${1}"
  local ref="${2}"
  local kind="${3}"
  local ere target

  if [ -z "${pattern}" ]; then
    return 1
  fi

  if _resolver_is_regex_pattern "${pattern}"; then
    if ! ere="$(resolver_regex_to_ere "${pattern:1:${#pattern}-2}")"; then
      return 2
    fi
    # refs/ counts only at the start or after a non-word character, so /^prefs\/x$/
    # still matches the branch prefs/x.
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

# Set RESOLVER_CONFIG_FILE to a readable .yaml path: jv picks its parser from the extension
# and a File variable path has none. A global, since a subshell would lose RESOLVER_TMP_CONFIG_DIR.
resolver_config_file() {
  local value="${1}"
  local tmp

  RESOLVER_CONFIG_FILE=""

  if [ -f "${value}" ] && [ -r "${value}" ]; then
    RESOLVER_CONFIG_FILE="${value}"
    return 0
  fi

  if ! tmp="$(mktemp -t spark_k8s_config.XXXXXX)"; then
    _resolver_log "Cannot create a temporary file for the inline cluster configuration."
    return 1
  fi
  # Consumed by the caller, which removes the file on exit.
  # shellcheck disable=SC2034
  RESOLVER_TMP_CONFIG_FILE="${tmp}"

  if ! chmod 600 "${tmp}" || ! printf '%s\n' "${value}" >"${tmp}"; then
    _resolver_log "Cannot write the inline cluster configuration to ${tmp}."
    return 1
  fi

  RESOLVER_CONFIG_FILE="${tmp}"
}

# Validate the file: parseable YAML, supported version, non-empty clusters list,
# at most one default, every refs a list, every regex translatable.
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

  # Empty means yq4 failed; without this guard `[ "" -gt 1 ]` errors and reads as false.
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

  resolver_check_patterns "${file}" || return 1

  return 0
}

# Print the number of declared clusters.
resolver_cluster_count() {
  yq4 e '.clusters | length' "${1}"
}

# Print a scalar field, empty when absent. `//` is avoided on purpose: it also
# replaces `false`, which would turn `use_dns_endpoint: false` into the default.
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

# Warn when GitLab Agent variables coexist with the resolver; the resolver wins.
# To make this fatal after the migration, replace the final `return 0` with `return 1`.
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

# Print the export lines for the cluster at the given index. The DNS endpoint is
# exported but never logged.
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
    # "1", yes or on arrive as strings; guessing would mask the typo, so it is an error.
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

# Resolve the cluster owning the current ref and print its export lines.
# Returns 0 on selection, 3 when the pipeline has no ref, 1 on a configuration error.
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

  if ! resolver_check_config "${file}"; then
    return 1
  fi

  ref="$(resolver_normalized_ref)"
  kind="$(resolver_ref_kind)"

  # No ref (merge request pipeline): nothing to resolve, and the default cluster
  # must not be used for a merge request.
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
