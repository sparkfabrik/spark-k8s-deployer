FROM google/cloud-sdk:181.0.0-alpine

RUN apk add --no-cache curl make gettext bash docker py-pip

ENV COMPOSE_VERSION 1.17.1
ENV DOCKER_BUCKET get.docker.com
ENV DOCKER_VERSION 17.10.0-r0

RUN set -x \
  && gcloud components install kubectl --quiet \
  && docker=${DOCKER_VERSION} -v \
  && pip install "docker-compose==${COMPOSE_VERSION}"

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ADD scripts /scripts
RUN chmod -R +rwx scripts
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh"]
