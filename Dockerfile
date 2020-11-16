FROM google/cloud-sdk:313.0.1-alpine

LABEL org.opencontainers.image.source https://github.com/sparkfabrik/spark-k8s-deployer

ENV COMPOSE_VERSION 1.22.0
ENV DOCKER_VERSION 17.12.0-ce
ENV HELM_VERSION 2.14.3
ENV HELM3_VERSION 3.4.1
ENV AWS_CLI_VERSION 1.16.305

RUN apk add --no-cache curl make gettext bash py-pip openssl py-pip python-dev libffi-dev openssl-dev gcc libc-dev make jq && \
    curl -fSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && tar -xzvf docker.tgz \
    && mv docker/* /usr/local/bin/ \
    && rmdir docker \
    && rm docker.tgz \
    && docker -v \
    && pip install "docker-compose==${COMPOSE_VERSION}" \
    && gcloud components install kubectl --quiet \
    # Install Helm 2:
    && wget -O helm-v${HELM_VERSION}-linux-amd64.tar.gz https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    && tar -xzf helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    && cp linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    && rm -fr linux-amd64/ \
    && helm version -c \
    # Install Helm 3:
    && wget -O helm-v${HELM3_VERSION}-linux-amd64.tar.gz https://get.helm.sh/helm-v${HELM3_VERSION}-linux-amd64.tar.gz \
    && tar -xzf helm-v${HELM3_VERSION}-linux-amd64.tar.gz \
    && cp linux-amd64/helm /usr/local/bin/helm3 \
    && chmod +x /usr/local/bin/helm3 \
    && rm helm-v${HELM3_VERSION}-linux-amd64.tar.gz \
    && rm -fr linux-amd64/ \
    && helm3 version -c

RUN pip install awscli==${AWS_CLI_VERSION}

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ADD scripts /scripts
RUN chmod -R +rwx scripts
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh"]
