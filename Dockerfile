FROM google/cloud-sdk:162.0.1-alpine

RUN apk update && \
    apk add curl make gettext bash

ENV COMPOSE_VERSION 1.14.0
ENV DOCKER_BUCKET get.docker.com
ENV DOCKER_VERSION 1.13.1
ENV DOCKER_SHA256 97892375e756fd29a304bd8cd9ffb256c2e7c8fd759e12a55a6336e15100ad75

RUN set -x \
  && gcloud components install kubectl --quiet \
  && curl -fSL "https://${DOCKER_BUCKET}/builds/Linux/x86_64/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
  && echo "${DOCKER_SHA256} *docker.tgz" | sha256sum -c - \
  && tar -xzvf docker.tgz \
  && mv docker/* /usr/local/bin/ \
  && rmdir docker \
  && rm docker.tgz \
  && docker -v \
  && apk update \
  && apk add py-pip \
  && pip install "docker-compose==${COMPOSE_VERSION}"

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ADD scripts /scripts
RUN chmod -R +rwx scripts
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh"]
