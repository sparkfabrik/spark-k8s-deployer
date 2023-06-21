#!/usr/bin/env bash

# The LINT_CI_TOKEN must be a token with 'developer' role and 'api' and 'read_api' scopes.
# Remember that the token expires every 1 year.

cd "$(dirname "${CI_TO_TEST}")" || exit 1
# get a list of gitlab-ci files locally included.
YAML_LOCAL_FILES=$(grep -F -e'- local: ' "$CI_TO_TEST" | cut -d: -f 2 | sed "s/'//g" | sed "s/ \///")
TMPFILE="$(mktemp)"
# Remove the lines that include local files.
sed -i '/- local: ..*/d' "${CI_TO_TEST}"
# concat the main gitlab file with the local ones to a tmp file.
cat "${CI_TO_TEST}" "${YAML_LOCAL_FILES}" >"${TMPFILE}"
LINT_OUTPUT=$(jq --null-input --arg yaml "$(<${TMPFILE})" '.content=$yaml' |
  curl "${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/ci/lint" \
    --silent \
    --header 'Content-Type: application/json' \
    --header "PRIVATE-TOKEN: ${LINT_CI_TOKEN}" \
    --data @-)
echo Linting output: "${LINT_OUTPUT}"
LINT_VAL=$(echo "$LINT_OUTPUT" | jq --raw-output '.status')
if [ "${LINT_VAL}" != "valid" ]; then
  exit 1
fi
