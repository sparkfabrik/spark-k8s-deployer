#!/usr/bin/env bash

set -o errtrace
set -o errexit
set -o pipefail

function update_drupal_info_yml_metadata() {
  local timestamp
  timestamp="${3:-$(date +%s)}"
  for infofile in $(git ls-files | grep '\.info\.yml$'); do
    echo Changing metadata in "$infofile"
    if grep -q '^project: .*' "$infofile"; then
      sed -i "s/^project: .*/project: '$1'/" "$infofile"
    else
      printf "\nproject: \'%s\'" "$1" >> "$infofile"
    fi
    if grep -q '^version: .*' "$infofile"; then
      sed -i "s/^version: .*/version: '$2'/" "$infofile"
    else
      printf "\nversion: \'%s\'" "$2" >> "$infofile"
    fi
    if grep -q '^timestamp: .*' "$infofile"; then
      sed -i "s/^timestamp: .*/timestamp: '$timestamp'/" "$infofile"
    else
      printf "\ntimestamp: \'%s\'" "$timestamp" >> "$infofile"
    fi
  done
}

usage() {
  printf "%b" "
Description: this script goes through all your info.yml files and sets the version,project,timestamp entries.
Usage
  ./update_drupal_info_yml_metadata.sh <project_name> <version> [timestamp]
  If timestamp is not passed it will use the current timestamp.

Examples
  ./update_drupal_info_yml_metadata.sh firestarter_cms 21.42.33
  ./update_drupal_info_yml_metadata.sh firestarter_cms 21.42.33 1673542740
"
}

main() {
  ARGUMENTS=()
  while [[ $# -gt 0 ]]; do
    key="$1"
    shift

    case $key in
      -h|--help)
        usage
        exit 0
        ;;
      *)
        ARGUMENTS+=("$key")
        ;;
    esac
  done

  set -- "${ARGUMENTS[@]}" # restore args

  if [[ ${#ARGUMENTS[@]} -lt 2 ]]; then
    usage
    exit 0
  fi

  update_drupal_info_yml_metadata "${ARGUMENTS[@]}"
}

main "$@"
