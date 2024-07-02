#!/usr/bin/env bash
set -eo pipefail

[[ "$TRACE" ]] && set -x

export CI_CONTAINER_NAME="ci_job_build_$CI_BUILD_ID"
export CI_REGISTRY_TAG="$CI_BUILD_REF_NAME"
NON_DEVELOP_BRANCHES_REGEX=${NON_DEVELOP_BRANCHES_REGEX:-"master|main|stage"}
export NON_DEVELOP_BRANCHES_REGEX
