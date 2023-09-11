FROM eu.gcr.io/google.com/cloudsdktool/google-cloud-cli:445.0.0-alpine

LABEL org.opencontainers.image.source https://github.com/sparkfabrik/spark-k8s-deployer

# https://github.com/docker/compose/releases
ENV COMPOSE_VERSION v2.14.0
# https://download.docker.com/linux/static/stable/x86_64
ENV DOCKER_VERSION 20.10.7
ENV DOCKER_BUILDX_VERSION v0.5.1
ENV HELM3_VERSION 3.11.2
ENV AWS_CLI_VERSION 1.16.305
ENV YQ4_VERSION v4.14.2
ENV FLUX2_RELEASE_VERSION 0.26.2
ENV STERN_RELEASE_VERSION 1.24.0

# Use the gke-auth-plugin to authenticate to the GKE cluster.
ENV USE_GKE_GCLOUD_AUTH_PLUGIN true

# https://github.com/multiarch/qemu-user-static/releases
ENV QEMU_VERSION 5.2.0-2
ARG QEMU_ARCHS="aarch64 arm"

RUN apk add --no-cache py-pip python3-dev curl make gettext bash openssl libffi-dev openssl-dev gcc libc-dev jq yq rust cargo bat rsync yamllint && \
    # Install docker and docker-compose.
    curl -fSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && tar -xzvf docker.tgz \
    && mv docker/* /usr/local/bin/ \
    && rmdir docker \
    && rm docker.tgz \
    && docker -v \
    && mkdir -p ~/.docker/cli-plugins \
    && curl -SL https://github.com/docker/compose/releases/download/"${COMPOSE_VERSION}"/docker-compose-linux-x86_64 -o ~/.docker/cli-plugins/docker-compose \
    && chmod +x ~/.docker/cli-plugins/docker-compose \
    && ln -s ~/.docker/cli-plugins/docker-compose /usr/local/bin/docker-compose \
    && docker-compose --version \
    && curl -fSL "https://github.com/docker/buildx/releases/download/${DOCKER_BUILDX_VERSION}/buildx-${DOCKER_BUILDX_VERSION}.linux-amd64" -o ~/.docker/cli-plugins/docker-buildx \
    && chmod +x ~/.docker/cli-plugins/docker-buildx \
    && for ARCH in ${QEMU_ARCHS}; do curl https://github.com/multiarch/qemu-user-static/releases/download/v${QEMU_VERSION}/qemu-${ARCH}-static -o /usr/bin/qemu-${ARCH}-static; done \
    && gcloud components install kubectl beta gke-gcloud-auth-plugin --quiet \
    && kubectl version --client \
    # Install Helm 3:
    && wget -q -O helm-v${HELM3_VERSION}-linux-amd64.tar.gz https://get.helm.sh/helm-v${HELM3_VERSION}-linux-amd64.tar.gz \
    && tar -xzf helm-v${HELM3_VERSION}-linux-amd64.tar.gz \
    && cp linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm helm-v${HELM3_VERSION}-linux-amd64.tar.gz \
    && rm -fr linux-amd64/ \
    && helm version -c \
    # Add a symlink for helm3 command for legacy reasons.
    && ln -s /usr/local/bin/helm /usr/local/bin/helm3 \
    # Install YQ4
    && curl -fSL "https://github.com/mikefarah/yq/releases/download/${YQ4_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq4 \
    && chmod +x /usr/local/bin/yq4 \
    # Install flux
    && wget -q -O flux_${FLUX2_RELEASE_VERSION}_linux_amd64.tar.gz https://github.com/fluxcd/flux2/releases/download/v${FLUX2_RELEASE_VERSION}/flux_${FLUX2_RELEASE_VERSION}_linux_amd64.tar.gz \
    && tar -xvf flux_${FLUX2_RELEASE_VERSION}_linux_amd64.tar.gz \
    && mv flux /usr/local/bin/flux \
    && chmod +x /usr/local/bin/flux \
    && rm flux_${FLUX2_RELEASE_VERSION}_linux_amd64.tar.gz \
    # Install stern
    && wget -q -O stern_${STERN_RELEASE_VERSION}_linux_amd64.tar.gz https://github.com/stern/stern/releases/download/v${STERN_RELEASE_VERSION}/stern_${STERN_RELEASE_VERSION}_linux_amd64.tar.gz \
    && tar -xvf stern_${STERN_RELEASE_VERSION}_linux_amd64.tar.gz \
    && mv stern /usr/local/bin/stern \
    && chmod +x /usr/local/bin/stern \
    && rm -rf stern_${STERN_RELEASE_VERSION}_linux_amd64.tar.gz stern_${STERN_RELEASE_VERSION}_linux_amd64

RUN pip install --no-cache-dir awscli==${AWS_CLI_VERSION}

RUN echo "source /google-cloud-sdk/path.bash.inc" >> /etc/profile

COPY configs /configs

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
COPY scripts /scripts
RUN chmod -R +rwx scripts
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh"]
