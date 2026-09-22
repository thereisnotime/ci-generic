FROM ubuntu:24.04

# A batteries-included GitHub Actions runner for ARC without containerMode.
#
# There is no Docker CLI and no container hooks in here: this image is meant for
# a scale set running in plain mode, where there is no dind sidecar to talk to
# and no kubernetes-mode hooks to invoke. Installing them would be dead weight.
#
# Unlike a minimal runner image, the common toolchains ARE baked in. The trade is
# deliberate: the image is large (~2.5GB) and every node pays that once, but jobs
# do not spend 30-60s per run re-downloading a Go or Node toolchain into an
# empty toolcache. Containerd caches the image per node, so the cost is per node
# per tag, not per job.

ENV DEBIAN_FRONTEND=noninteractive

ARG USER=runner
# The chart and the runner tarball both expect uid 1001.
ARG USER_UID=1001

# GitHub stops queuing jobs to a runner roughly 30 days after a newer release
# ships, and ARC registers with DisableUpdate=true, so this never self-updates.
# The renovate annotations are what keep the image inside that window.
# renovate: datasource=github-releases depName=actions/runner
ARG RUNNER_VERSION=2.337.0
# renovate: datasource=github-releases depName=golang/go extractVersion=^go(?<version>.*)$
ARG GO_VERSION=1.27.1
# renovate: datasource=node-version depName=node
ARG NODE_VERSION=24.21.0
# renovate: datasource=github-releases depName=hashicorp/terraform extractVersion=^v(?<version>.*)$
ARG TERRAFORM_VERSION=1.16.3
# renovate: datasource=github-releases depName=opentofu/opentofu extractVersion=^v(?<version>.*)$
ARG OPENTOFU_VERSION=1.12.6
# renovate: datasource=github-releases depName=openbao/openbao extractVersion=^v(?<version>.*)$
ARG OPENBAO_VERSION=2.6.2
# renovate: datasource=github-releases depName=asdf-vm/asdf extractVersion=^v(?<version>.*)$
ARG ASDF_VERSION=0.20.2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# libicu74 is required by the runner's .NET host. The alternative,
# DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1, breaks culture-aware actions.
# tzdata is OS data rather than tooling: ubuntu's rootfs ships no
# /usr/share/zoneinfo, so anything resolving a named zone dies - python's
# ZoneInfo("Europe/Sofia") raises ZoneInfoNotFoundError.
# openssh-client is not optional either: without it git's SSH transport does not
# exist, so `git clone git@github.com:` fails outright, and actions that shell
# out to ssh-agent fail earlier still with `spawnSync ssh-agent ENOENT`.
# sudo is NOPASSWD below so a workflow can install its own extras without
# waiting for a new image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      libicu74 \
      openssh-client \
      pkg-config \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      rsync \
      sudo \
      tzdata \
      unzip \
      wget \
      zip \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL server, not just the client. Jobs that used a `services:` container
# start a local cluster instead:
#   sudo pg_ctlcluster 16 main start
# The runner user gets NOPASSWD sudo below, and is added to the postgres group.
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql \
      postgresql-client \
      postgresql-contrib \
    && rm -rf /var/lib/apt/lists/*

# Go, Node, Terraform, OpenTofu and OpenBao come from upstream rather than apt:
# the distro packages lag by a major version or more, which is the whole reason
# workflows reach for setup-go/setup-node in the first place.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) goarch=amd64; nodearch=x64;; arm64) goarch=arm64; nodearch=arm64;; *) echo "unsupported arch $arch" >&2; exit 1;; esac; \
    curl -fsSL --retry 5 --retry-all-errors \
      "https://go.dev/dl/go${GO_VERSION}.linux-${goarch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    curl -fsSL --retry 5 --retry-all-errors \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${nodearch}.tar.xz" -o /tmp/node.txz; \
    tar -C /usr/local --strip-components=1 -xJf /tmp/node.txz; \
    rm /tmp/node.txz; \
    for t in "terraform:https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" \
             "tofu:https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${arch}.zip"; do \
      name="${t%%:*}"; url="${t#*:}"; \
      curl -fsSL --retry 5 --retry-all-errors "$url" -o /tmp/${name}.zip; \
      unzip -q -o /tmp/${name}.zip -d /tmp/${name}; \
      install -m 0755 /tmp/${name}/${name} /usr/local/bin/${name}; \
      rm -rf /tmp/${name}.zip /tmp/${name}; \
    done; \
    # OpenBao does not follow HashiCorp's naming: the asset is
    # openbao_<ver>_linux_<arch>.tar.gz and the binary inside is `bao`.
    curl -fsSL --retry 5 --retry-all-errors \
      "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/openbao_${OPENBAO_VERSION}_linux_${arch}.tar.gz" \
      -o /tmp/openbao.tgz; \
    tar -C /tmp -xzf /tmp/openbao.tgz bao; \
    install -m 0755 /tmp/bao /usr/local/bin/bao; \
    rm -f /tmp/openbao.tgz /tmp/bao; \
    # asdf 0.16+ is a single Go binary, not the old shell install - there is no
    # asdf.sh to source. Plugins and shims live under ASDF_DATA_DIR, set below.
    curl -fsSL --retry 5 --retry-all-errors \
      "https://github.com/asdf-vm/asdf/releases/download/v${ASDF_VERSION}/asdf-v${ASDF_VERSION}-linux-${arch}.tar.gz" \
      -o /tmp/asdf.tgz; \
    tar -C /tmp -xzf /tmp/asdf.tgz asdf; \
    install -m 0755 /tmp/asdf /usr/local/bin/asdf; \
    rm -f /tmp/asdf.tgz /tmp/asdf

# asdf shims come first on PATH: a repo with a .tool-versions should get the
# version it asks for, not the one baked into the image.
ENV ASDF_DATA_DIR=/home/${USER}/.asdf
ENV PATH=/home/${USER}/.asdf/shims:/usr/local/go/bin:/usr/local/bin:$PATH
ENV GOPATH=/home/${USER}/go
ENV GOTOOLCHAIN=local

# ubuntu:24.04 ships an `ubuntu` user on uid 1001; take the uid over.
RUN userdel -r "$(id -un ${USER_UID} 2>/dev/null || echo ubuntu)" 2>/dev/null || true; \
    useradd -m -s /bin/bash -u ${USER_UID} ${USER}; \
    usermod -aG sudo,postgres ${USER}; \
    echo "%sudo ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner; \
    chmod 0440 /etc/sudoers.d/runner; \
    echo "Defaults env_keep += \"DEBIAN_FRONTEND\"" >> /etc/sudoers.d/runner; \
    mkdir -p /home/${USER}/go /home/${USER}/.asdf/shims \
    && chown -R ${USER}:${USER} /home/${USER}/go /home/${USER}/.asdf

USER ${USER}
WORKDIR /home/${USER}

# The runner tarball is ~215MB - retry it, a mid-transfer reset otherwise fails
# the whole build.
RUN set -eux; \
    curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
      -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"; \
    tar xzf ./runner.tar.gz; \
    rm runner.tar.gz

# The chart overrides this with /home/runner/run.sh; set so the image is also
# usable standalone.
ENTRYPOINT ["/home/runner/run.sh"]
