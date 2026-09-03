#!/bin/sh
#
# Smoke test for the binaries installed in the deployer image.
#
# Every tool listed at the bottom of this script is run inside the image as an
# unprivileged user, so the test proves that the binary is installed,
# executable by any user, and reports the version pinned in the Dockerfile.
# Run it with:
#
#   make test-image-tools
#   make test-image-tools IMAGE=ghcr.io/sparkfabrik/spark-k8s-deployer:latest
#
set -eu

IMAGE="${IMAGE:-sparkfabrik/spark-k8s-deployer:latest}"
DOCKERFILE="$(dirname "$0")/../Dockerfile"

failures=0

# Read a pinned ENV value from the Dockerfile so the expected version lives in
# exactly one place and a version bump keeps this test honest.
pinned_version() {
    value="$(sed -n "s/^ENV $1=\\(.*\\)\$/\\1/p" "$DOCKERFILE")"
    if [ -z "$value" ]; then
        echo "cannot read $1 from $DOCKERFILE" >&2
        exit 1
    fi
    printf '%s' "$value"
}

# The entrypoint logs in to Google Container Registry, which needs credentials
# this test does not have, so the tools are invoked directly.
assert_tool_version() {
    tool="$1"
    expected="$2"
    shift 2
    printf 'checking %s ... ' "$tool"
    if ! output="$(docker run --rm --user 65534:65534 --entrypoint "" "$IMAGE" "$@" 2>&1)"; then
        printf 'FAIL (exited non-zero)\n%s\n' "$output"
        failures=$((failures + 1))
        return
    fi
    # Match the whole word, not a substring: a plain substring test would accept
    # v0.8.01 or v0.8.0-rc1 for a pinned v0.8.0. Splitting on whitespace still
    # works for tools that print the version inside a longer line, such as
    # "just 1.58.0". Globbing is off so a token is never expanded as a pattern.
    set -f
    for token in $output; do
        if [ "$token" = "$expected" ]; then
            set +f
            printf 'ok (%s)\n' "$expected"
            return
        fi
    done
    set +f
    printf 'FAIL (expected %s, got: %s)\n' "$expected" "$output"
    failures=$((failures + 1))
}

# Read the pins first: pinned_version exits from a command substitution, whose
# subshell status is lost when it is expanded inline as an argument. Assigning
# it here lets set -e stop the script when a pin cannot be read.
kubeconform_expected="$(pinned_version KUBECONFORM_VERSION)"

assert_tool_version kubeconform "$kubeconform_expected" kubeconform -v

if [ "$failures" -ne 0 ]; then
    printf '%s tool check(s) failed in %s\n' "$failures" "$IMAGE" >&2
    exit 1
fi

printf 'all tool checks passed in %s\n' "$IMAGE"
