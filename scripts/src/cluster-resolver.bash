#!/usr/bin/env bash

# Runtime ref-to-cluster resolver: reads SPARK_K8S_CONFIG, picks the cluster that
# owns the current ref and prints `export` lines on stdout, diagnostics on stderr.

# Supported cluster configuration schema version.
RESOLVER_SUPPORTED_SCHEMA_VERSION=1

# Set by resolver_config_file to the configuration file to read.
RESOLVER_CONFIG_FILE=""

# Set by resolver_config_file when a temporary directory was created to hold
# the configuration, so the caller can remove it.
RESOLVER_TMP_CONFIG_DIR=""

# Set by resolve_cluster to the index of the selected entry.
RESOLVER_SELECTED=""

# Set by resolver_check_config to the shape of the document: "clusters" for the
# cluster shape with a default entry, "envs" for the environment shape resolved by
# specificity. A document carries exactly one of the two keys.
RESOLVER_SHAPE=""

# Set by resolver_check_config to the top level key holding the entries, so the
# accessors read both shapes.
RESOLVER_ENTRIES_KEY=""

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

  count="$(resolver_entry_count "${file}")"
  if [ -z "${count}" ]; then
    _resolver_log "Cannot count the entries in the configuration."
    return 1
  fi

  index=0
  while [ "${index}" -lt "${count}" ]; do
    while IFS= read -r pattern; do
      if _resolver_is_regex_pattern "${pattern}"; then
        resolver_regex_to_ere "${pattern:1:${#pattern}-2}" >/dev/null || return 1
      fi
    done < <(resolver_entry_refs "${file}" "${index}")
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

# Print the specificity rank of a pattern as "kind literals double_stars single_stars".
# The kind is 2 for a literal, 1 for a glob and 0 for a regex: a literal names one
# ref, a glob a family, a regex anything at all. Literal characters are counted as
# written, the refs/ prefix included, so refs/tags/v* counts 11 and v* counts 1; an
# escape and the character it escapes count as one.
resolver_pattern_rank() {
  local pattern="${1}"
  local length=${#pattern}
  local index=0
  local kind=2
  local literals=0
  local doubles=0
  local singles=0
  local char

  if _resolver_is_regex_pattern "${pattern}"; then
    printf '0 0 0 0'
    return 0
  fi

  while [ "${index}" -lt "${length}" ]; do
    char="${pattern:index:1}"
    case "${char}" in
    "\\")
      index=$((index + 1))
      literals=$((literals + 1))
      ;;
    '*')
      kind=1
      if [ "${pattern:index+1:1}" = "*" ]; then
        doubles=$((doubles + 1))
        index=$((index + 1))
      else
        singles=$((singles + 1))
      fi
      ;;
    '?')
      kind=1
      ;;
    *)
      literals=$((literals + 1))
      ;;
    esac
    index=$((index + 1))
  done

  printf '%s %s %s %s' "${kind}" "${literals}" "${doubles}" "${singles}"
}

# Print 1 when the first rank is more specific than the second, -1 when it is less,
# 0 when the two rank equal. The kind decides first; between globs more literal
# characters win, then fewer ** and then fewer *. Two literals and two regexes always
# rank equal, which is why a regex may live in one environment only.
resolver_rank_compare() {
  local -a left right
  local index

  read -r -a left <<<"${1}"
  read -r -a right <<<"${2}"

  if [ "${left[0]}" -ne "${right[0]}" ]; then
    if [ "${left[0]}" -gt "${right[0]}" ]; then
      printf '1'
    else
      printf '-1'
    fi
    return 0
  fi

  if [ "${left[0]}" != "1" ]; then
    printf '0'
    return 0
  fi

  if [ "${left[1]}" -ne "${right[1]}" ]; then
    if [ "${left[1]}" -gt "${right[1]}" ]; then
      printf '1'
    else
      printf '-1'
    fi
    return 0
  fi

  # Fewer wildcards win, so the comparison is inverted for the star counts.
  for index in 2 3; do
    if [ "${left[index]}" -ne "${right[index]}" ]; then
      if [ "${left[index]}" -lt "${right[index]}" ]; then
        printf '1'
      else
        printf '-1'
      fi
      return 0
    fi
  done

  printf '0'
}

