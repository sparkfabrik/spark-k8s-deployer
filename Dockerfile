# check=skip=SecretsUsedInArgOrEnv;error=true
# Build checks fail the build. SecretsUsedInArgOrEnv is skipped because it
# matches USE_GKE_GCLOUD_AUTH_PLUGIN by name; the image takes no secrets as
# ARG or ENV.

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
RUN git clone --depth 1 --branch "${MKCERT_VERSION}" https://github.com/FiloSottile/mkcert && cd mkcert \
    && go build -o /go/bin/mkcert -ldflags "-X main.Version=${MKCERT_VERSION}"

FROM eu.gcr.io/google.com/cloudsdktool/google-cloud-cli:${GOOGLE_CLOUD_CLI_IMAGE_TAG}

# Set by BuildKit to the architecture being built (amd64 or arm64). The binaries
# below are downloaded for it.
ARG TARGETARCH

# Every downloaded binary is verified against a sha256 per architecture. Bump
# each checksum pair together with its version.

# https://github.com/docker/compose/releases
ENV COMPOSE_VERSION=v2.38.2
# sha256 of docker-compose-linux-<x86_64|aarch64>, from the release checksums.txt.
ARG COMPOSE_SHA256_AMD64=486b3ffc0f806ca2efbc430cef89955386011662f0c76bad17c103d059cfa9cf
ARG COMPOSE_SHA256_ARM64=4d0f7678dd3338452beba4518e36a8e22b20cad79ba2535c687da554dc3997fb
# https://download.docker.com/linux/static/stable/
ENV DOCKER_VERSION=27.1.1
# sha256 of <x86_64|aarch64>/docker-${DOCKER_VERSION}.tgz. Docker publishes no
# checksum for the static binaries, so compute it from the downloaded file.
ARG DOCKER_SHA256_AMD64=118da6b8fc8e8b6c086ab0dd5e64ee549376c3a3f963723bbc9a46db475bf21f
ARG DOCKER_SHA256_ARM64=86a395f67a5a23d8eb207ab5a9ab32a51f7fccd8b18dae40887e738db95c6bc4
# https://github.com/docker/buildx/releases
ENV DOCKER_BUILDX_VERSION=0.25.0
# sha256 of buildx-v${DOCKER_BUILDX_VERSION}.linux-<amd64|arm64>, from the
# release checksums.txt.
ARG DOCKER_BUILDX_SHA256_AMD64=4104d79a791a8744c0b43fd5bd0a6172dff29040c5229946a1cdb2d27b0b5bfa
ARG DOCKER_BUILDX_SHA256_ARM64=f07063844bb750172c1f25cef61b07a8314d24bedffc015517b3ec4016b16de8
# https://github.com/helm/helm/releases
ENV HELM3_VERSION=3.18.4
# sha256 of helm-v${HELM3_VERSION}-linux-<amd64|arm64>.tar.gz, from its
# .sha256sum file on get.helm.sh.
ARG HELM3_SHA256_AMD64=f8180838c23d7c7d797b208861fecb591d9ce1690d8704ed1e4cb8e2add966c1
ARG HELM3_SHA256_ARM64=c0a45e67eef0c7416a8a8c9e9d5d2d30d70e4f4d3f7bea5de28241fffa8f3b89
ENV AWS_CLI_VERSION=1.32.14
# https://github.com/mikefarah/yq/releases
ENV YQ4_VERSION=v4.49.2
# sha256 of yq_linux_<amd64|arm64>, from the release checksums-bsd file.
ARG YQ4_SHA256_AMD64=be2c0ddcf426b6a231648610ec5d1666ae50e9f6473e82f6486f9f4cb6e3e2f7
ARG YQ4_SHA256_ARM64=783aa3c3beedcf2bf4aaf6262eca38b92a16d3ea31e2218ca80ba8ec7226b248
# https://github.com/fluxcd/flux2/releases
ENV FLUX2_RELEASE_VERSION=0.26.2
# sha256 of flux_${FLUX2_RELEASE_VERSION}_linux_<amd64|arm64>.tar.gz, from the
# release checksums file.
ARG FLUX2_SHA256_AMD64=e4a0fc274b724ed9c92b4de59b1acfd88eeee9de9c50df4f7efb4c8519566719
ARG FLUX2_SHA256_ARM64=b52624292e17ec9120e190c96072874890b348797d818dbd892328c816c9c679
# https://github.com/stern/stern/releases
ENV STERN_RELEASE_VERSION=1.33.1
# sha256 of stern_${STERN_RELEASE_VERSION}_linux_<amd64|arm64>.tar.gz, from the
# release checksums.txt.
ARG STERN_SHA256_AMD64=185be29c6a22bd07c0791ec697900943c0cc27292e5a5640a07a543886f1bfc9
ARG STERN_SHA256_ARM64=41ff85d85aeaf6f61b1cfb7aeccad64d7f66051b51f955f55b49ce20b5822374
# https://github.com/casey/just/releases
# A recent just is required: it rejects justfile forms that older versions
# accept, which is how a broken package justfile can ship green.
ENV JUST_VERSION=1.58.0
# sha256 of just-${JUST_VERSION}-<x86_64|aarch64>-unknown-linux-musl.tar.gz,
# from the release SHA256SUMS.
ARG JUST_SHA256_AMD64=4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d
ARG JUST_SHA256_ARM64=748237128c4c40cbdabc65e841d05ceba13cc23a91eaba395495894c1d9764df
# https://github.com/yannh/kubeconform/releases
ENV KUBECONFORM_VERSION=v0.8.0
# sha256 of kubeconform-linux-<amd64|arm64>.tar.gz, from the release CHECKSUMS
# file.
ARG KUBECONFORM_SHA256_AMD64=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
ARG KUBECONFORM_SHA256_ARM64=1f53fc8e81258197a35e8603054162a5af1de8c5af13746c71ab680d9534ed87

