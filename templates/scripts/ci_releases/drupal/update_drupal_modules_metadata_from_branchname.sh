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
#     - curl -Ls -o ./.gitlab/scripts/$SCRIPT
#       https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/drupal/$SCRIPT
#       && chmod +x ./.gitlab/scripts/$SCRIPT
#       && ./.gitlab/scripts/$SCRIPT

set -o errtrace
set -o errexit
set -o pipefail

declare -a SCRIPTS=("validate_semver.sh" "setup_repo_for_writing.sh")
for SCRIPT in "${SCRIPTS[@]}"; do
  curl -Ls -o ./.gitlab/scripts/"$SCRIPT" \
  https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/"$SCRIPT" \
  && chmod +x ./.gitlab/scripts/"$SCRIPT"
done
SCRIPT_DRUPAL="update_drupal_info_yml_metadata.sh"
curl -Ls -o ./.gitlab/scripts/"$SCRIPT_DRUPAL" \
  https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/drupal/"$SCRIPT_DRUPAL" \
  && chmod +x ./.gitlab/scripts/"$SCRIPT_DRUPAL"

# Extract version from the branch name, check that is a valid semver string,
# and that is greater (semver-wise) to the latest tag in the repo.
VERSION_FROM_BRANCH_NAME=${CI_COMMIT_REF_NAME##release/}
echo VERSION_FROM_BRANCH_NAME="$VERSION_FROM_BRANCH_NAME"
./.gitlab/scripts/validate_semver.sh "$VERSION_FROM_BRANCH_NAME"

# Requires GITLAB_PROJECT_RW_AND_API_TOKEN vars.
./.gitlab/scripts/setup_repo_for_writing.sh

./.gitlab/scripts/update_drupal_info_yml_metadata.sh "$DRUPAL_PROJECT_NAME" "$VERSION_FROM_BRANCH_NAME"

DESTINATION_BRANCH="${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-${CI_COMMIT_BRANCH:-$CI_COMMIT_REF_NAME}}"
git add .
git commit -m "[skip ci] [ci automation] Updated info.yml versions to $VERSION_FROM_BRANCH_NAME"
git push ciremote --push-option=ci.skip "HEAD:$DESTINATION_BRANCH"
