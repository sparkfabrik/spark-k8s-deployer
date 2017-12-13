FROM google/cloud-sdk:181.0.0-alpine

ENV COMPOSE_VERSION 1.17.1
ENV DOCKER_VERSION 17.03.2-ce

RUN apk add --no-cache curl make gettext bash py-pip && \
    curl -fSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && tar -xzvf docker.tgz \
    && mv docker/* /usr/local/bin/ \
    && rmdir docker \
    && rm docker.tgz \
    && docker -v \
    && pip install "docker-compose==${COMPOSE_VERSION}" \
    && gcloud components install kubectl --quiet

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ADD scripts /scripts
RUN chmod -R +rwx scripts
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh"]