# Use the gke-auth-plugin to authenticate to the GKE cluster.
ENV USE_GKE_GCLOUD_AUTH_PLUGIN=true

# Release assets name the architecture either as amd64/arm64 (TARGETARCH) or as
# x86_64/aarch64 (UNAME_ARCH). ARCH_SUFFIX selects the checksums above.
RUN case "${TARGETARCH}" in \
      amd64) UNAME_ARCH=x86_64; ARCH_SUFFIX=AMD64 ;; \
      arm64) UNAME_ARCH=aarch64; ARCH_SUFFIX=ARM64 ;; \
      *) echo "Unsupported TARGETARCH '${TARGETARCH}', expected amd64 or arm64" >&2; exit 1 ;; \
    esac \
    && for tool in DOCKER COMPOSE DOCKER_BUILDX HELM3 YQ4 FLUX2 STERN JUST KUBECONFORM; do \
      eval "${tool}_SHA256=\"\${${tool}_SHA256_${ARCH_SUFFIX}}\""; \
    done \
    && apk add --no-cache py-pip python3-dev curl make mysql-client mariadb-connector-c gettext bash openssl libffi-dev openssl-dev gcc libc-dev jq yq rust cargo bat rsync yamllint util-linux \
    # Install docker and docker-compose.
    && curl -fSL "https://download.docker.com/linux/static/stable/${UNAME_ARCH}/docker-${DOCKER_VERSION}.tgz" -o docker.tgz \
    && echo "${DOCKER_SHA256}  docker.tgz" | sha256sum -c - \
    && tar -xzvf docker.tgz \
    && mv docker/* /usr/local/bin/ \
    && rmdir docker \
    && rm docker.tgz \
    && docker -v \
    && mkdir -p ~/.docker/cli-plugins \
    && curl -fSL https://github.com/docker/compose/releases/download/"${COMPOSE_VERSION}"/docker-compose-linux-${UNAME_ARCH} -o ~/.docker/cli-plugins/docker-compose \
    && echo "${COMPOSE_SHA256}  ${HOME}/.docker/cli-plugins/docker-compose" | sha256sum -c - \
    && chmod +x ~/.docker/cli-plugins/docker-compose \
    && ln -s ~/.docker/cli-plugins/docker-compose /usr/local/bin/docker-compose \
    && docker-compose --version \
    && curl -fSL "https://github.com/docker/buildx/releases/download/v${DOCKER_BUILDX_VERSION}/buildx-v${DOCKER_BUILDX_VERSION}.linux-${TARGETARCH}" -o ~/.docker/cli-plugins/docker-buildx \
    && echo "${DOCKER_BUILDX_SHA256}  ${HOME}/.docker/cli-plugins/docker-buildx" | sha256sum -c - \
    && chmod +x ~/.docker/cli-plugins/docker-buildx \
    && gcloud components install kubectl beta gke-gcloud-auth-plugin --quiet \
    && kubectl version --client \
    # Install Helm 3:
    && wget -q -O helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz https://get.helm.sh/helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz \
    && echo "${HELM3_SHA256}  helm-v${HELM3_VERSION}-linux-${TARGETARCH}.tar.gz" | sha256sum -c - \
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
    && echo "${YQ4_SHA256}  /usr/local/bin/yq4" | sha256sum -c - \
    && chmod +x /usr/local/bin/yq4 \
    # Install flux
    && wget -q -O flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz https://github.com/fluxcd/flux2/releases/download/v${FLUX2_RELEASE_VERSION}/flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && echo "${FLUX2_SHA256}  flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz" | sha256sum -c - \
    && tar -xvf flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && mv flux /usr/local/bin/flux \
    && chmod +x /usr/local/bin/flux \
    && rm flux_${FLUX2_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    # Install stern
    && wget -q -O stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz https://github.com/stern/stern/releases/download/v${STERN_RELEASE_VERSION}/stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz \
    && echo "${STERN_SHA256}  stern_${STERN_RELEASE_VERSION}_linux_${TARGETARCH}.tar.gz" | sha256sum -c - \
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
