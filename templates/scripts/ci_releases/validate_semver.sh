#!/usr/bin/env bash

# This script receives as first argument a string, <some_ver>, that is
# validated to be a semver compatible version.
# It also validates that <some_ver> is greater than the latest tag found in the repo.

set -o errtrace
set -o errexit
set -o pipefail

RELDIR_OF_SCRIPT=$( dirname "${BASH_SOURCE[0]}" )

# https://gist.github.com/rponte/fdc0724dd984088606b0
LATEST_TAG_IN_REPO="$(git describe --tags "$(git rev-list --tags --max-count=1)")"
echo LATEST_TAG_IN_REPO="$LATEST_TAG_IN_REPO"

curl -Ls -o "$RELDIR_OF_SCRIPT/semver" https://github.com/fsaintjacques/semver-tool/raw/master/src/semver && chmod +x "$RELDIR_OF_SCRIPT/semver"

# Check if one of the strings is not in a semver compatible format.
if ! COMPARISON=$("$RELDIR_OF_SCRIPT/semver" compare "$1" "$LATEST_TAG_IN_REPO" 2>&1); then
  echo "$COMPARISON"
  exit 1
fi

if [[ $COMPARISON -le 0 ]]; then
  echo not ok, "$1" is less than or equal than "$LATEST_TAG_IN_REPO"
  exit 1
else
  echo ok, "$1" is greater than "$LATEST_TAG_IN_REPO"
fi
