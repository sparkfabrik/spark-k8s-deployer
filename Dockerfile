# Define the google cloud sdk image tag to use.
# https://console.cloud.google.com/artifacts/docker/google.com:cloudsdktool/europe/eu.gcr.io/google-cloud-cli
ARG GOOGLE_CLOUD_CLI_IMAGE_TAG=550.0.0-alpine

# Build go binaries
FROM golang:1.25-alpine AS gobinaries

# Install git to be able to fetch go modules
RUN apk --no-cache add git

# https://github.com/stackrox/kube-linter
ENV KUBELINTER_VERSION=0.7.6
RUN go install golang.stackrox.io/kube-linter/cmd/kube-linter@v${KUBELINTER_VERSION}

# https://github.com/santhosh-tekuri/jsonschema
# JSON Schema validator for the cluster resolver. Must support draft 2020-12
# (minContains/maxContains). Keep in sync with the cluster-resolver CI job.
ENV JV_VERSION=v0.7.0
RUN go install github.com/santhosh-tekuri/jsonschema/cmd/jv@${JV_VERSION}

# https://github.com/FiloSottile/mkcert
ENV MKCERT_VERSION=v1.4.4
RUN git clone https://github.com/FiloSottile/mkcert && cd mkcert \
    && go build -o /go/bin/mkcert -ldflags "-X main.Version=${MKCERT_VERSION}"

FROM eu.gcr.io/google.com/cloudsdktool/google-cloud-cli:${GOOGLE_CLOUD_CLI_IMAGE_TAG}

# Set by BuildKit to the architecture being built (amd64 or arm64). The binaries
# below are downloaded for it.
ARG TARGETARCH

# https://github.com/docker/compose/releases
ENV COMPOSE_VERSION=v2.38.2
# https://download.docker.com/linux/static/stable/
ENV DOCKER_VERSION=27.1.1
# https://github.com/docker/buildx/releases
ENV DOCKER_BUILDX_VERSION=0.25.0
# https://github.com/helm/helm/releases
ENV HELM3_VERSION=3.18.4
ENV AWS_CLI_VERSION=1.32.14
# https://github.com/mikefarah/yq/releases
ENV YQ4_VERSION=v4.49.2
ENV FLUX2_RELEASE_VERSION=0.26.2
# https://github.com/stern/stern/releases
ENV STERN_RELEASE_VERSION=1.33.1
# https://github.com/casey/just/releases
# A recent just is required: it rejects justfile forms that older versions
# accept, which is how a broken package justfile can ship green.
ENV JUST_VERSION=1.58.0
# sha256 of just-${JUST_VERSION}-<x86_64|aarch64>-unknown-linux-musl.tar.gz,
# from the release SHA256SUMS. Bump together with JUST_VERSION.
ENV JUST_SHA256_AMD64=4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d
ENV JUST_SHA256_ARM64=748237128c4c40cbdabc65e841d05ceba13cc23a91eaba395495894c1d9764df
# https://github.com/yannh/kubeconform/releases
ENV KUBECONFORM_VERSION=v0.8.0
# sha256 of kubeconform-linux-<amd64|arm64>.tar.gz, from the release CHECKSUMS
# file. Bump together with KUBECONFORM_VERSION.
ENV KUBECONFORM_SHA256_AMD64=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
ENV KUBECONFORM_SHA256_ARM64=1f53fc8e81258197a35e8603054162a5af1de8c5af13746c71ab680d9534ed87

# Use the gke-auth-plugin to authenticate to the GKE cluster.
ENV USE_GKE_GCLOUD_AUTH_PLUGIN=true

