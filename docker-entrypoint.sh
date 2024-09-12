#!/bin/sh
set -e

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
  set -- docker "$@"
fi

# if our command is a valid Docker subcommand, let's invoke it through Docker instead
# (this allows for "docker run docker ps", etc)
if docker help "$1" > /dev/null 2>&1; then
  set -- docker "$@"
fi

echo "testing pr-agent"

# if we have "--link some-docker:docker" and not DOCKER_HOST, let's set DOCKER_HOST automatically
if [ -z "$DOCKER_HOST" -a "$DOCKER_PORT_2375_TCP" ]; then
  export DOCKER_HOST='tcp://docker:2375'
fi

# Alias docker to use gcloud version.
alias docker="gcloud docker --"

# Authenticate docker client.
docker login -e 1234@5678.com -u oauth2accesstoken -p "$(gcloud auth print-access-token)" https://gcr.io

# Run commands.
exec "$@"