# Set RESOLVER_CONFIG_FILE to a readable .yaml path: jv picks its parser from the extension
# and a File variable path has none. A global, since a subshell would lose RESOLVER_TMP_CONFIG_DIR.
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

  # Copy rather than link: a relative path would dangle from the temporary directory,
  # and a copy is a stable snapshot between validation and parsing.
  if [ -f "${value}" ] && [ -r "${value}" ]; then
    if ! (
      umask 077
      cat -- "${value}" >"${target}"
    ); then
      _resolver_log "Cannot copy the cluster configuration into ${dir}."
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

# Print the path of the shipped schema copy, empty when none is available. There is
# no override: a project could point it at a permissive schema.
resolver_schema_file() {
  local candidate

  for candidate in "/schemas/cluster-config.schema.json" \
    "${DEPLOY_ROOT_DIR:-}/../schemas/cluster-config.schema.json"; do
    if [ -f "${candidate}" ] && [ -r "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
}

# Validate against the generator schema and fail on violation. A missing jv or schema
# copy only warns: the structural checks still cover the dangerous cases.
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

# Print the shape of the document, "clusters" or "envs". The schema allows exactly
# one of the two keys; this repeats the rule for the job image that has no jv.
resolver_document_shape() {
  local file="${1}"
  local has_clusters has_envs

  has_clusters="$(yq4 e 'has("clusters")' "${file}" 2>/dev/null)"
  has_envs="$(yq4 e 'has("envs")' "${file}" 2>/dev/null)"

  if [ "${has_clusters}" = "true" ] && [ "${has_envs}" = "true" ]; then
    _resolver_log "The cluster configuration declares both a 'clusters' list and an 'envs' list, a document carries one shape only."
    return 1
  fi
  if [ "${has_clusters}" = "true" ]; then
    printf 'clusters'
    return 0
  fi
  if [ "${has_envs}" = "true" ]; then
    printf 'envs'
    return 0
  fi

  _resolver_log "The cluster configuration declares neither a 'clusters' list nor an 'envs' list."
  return 1
}

# Validate the file: parseable YAML, supported version, one known shape and the
# checks that shape needs, then every regex translatable.
resolver_check_config() {
  local file="${1}"
  local version

  if ! version="$(yq4 e '.version // 1' "${file}" 2>/dev/null)"; then
    _resolver_log "The cluster configuration is not valid YAML."
    return 1
  fi
  if [ "${version}" != "${RESOLVER_SUPPORTED_SCHEMA_VERSION}" ]; then
    _resolver_log "Unsupported cluster configuration version '${version}', this resolver supports version ${RESOLVER_SUPPORTED_SCHEMA_VERSION}."
    return 1
  fi

  RESOLVER_SHAPE="$(resolver_document_shape "${file}")" || return 1
  RESOLVER_ENTRIES_KEY="${RESOLVER_SHAPE}"

  case "${RESOLVER_SHAPE}" in
  clusters) resolver_check_clusters "${file}" || return 1 ;;
  envs) resolver_check_envs "${file}" || return 1 ;;
  esac

  resolver_check_patterns "${file}" || return 1

  return 0
}

# Validate the cluster shape: a non-empty list, at most one default, every refs a list.
resolver_check_clusters() {
  local file="${1}"
  local kind length default_count scalar_refs_count

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

  return 0
}

