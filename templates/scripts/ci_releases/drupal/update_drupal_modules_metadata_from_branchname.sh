#!/usr/bin/env bash

# This script is meant to be executed from a gitlab ci job when the branch is
# named release/<semver>.
# It does the following:

# 1) <semver> is validated to be a valid semantic versioning string and that is
# greater than the latest tag in the repo.

# 2) It goes through all the info.yml files and updates the
# project/version/timestamp values using the $DRUPAL_PROJECT_NAME,
# $VERSION_FROM_BRANCH_NAME, and current timestamp, respectively.

# 3) It commits and push the resulting files skipping ci.

# An example of a configuration of a gitlab ci job is:
# validate_brach_name:
#   variables:
#     DRUPAL_PROJECT_NAME: some_drupal_project
#   stage: pre_release
#   rules:
#     - if: ($CI_PIPELINE_SOURCE == "merge_request_event") && ($CI_MERGE_REQUEST_SOURCE_BRANCH_NAME =~ /^release\/.*/) && ($CI_MERGE_REQUEST_TARGET_BRANCH_NAME == $CI_DEFAULT_BRANCH)
#   script:
#     - SCRIPT=update_drupal_modules_metadata_from_branchname.sh
#     - SCRIPT_DOWNLOAD_PATH=/tmp
#     - curl -Ls -o "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"
#       https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/drupal/$SCRIPT
#       && chmod +x "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"
#       && "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"

set -o errtrace
set -o errexit
set -o pipefail

SCRIPT_DOWNLOAD_PATH=/tmp
declare -a SCRIPTS=("validate_semver.sh" "setup_repo_for_writing.sh")
for SCRIPT in "${SCRIPTS[@]}"; do
  curl -Ls -o "$SCRIPT_DOWNLOAD_PATH/$SCRIPT" \
  https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/"$SCRIPT" \
  && chmod +x "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"
done
SCRIPT_DRUPAL="update_drupal_info_yml_metadata.sh"
curl -Ls -o "$SCRIPT_DOWNLOAD_PATH/$SCRIPT_DRUPAL" \
  https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/drupal/"$SCRIPT_DRUPAL" \
  && chmod +x "$SCRIPT_DOWNLOAD_PATH/$SCRIPT_DRUPAL"

# Extract version from the branch name, check that is a valid semver string,
# and that is greater (semver-wise) to the latest tag in the repo.
DESTINATION_BRANCH="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-$CI_COMMIT_REF_NAME}}"
echo DESTINATION_BRANCH="$DESTINATION_BRANCH"
VERSION_FROM_BRANCH_NAME=${DESTINATION_BRANCH##release/}
echo VERSION_FROM_BRANCH_NAME="$VERSION_FROM_BRANCH_NAME"

"$SCRIPT_DOWNLOAD_PATH"/validate_semver.sh "$VERSION_FROM_BRANCH_NAME"
# Requires GITLAB_PROJECT_RW_AND_API_TOKEN vars.
"$SCRIPT_DOWNLOAD_PATH"/setup_repo_for_writing.sh
"$SCRIPT_DOWNLOAD_PATH"/update_drupal_info_yml_metadata.sh "$DRUPAL_PROJECT_NAME" "$VERSION_FROM_BRANCH_NAME"

git add .
git commit -m "[ci automation] Updated info.yml versions to $VERSION_FROM_BRANCH_NAME"
# shellcheck disable=SC2086
git push ciremote ${GIT_PUSH_OPTIONS:---push-option=ci.skip} "HEAD:$DESTINATION_BRANCH"
