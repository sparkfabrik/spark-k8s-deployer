#!/usr/bin/env bash

# This script is meant to be executed from a gitlab ci job.
# It configures the gitlab repository checked out during ci to have a remote
# called "ciremote" that uses a gitlab rw access token to be able to push to it.
#
# Use something like this to commit and push
# git commit -m "[skip ci] some message"
# git push ciremote --push-option=ci.skip "HEAD:$CI_COMMIT_BRANCH"

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

git config user.email "${GITLAB_USER_EMAIL:-spark_ci_script@sparkfabrik.com}"
git config user.name "${GITLAB_USER_NAME:-Spark CI script}"
NEWREMOTEURL=$(echo "$CI_REPOSITORY_URL" | sed -e "s|.*@\(.*\)|$CI_SERVER_PROTOCOL://$GITLAB_PROJECT_RW_AND_API_TOKEN@\1|")
git remote add ciremote "$NEWREMOTEURL"
