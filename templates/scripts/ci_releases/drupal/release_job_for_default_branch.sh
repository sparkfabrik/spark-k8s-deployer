#!/usr/bin/env bash

# This script is meant to be executed from a gitlab ci job when the branch is the default branch
# An example of a configuration of a gitlab ci job is:
#
# release_tag:
#   stage: deploy
#   rules:
#     - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
#   script:
#     - SCRIPT=release_job_for_default_branch.sh
#     - SCRIPT_DOWNLOAD_PATH=/tmp
#     - curl -Ls -o "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"
#       https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/drupal/$SCRIPT
#       && chmod +x "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"
#     # do something only if script does not output "doing nothing"
#     # https://unix.stackexchange.com/questions/424652/capture-all-the-output-of-a-script-to-a-file-from-the-script-itself
#     - "exec 5>&1"
#     - "SCRIPT_OUTPUT=$($SCRIPT_DOWNLOAD_PATH/$SCRIPT| tee >(cat - >&5))"
#     - |
#       if [[ ! $SCRIPT_OUTPUT =~ 'doing nothing' ]]; then
#         echo now do something
#       fi
#
# It does the following:
# - It checks if the current commit of $CI_DEFAULT_BRANCH (master) is a merge commit.
# Explanation:
#   A normal commit usually has one parent but a merge commit tipically has two,
#   one from master and one from an incoming branch.
#   To check if it's a merge commit, it uses the gitlab API to get the parent
#   commits of the current commit and from the obtained list it excludes the
#   penultimate commit of master.
#   If another commit is present in the list it's a merge commit, otherwise it is not.
#
# - If it's not a merge commit it bails out.
#
# - Gets the original branch name of the MR that created the merge commit, if
#   it's in the form of release/xxx creates a xxx tag and pushes it.
# Explanation:
#   It does so by using the Gitlab API to ask for the MR associated to the
#   remaning commit in the list. The information is stored in the
#   "source_branch" field of the json response.

set -o errtrace
set -o errexit
set -o pipefail

if [[ ( -z $GITLAB_PROJECT_RW_AND_API_TOKEN ) ]]; then
  echo 'Please do the following:'
  echo '  -' go to the project\'s \"Settings -\> Access tokens\" section and define an access token with \"write_repository\"+\"read_api\" grants.
  echo '  -' go to the project\'s \"Settings -\> CI/CD -\> Variables\" section and define
  echo '   ' a variable with name GITLAB_PROJECT_RW_AND_API_TOKEN and value name_of_your_token:value_of_your_token.
  exit 1
fi
GITLAB_PROJECT_RW_AND_API_TOKEN_VALUE=${GITLAB_PROJECT_RW_AND_API_TOKEN##*:}

# https://forum.gitlab.com/t/run-job-in-ci-pipeline-only-on-merge-branch-into-the-master-and-get-merged-branch-name/24195
MR_BRANCH_LAST_COMMIT_SHA=$(
  curl -s \
    --header "PRIVATE-TOKEN: $GITLAB_PROJECT_RW_AND_API_TOKEN_VALUE" \
    "$CI_API_V4_URL/projects/$CI_PROJECT_ID/repository/commits/$CI_COMMIT_SHA" |\
    jq -r '.parent_ids | del(.[] | select(. == "'"$CI_COMMIT_BEFORE_SHA"'")) | .[-1]'
)

if [[ ( -z $MR_BRANCH_LAST_COMMIT_SHA ) || ( $MR_BRANCH_LAST_COMMIT_SHA == null ) ]]; then
  echo "commit $CI_COMMIT_SHA on $CI_DEFAULT_BRANCH is not on a merge commit, doing nothing"
  exit 0
fi

echo MR_BRANCH_LAST_COMMIT_SHA "$MR_BRANCH_LAST_COMMIT_SHA"

MR_BRANCH_NAME=$(
  curl -s \
    --header "PRIVATE-TOKEN: $GITLAB_PROJECT_RW_AND_API_TOKEN_VALUE" \
    "$CI_API_V4_URL/projects/$CI_PROJECT_ID/repository/commits/$MR_BRANCH_LAST_COMMIT_SHA/merge_requests" |\
    jq -r '.[0].source_branch'
)
echo MR_BRANCH_NAME "$MR_BRANCH_NAME"

if [[ $MR_BRANCH_NAME =~ ^release/.+ ]]; then
  SCRIPT_DOWNLOAD_PATH=/tmp
  # Requires GITLAB_PROJECT_RW_AND_API_TOKEN vars.
  declare -a SCRIPTS=("setup_repo_for_writing.sh")
  for SCRIPT in "${SCRIPTS[@]}"; do
    curl -Ls -o "$SCRIPT_DOWNLOAD_PATH/$SCRIPT" \
    https://github.com/sparkfabrik/spark-k8s-deployer/raw/master/templates/scripts/ci_releases/"$SCRIPT" \
    && chmod +x "$SCRIPT_DOWNLOAD_PATH/$SCRIPT" \
    && "$SCRIPT_DOWNLOAD_PATH/$SCRIPT"
  done

  TAG_NAME=${MR_BRANCH_NAME##release/}
  echo Pushing tag "$TAG_NAME" to origin
  git tag "$TAG_NAME"
  # shellcheck disable=SC2086
  git push ciremote ${GIT_PUSH_OPTIONS:---push-option=ci.skip} "$TAG_NAME"
else
  echo "$MR_BRANCH_NAME is not a release branch, doing nothing"
  exit 0
fi
