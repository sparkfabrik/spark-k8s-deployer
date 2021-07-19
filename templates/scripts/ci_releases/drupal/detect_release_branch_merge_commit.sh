#!/usr/bin/env bash

# This script is meant to be executed from a gitlab ci job when the branch is the default branch
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
#
# its return code is
# 0: if the current commit of $CI_DEFAULT_BRANCH is not a merge commit
#    or if it's a merge commit coming from a branch name not named release/xxx
# 1: any fatal error, like missimg api token, curl execution fail.
# 9: if the current commit of $CI_DEFAULT_BRANCH is a merge commit coming from
#    a branch name named release/xxx. Branch name is outputted in stdout.

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

RC_FOR_DETECTED_RELEASE_BRANCH=9
if [[ $MR_BRANCH_NAME =~ ^release/.+ ]]; then
  echo "$MR_BRANCH_NAME"
  exit $RC_FOR_DETECTED_RELEASE_BRANCH
else
  echo "$MR_BRANCH_NAME is not a release branch, doing nothing"
  exit 0
fi