# Validate the environment shape: a non-empty list and a refs list on every entry.
# `refs` is required here, unlike the cluster shape: an entry without it would claim
# nothing and there is no default entry to fall back to, so the deploy would skip in
# silence.
resolver_check_envs() {
  local file="${1}"
  local kind length bad_refs_count

  kind="$(yq4 e '.envs | tag' "${file}" 2>/dev/null)"
  if [ "${kind}" != "!!seq" ]; then
    _resolver_log "The cluster configuration has no 'envs' list."
    return 1
  fi

  length="$(yq4 e '.envs | length' "${file}" 2>/dev/null)"
  if [ "${length}" = "0" ]; then
    _resolver_log "The cluster configuration declares an empty 'envs' list."
    return 1
  fi

  bad_refs_count="$(yq4 e '[.envs[] | select((has("refs") | not) or (.refs | tag) != "!!seq")] | length' "${file}" 2>/dev/null)"
  if [ -z "${bad_refs_count}" ]; then
    _resolver_log "Cannot check the refs lists in the configuration."
    return 1
  fi
  if [ "${bad_refs_count}" != "0" ]; then
    _resolver_log "The cluster configuration declares ${bad_refs_count} environments whose 'refs' is missing or not a list."
    return 1
  fi

  return 0
}

# Print the number of declared entries, clusters or environments.
resolver_entry_count() {
  yq4 e ".${RESOLVER_ENTRIES_KEY} | length" "${1}"
}

# Print a scalar field, empty when absent. `//` is avoided on purpose: it also
# replaces `false`, which would turn `use_dns_endpoint: false` into the default.
resolver_entry_field() {
  local value

  value="$(yq4 e ".${RESOLVER_ENTRIES_KEY}[${2}].${3}" "${1}")" || return 1
  if [ "${value}" = "null" ]; then
    printf ''
    return 0
  fi
  printf '%s' "${value}"
}