# Release assets name the architecture either as amd64/arm64 (TARGETARCH) or as
# x86_64/aarch64 (UNAME_ARCH).
RUN case "${TARGETARCH}" in \
      amd64) UNAME_ARCH=x86_64; JUST_SHA256="${JUST_SHA256_AMD64}"; KUBECONFORM_SHA256="${KUBECONFORM_SHA256_AMD64}" ;; \
      arm64) UNAME_ARCH=aarch64; JUST_SHA256="${JUST_SHA256_ARM64}"; KUBECONFORM_SHA256="${KUBECONFORM_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH '${TARGETARCH}', expected amd64 or arm64" >&2; exit 1 ;; \
    esac \
    && apk add --no-cache py-pip python3-dev curl make mysql-client mariadb-connector-c gettext bash openssl libffi-dev openssl-dev gcc libc-dev jq yq rust cargo bat rsync yamllint util-linux \
    # Install docker and docker-compose.
    && curl -fSL "https://download.docker.com/linux/static/stable/${UNAME_ARCH}/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && tar -xzvf docker.tgz \
    && mv docker/* /usr/local/bin/ \
    && rmdir docker \
    && rm docker.tgz \
    && docker -v \
    && mkdir -p ~/.docker/cli-plugins \
    && curl -SL https://github.com/docker/compose/releases/download/"${COMPOSE_VERSION}"/docker-compose-linux-${UNAME_ARCH} -o ~/.docker/cli-plugins/docker-compose \
    && chmod +x ~/.docker/cli-plugins/docker-compose \
    && ln -s ~/.docker/cli-plugins/docker-compose /usr/local/bin/docker-compose \
    && docker-compose --version \
    && curl -fSL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${TARGETARCH}" -o ~/.docker/cli-plugins/docker-buildx \
    && chmod +x ~/.docker/cli-plugins/docker-buildx \
    && gcloud components install kubectl beta gke-gcloud-auth-plugin --quiet \
    && kubectl version --client \
    # Install Helm 3:
    && wget -q -O helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz https://get.helm.sh/helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz \
    && tar -xzf helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz \
    && cp linux-${TARGETARCH}/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz \
    && rm -fr linux-${TARGETARCH}/ \
    && helm version -c \
    # Add a symlink for helm3 command for legacy reasons.
    && ln -s /usr/local/bin/helm /usr/local/bin/helm3 \
    # Install YQ4
    && curl -fSL "https://github.com/mikefarah/yq/releases/download/${YQ4_VERSION}/yq_linux_${TARGETARCH}" -o /usr/local/bin/yq4 \
    && chmod +x /usr/local/bin/yq4 \
    # Install flux
    && wget -q -O flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz https://github.com/fluxcd/flux2/releases/download/v${FLUX2_RELEASE_VERSION}/flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && tar -xvf flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && mv flux /usr/local/bin/flux \
    && chmod +x /usr/local/bin/flux \
    && rm flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    # Install stern
    && wget -q -O stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz https://github.com/stern/stern/releases/download/v${STERN_RELEASE_VERSION}/stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && tar -xvf stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && mv stern /usr/local/bin/stern \
    && chmod +x /usr/local/bin/stern \
    && rm -rf stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH} \
    # Install just (musl static binary, matching the alpine base)
    && curl -fSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-${UNAME_ARCH}-unknown-linux-musl.tar.gz" -o just.tar.gz \
    && echo "${JUST_SHA256}  just.tar.gz" | sha256sum -c - \
    && tar -xzf just.tar.gz just \
    && mv just /usr/local/bin/just \
    && chmod +x /usr/local/bin/just \
    && rm just.tar.gz \
    && just --version \
    # Install kubeconform
    && curl -fSL "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-${TARGETARCH}.tar.gz" -o kubeconform.tar.gz \
    && echo "${KUBECONFORM_SHA256}  kubeconform.tar.gz" | sha256sum -c - \
    && tar -xzf kubeconform.tar.gz kubeconform \
    && mv kubeconform /usr/local/bin/kubeconform \
    && chmod 755 /usr/local/bin/kubeconform \
    && rm kubeconform.tar.gz \
    && kubeconform -v

RUN pip install --no-cache-dir awscli==${AWS_CLI_VERSION} --break-system-packages

RUN echo "source /google-cloud-sdk/path.bash.inc" >> /etc/profile

# Install kube-linter copying the binary from the gobinaries stage
COPY --from=gobinaries /go/bin/kube-linter /usr/local/bin/kube-linter
RUN chmod +x /usr/local/bin/kube-linter

# Install mkcert copying the binary from the gobinaries stage
COPY --from=gobinaries /go/bin/mkcert /usr/local/bin/mkcert
RUN chmod +x /usr/local/bin/mkcert

# Install jv copying the binary from the gobinaries stage
COPY --from=gobinaries /go/bin/jv /usr/local/bin/jv
RUN chmod +x /usr/local/bin/jv

COPY configs /configs

# Cluster configuration schema, owned by the platform generator and synced here.
COPY schemas /schemas

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
COPY scripts /scripts
RUN chmod -R +rwx scripts
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["sh"]
