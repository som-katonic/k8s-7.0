# ============================================================================
# Katonic AI Platform v7.0 - Installer Image
# ============================================================================
# Contains: Ansible, Terraform, Helm, kubectl, cloud CLIs (AWS, Azure, GCP,
#           OCI, Alibaba), and the tenant-manager Helm chart.
# ============================================================================

FROM ubuntu:22.04

ARG PLATFORM_VERSION=7.0.0
ARG KUBECTL_VERSION=1.30.0
ARG HELM_VERSION=3.15.0
ARG TERRAFORM_VERSION=1.8.0
ARG ISTIO_VERSION=1.22.0

ENV DEBIAN_FRONTEND=noninteractive
ENV PLATFORM_VERSION=${PLATFORM_VERSION}

LABEL maintainer="Katonic AI <platform@katonic.ai>"
LABEL version="${PLATFORM_VERSION}"
LABEL description="Katonic AI Platform v7 Installer"

# ---- Base packages ----
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget unzip git jq python3 python3-pip \
    openssh-client gnupg2 apt-transport-https \
    ca-certificates software-properties-common \
    dnsutils uuid-runtime gettext-base \
    && rm -rf /var/lib/apt/lists/*

# ---- yq (YAML processor) ----
RUN curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# ---- Ansible ----
RUN pip3 install --no-cache-dir ansible==9.* kubernetes jmespath pyyaml

# ---- kubectl ----
RUN curl -sLO "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x kubectl && mv kubectl /usr/local/bin/

# ---- Helm ----
RUN curl -sL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" | tar xz \
    && mv linux-amd64/helm /usr/local/bin/ && rm -rf linux-amd64

# ---- Terraform ----
RUN curl -sL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o tf.zip \
    && unzip tf.zip && mv terraform /usr/local/bin/ && rm tf.zip

# ---- AWS CLI ----
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscli.zip \
    && unzip -q awscli.zip && ./aws/install && rm -rf aws awscli.zip

# ---- Azure CLI ----
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# ---- GCP CLI ----
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && apt-get update && apt-get install -y google-cloud-cli && rm -rf /var/lib/apt/lists/*

# ---- OCI CLI ----
RUN pip3 install --no-cache-dir oci-cli

# ---- Alibaba Cloud CLI (aliyun) ----
RUN curl -sL "https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz" | tar xz \
    && mv aliyun /usr/local/bin/

# ---- pdftoppm (for validation scripts, optional) ----
# RUN apt-get update && apt-get install -y poppler-utils && rm -rf /var/lib/apt/lists/*

# ---- Project files ----
WORKDIR /root

# Copy installer
COPY ansible/ /root/ansible/
COPY terraform/ /root/terraform/
COPY charts/ /root/charts/
COPY scripts/ /root/scripts/
COPY data/ /root/data/
COPY entrypoint.sh /root/entrypoint.sh
COPY katonic.sh /root/katonic.sh

RUN chmod +x /root/entrypoint.sh /root/katonic.sh /root/scripts/*.sh

# Air-gap bundle (optional, only in air-gap builds)
# COPY airgap/ /root/airgap/

# Inventory is mounted at runtime
VOLUME ["/inventory"]

ENTRYPOINT ["/root/entrypoint.sh"]
