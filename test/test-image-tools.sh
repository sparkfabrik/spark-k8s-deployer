#!/bin/sh
#
# Smoke test for the binaries installed in the deployer image.
#
# Each tool is run inside the image as an unprivileged user, so the test proves
# that the binary is installed, executable by any user, and reports the version
# pinned in the Dockerfile. Run it with:
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
    case "$output" in
    *"$expected"*)
        printf 'ok (%s)\n' "$expected"
        ;;
    *)
        printf 'FAIL (expected %s, got: %s)\n' "$expected" "$output"
        failures=$((failures + 1))
        ;;
    esac
}

assert_tool_version kubeconform "$(pinned_version KUBECONFORM_VERSION)" kubeconform -v

if [ "$failures" -ne 0 ]; then
    printf '%s tool check(s) failed in %s\n' "$failures" "$IMAGE" >&2
    exit 1
fi

printf 'all tool checks passed in %s\n' "$IMAGE"
