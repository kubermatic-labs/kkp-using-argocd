# this should be based on Ubuntu
# should install kubectl, helm, git, unzip, sed
# should mount the ci script and maybe aws credential file
ARG ARCH=amd64
ARG OS=linux
ARG BASE_IMAGE=${ARCH}/ubuntu:24.04
FROM ${BASE_IMAGE}

# Added args again since args before FROM are not available after FROM statement [Ref: https://docs.docker.com/engine/reference/builder/#understand-how-arg-and-from-interact]
ARG ARCH
ARG OS
USER 0

RUN apt-get update && apt-get install -y\
#    apt-transport-https \
#    ca-certificates \
    curl \
    git \
#    make \
#    sudo \
    unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# update these versions from: 
ENV HELM_VERSION="v3.17.2" \
    KUBECTL_VERSION="v1.32.4" \
    OPENTOFU_VERSION="1.9.0" \
    YQ_VERSION="4.45.1"

RUN \
    # Install Yq
    curl --fail -LO https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64 && \
    chmod +x yq_linux_amd64 && \
    mv yq_linux_amd64 /usr/local/bin/yq && \
    # tofu
    curl --fail -LO https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_amd64.zip && \
    unzip -o tofu_*.zip && \
    chmod +x tofu && \
    mv tofu /usr/local/bin && \
    rm -rf tofu_*.zip && \
    # helm
    curl --fail -L https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz | tar -xzO linux-amd64/helm > helm && \
    chmod +x helm && \
    mv helm /usr/local/bin && \
    # KUBECTL
    curl --fail -LO https://dl.k8s.io/$KUBECTL_VERSION/bin/linux/amd64/kubectl && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin

USER ubuntu