# Print the ref patterns of an entry, one per line. A git ref name cannot
# contain a newline, so the list round trips safely.
resolver_entry_refs() {
  yq4 e "(.${RESOLVER_ENTRIES_KEY}[${2}].refs // [])[]" "${1}"
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

# Print the export lines for the entry at the given index. The DNS endpoint is
# exported but never logged. KUBE_NAMESPACE is exported on the environment shape
# only: on the cluster shape the namespace stays a project variable.
resolver_emit_selected() {
  local file="${1}"
  local index="${2}"
  local name project_id location dns_endpoint use_dns_endpoint env namespace
  local use_dns_flag="0"
  local missing=""

  name="$(resolver_entry_field "${file}" "${index}" "name")"
  project_id="$(resolver_entry_field "${file}" "${index}" "project_id")"
  location="$(resolver_entry_field "${file}" "${index}" "location")"
  dns_endpoint="$(resolver_entry_field "${file}" "${index}" "dns_endpoint")"
  use_dns_endpoint="$(resolver_entry_field "${file}" "${index}" "use_dns_endpoint")"

  [ -n "${name}" ] || missing="${missing} name"
  [ -n "${project_id}" ] || missing="${missing} project_id"
  [ -n "${location}" ] || missing="${missing} location"

  if [ "${RESOLVER_SHAPE}" = "envs" ]; then
    env="$(resolver_entry_field "${file}" "${index}" "env")"
    namespace="$(resolver_entry_field "${file}" "${index}" "namespace")"
    [ -n "${env}" ] || missing="${missing} env"
    [ -n "${namespace}" ] || missing="${missing} namespace"
  fi

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

  if [ "${RESOLVER_SHAPE}" = "envs" ]; then
    _resolver_emit_export "KUBE_NAMESPACE" "${namespace}"
    # The environment name is not exported, so the template cannot print it: the
    # resolver logs the resolved environment itself.
    _resolver_log "Resolved environment: ${env} (namespace ${namespace}, cluster ${name}, project ${project_id}, location ${location})"
  fi
}

# Select the cluster owning the ref on the cluster shape, setting RESOLVER_SELECTED.
# The list is scanned bottom up, so the last declared match wins, and a ref that
# matches nothing falls back to the default entry. Returns 1 on a configuration error.
resolver_select_cluster() {
  local file="${1}"
  local ref="${2}"
  local kind="${3}"
  local count index pattern rc name

  count="$(resolver_entry_count "${file}")"
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
        name="$(resolver_entry_field "${file}" "${index}" "name")"
        _resolver_log "The ref '${ref}' matches the pattern '${pattern}' of cluster '${name}'."
        break
      fi
    done < <(resolver_entry_refs "${file}" "${index}")

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

  return 0
}

# Select the environment claiming the ref on the environment shape, setting
# RESOLVER_SELECTED. Every pattern of every environment is tried and the most
# specific match wins, so the order of the list never changes the outcome. Returns 3
# when nothing claims the ref, 1 on an invalid pattern or a tie of equal rank.
resolver_select_env() {
  local file="${1}"
  local ref="${2}"
  local kind="${3}"
  local count index pattern rc rank order env
  local best_rank="" best_env="" best_pattern=""
  local tie_env="" tie_pattern=""

  count="$(resolver_entry_count "${file}")"
  RESOLVER_SELECTED=""

  index=0
  while [ "${index}" -lt "${count}" ]; do
    env="$(resolver_entry_field "${file}" "${index}" "env")"
    while IFS= read -r pattern; do
      [ -n "${pattern}" ] || continue
      resolver_pattern_matches "${pattern}" "${ref}" "${kind}"
      rc=$?
      if [ "${rc}" = "2" ]; then
        return 1
      fi
      [ "${rc}" = "0" ] || continue

      rank="$(resolver_pattern_rank "${pattern}")"
      if [ -z "${best_rank}" ]; then
        best_rank="${rank}"
        best_env="${env}"
        best_pattern="${pattern}"
        RESOLVER_SELECTED="${index}"
        continue
      fi

      order="$(resolver_rank_compare "${rank}" "${best_rank}")"
      if [ "${order}" = "1" ]; then
        best_rank="${rank}"
        best_env="${env}"
        best_pattern="${pattern}"
        RESOLVER_SELECTED="${index}"
        # A more specific match settles what the previous tie could not.
        tie_env=""
        tie_pattern=""
      elif [ "${order}" = "0" ] && [ "${env}" != "${best_env}" ]; then
        # Two environments claiming the ref with the same force: the generator
        # rejects such a project, so this can only be a hand written document.
        tie_env="${env}"
        tie_pattern="${pattern}"
      fi
    done < <(resolver_entry_refs "${file}" "${index}")
    index=$((index + 1))
  done

  if [ -z "${RESOLVER_SELECTED}" ]; then
    _resolver_log "The ref '${ref}' is claimed by no environment, there is nothing to deploy."
    return 3
  fi

  if [ -n "${tie_env}" ]; then
    _resolver_log "The ref '${ref}' matches the pattern '${best_pattern}' of environment '${best_env}' and the pattern '${tie_pattern}' of environment '${tie_env}' at equal rank."
    return 1
  fi

  _resolver_log "The ref '${ref}' matches the pattern '${best_pattern}' of environment '${best_env}'."

  return 0
}

# Resolve the cluster owning the current ref and print its export lines.
# Returns 0 on selection, 3 when the pipeline has no ref, 1 on a configuration error.
resolve_cluster() {
  local file ref kind

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

  # Schema first, so the operator sees a JSON Pointer rather than the coarser message below.
  if ! resolver_validate_schema "${file}"; then
    return 1
  fi

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

  case "${RESOLVER_SHAPE}" in
  envs) resolver_select_env "${file}" "${ref}" "${kind}" || return $? ;;
  *) resolver_select_cluster "${file}" "${ref}" "${kind}" || return $? ;;
  esac

  resolver_warn_on_agent_variables || return 1
  resolver_emit_selected "${file}" "${RESOLVER_SELECTED}"
}
