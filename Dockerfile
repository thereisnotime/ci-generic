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
ARG RUNNER_VERSION
ARG GO_VERSION
ARG NODE_VERSION
ARG TERRAFORM_VERSION
ARG OPENTOFU_VERSION
ARG OPENBAO_VERSION
ARG ASDF_VERSION

# CI gates. Versions match tix's Containerfile.ci so that `just lint` gives the
# same answer locally (in its pinned toolbox) and here.
ARG GOLANGCI_LINT_VERSION
ARG ACTIONLINT_VERSION
ARG GORELEASER_VERSION
ARG TRIVY_VERSION
ARG HADOLINT_VERSION
ARG YAMLLINT_VERSION
ARG GOSEC_VERSION
ARG GOVULNCHECK_VERSION
ARG MARKDOWNLINT_VERSION
ARG OPENSPEC_VERSION
ARG SHELLCHECK_VERSION
ARG PYFLAKES_VERSION

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The ARGs above have no defaults so that a stale value can never be baked in
# silently. Fail here with a clear message rather than 40 layers later on a
# download URL with an empty version in it.
RUN for v in RUNNER_VERSION GO_VERSION NODE_VERSION TERRAFORM_VERSION \
             OPENTOFU_VERSION OPENBAO_VERSION ASDF_VERSION; do \
      if [ -z "${!v:-}" ]; then \
        echo "build-arg $v is not set - use ./build.sh, which reads versions.env" >&2; \
        exit 1; \
      fi; \
    done

# libicu74 is required by the runner's .NET host. The alternative,
# DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1, breaks culture-aware actions.
# tzdata is OS data rather than tooling: ubuntu's rootfs ships no
# /usr/share/zoneinfo, so anything resolving a named zone dies - python's
# ZoneInfo("Europe/Sofia") raises ZoneInfoNotFoundError.
# openssh-client is not optional either: without it git's SSH transport does not
# exist, so `git clone git@github.com:` fails outright, and actions that shell
# out to ssh-agent fail earlier still with `spawnSync ssh-agent ENOENT`.
# gettext-base is for envsubst: cosign-installer and a number of release
# workflows shell out to it, and its absence surfaces as a bare `envsubst:
# command not found` deep inside an action rather than as a missing dependency.
# sudo is NOPASSWD below so a workflow can install its own extras without
# waiting for a new image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      gettext-base \
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
# npm's default prefix is /usr/local, which the non-root runner cannot write to,
# so a workflow doing `npm install -g` fails with EACCES. Point the prefix at
# the runner's home and put its bin first, so a repo installing its own pinned
# version shadows whatever is baked in.
ENV NPM_CONFIG_PREFIX=/home/${USER}/.npm-global
ENV PATH=/home/${USER}/.asdf/shims:/home/${USER}/.npm-global/bin:/home/${USER}/.local/bin:/usr/local/go/bin:/usr/local/bin:$PATH
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
                /home/${USER}/.npm-global/bin /home/${USER}/.npm \
    && chown -R ${USER}:${USER} /home/${USER}/go /home/${USER}/.asdf \
                /home/${USER}/.npm-global /home/${USER}/.npm

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

# CI gates, installed as the runner user so the shims land in ASDF_DATA_DIR.
#
# asdf where a plugin exists: it is one mechanism for versioning, and a repo
# that pins its own version in .tool-versions overrides these without a new
# image. gosec and govulncheck have no plugin and are `go install`; markdownlint
# and openspec are npm and went in above as root.
RUN set -eux; \
    for p in golangci-lint actionlint goreleaser trivy hadolint yamllint shellcheck; do \
      asdf plugin add "$p"; \
    done; \
    asdf install golangci-lint "${GOLANGCI_LINT_VERSION}"; \
    asdf install actionlint    "${ACTIONLINT_VERSION}"; \
    asdf install goreleaser    "${GORELEASER_VERSION}"; \
    asdf install trivy         "${TRIVY_VERSION}"; \
    asdf install hadolint      "${HADOLINT_VERSION}"; \
    asdf install yamllint      "${YAMLLINT_VERSION}"; \
    asdf install shellcheck    "${SHELLCHECK_VERSION}"; \
    asdf set -u golangci-lint "${GOLANGCI_LINT_VERSION}"; \
    asdf set -u actionlint    "${ACTIONLINT_VERSION}"; \
    asdf set -u goreleaser    "${GORELEASER_VERSION}"; \
    asdf set -u trivy         "${TRIVY_VERSION}"; \
    asdf set -u hadolint      "${HADOLINT_VERSION}"; \
    asdf set -u yamllint      "${YAMLLINT_VERSION}"; \
    asdf set -u shellcheck    "${SHELLCHECK_VERSION}"; \
    asdf reshim

# markdownlint and openspec have no asdf plugin, so npm is the packaging they
# ship in. Installed as the runner user into NPM_CONFIG_PREFIX, which is why
# this is here rather than before the USER switch: a root install would leave
# root-owned files in the runner's home.
# actionlint uses pyflakes for `run:` blocks with shell: python. --break-system-
# packages because noble marks the system python externally-managed; this is a
# purpose-built image, not a general-purpose desktop. Running as the runner user
# puts the entry point in ~/.local/bin, which is on PATH above - a pip install
# in a workflow lands in the same place and works without sudo.
RUN pip3 install --no-cache-dir --break-system-packages \
      "pyflakes==${PYFLAKES_VERSION}"

RUN npm install -g --no-fund --no-audit \
      "markdownlint-cli@${MARKDOWNLINT_VERSION}" \
      "@fission-ai/openspec@${OPENSPEC_VERSION}" \
    && npm cache clean --force

# Go-installed gates. GOFLAGS is cleared afterwards so a workflow's build is not
# affected by anything set here.
RUN set -eux; \
    go install "github.com/securego/gosec/v2/cmd/gosec@v${GOSEC_VERSION}"; \
    go install "golang.org/x/vuln/cmd/govulncheck@v${GOVULNCHECK_VERSION}"; \
    # go clean, not rm -rf: the module cache is written read-only, so rm fails
    # with EACCES partway through and leaves the layer half-cleaned.
    go clean -modcache; \
    go clean -cache

ENV PATH=${GOPATH}/bin:$PATH

# The chart overrides this with /home/runner/run.sh; set so the image is also
# usable standalone.
ENTRYPOINT ["/home/runner/run.sh"]
