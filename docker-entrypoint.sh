#!/bin/sh
set -e

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
  set -- docker "$@"
fi

# if our command is a valid Docker subcommand, let's invoke it through Docker instead
# (this allows for "docker run docker ps", etc)
if docker help "$1" >/dev/null 2>&1; then
  set -- docker "$@"
fi

# if we have "--link some-docker:docker" and not DOCKER_HOST, let's set DOCKER_HOST automatically
if [ -z "$DOCKER_HOST" -a "$DOCKER_PORT_2375_TCP" ]; then
  export DOCKER_HOST='tcp://docker:2375'
fi

if [ "${PREVENT_GCLOUD_DOCKER:-0}" != "1" ]; then
  # Alias docker to use gcloud version.
  alias docker="gcloud docker --"
fi

if [ "${PREVENT_DOCKER_LOGIN_TO_GCR:-0}" != "1" ]; then
  # Authenticate docker client.
  docker login -e 1234@5678.com -u oauth2accesstoken -p "$(gcloud auth print-access-token)" https://gcr.io
fi

# Run commands.
exec "$@"
