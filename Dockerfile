FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    curl \
    jq \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    make \
    g++ \
    && ln -sf /usr/bin/python3 /usr/local/bin/python \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install OpenCode CLI globally (headless harness for Berget Code)
RUN npm install -g opencode-ai

# Install nvm for the node user so agents can install/switch Node versions.
# BASH_ENV makes nvm available in non-interactive `bash -c` commands.
# The init script guards `set -eu` so it is safe to source from the
# entrypoint, which runs with `set -euo pipefail`.
ENV NVM_DIR=/home/node/.nvm
ENV NVM_VERSION=v0.40.1
ENV BASH_ENV=/home/node/.nvm_init.sh
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
       | NVM_DIR="$NVM_DIR" PROFILE=/dev/null bash \
    && printf '%s\n' \
       'export NVM_DIR="/home/node/.nvm"' \
       'if [ -s "$NVM_DIR/nvm.sh" ]; then' \
       '  __nvm_prev=$(set +o)' \
       '  set +eu' \
       '  . "$NVM_DIR/nvm.sh"' \
       '  eval "$__nvm_prev"' \
       '  unset __nvm_prev' \
       'fi' \
       > "$BASH_ENV" \
    && echo '[ -f "$BASH_ENV" ] && . "$BASH_ENV"' >> /home/node/.bashrc \
    && chown -R node:node "$NVM_DIR" "$BASH_ENV" /home/node/.bashrc \
    && bash -c ". $BASH_ENV && nvm install 20 && nvm install 22 && nvm alias default 22"

# Security scanner tools for SDLC security audit
# Versions pinned — bump in a dedicated version PR per ADR-0025
# pip-audit:     2.7.3
# govulncheck:   v1.3.0
# cargo-audit:   0.20.0
# trufflehog:    v3.88.4
# hadolint:      v2.12.0
#
# Installation strategy:
#   pip-audit    — pip install (Python already in image)
#   govulncheck  — go install; Go toolchain installed and removed after build
#   cargo-audit  — pre-built binary from GitHub releases (avoids Rust toolchain)
#   trufflehog   — pre-built binary from GitHub releases
#   hadolint     — pre-built binary from GitHub releases

# pip-audit (Python CVE scanner)
RUN pip3 install --break-system-packages --no-cache-dir pip-audit==2.7.3

# govulncheck (Go CVE scanner) — install Go, build binary, remove Go toolchain
RUN set -eux; \
    GOVERSION="1.26.2"; \
    GOARCH="$(dpkg --print-architecture)"; \
    case "$GOARCH" in \
      amd64) GOSHA="990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282" ;; \
      arm64) GOSHA="c958a1fe1b361391db163a485e21f5f228142d6f8b584f6bef89b26f66dc5b23" ;; \
      *) echo "Unsupported arch: $GOARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://dl.google.com/go/go${GOVERSION}.linux-${GOARCH}.tar.gz" -o /tmp/go.tar.gz; \
    echo "${GOSHA}  /tmp/go.tar.gz" | sha256sum -c -; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz; \
    /usr/local/go/bin/go install golang.org/x/vuln/cmd/govulncheck@v1.3.0; \
    cp /root/go/bin/govulncheck /usr/local/bin/govulncheck; \
    rm -rf /usr/local/go /root/go /root/.cache/go-build

# cargo-audit (Rust CVE scanner) — pre-built binary
RUN set -eux; \
    GOARCH="$(dpkg --print-architecture)"; \
    case "$GOARCH" in \
      amd64) CARGO_AUDIT_ARCH="x86_64-unknown-linux-musl" ;; \
      arm64) CARGO_AUDIT_ARCH="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported arch: $GOARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/rustsec/rustsec/releases/download/cargo-audit%2Fv0.20.0/cargo-audit-${CARGO_AUDIT_ARCH}-v0.20.0.tgz" \
      -o /tmp/cargo-audit.tgz; \
    tar -xzf /tmp/cargo-audit.tgz -C /tmp; \
    mv /tmp/cargo-audit-${CARGO_AUDIT_ARCH}-v0.20.0/cargo-audit /usr/local/bin/cargo-audit; \
    chmod +x /usr/local/bin/cargo-audit; \
    rm -rf /tmp/cargo-audit.tgz /tmp/cargo-audit-${CARGO_AUDIT_ARCH}-v0.20.0

# trufflehog (secret scanner) — pre-built binary
RUN set -eux; \
    GOARCH="$(dpkg --print-architecture)"; \
    case "$GOARCH" in \
      amd64) TH_ARCH="amd64" ;; \
      arm64) TH_ARCH="arm64" ;; \
      *) echo "Unsupported arch: $GOARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/trufflesecurity/trufflehog/releases/download/v3.88.4/trufflehog_3.88.4_linux_${TH_ARCH}.tar.gz" \
      -o /tmp/trufflehog.tar.gz; \
    tar -xzf /tmp/trufflehog.tar.gz -C /usr/local/bin trufflehog; \
    chmod +x /usr/local/bin/trufflehog; \
    rm /tmp/trufflehog.tar.gz

# hadolint (Dockerfile linter) — pre-built binary
RUN set -eux; \
    GOARCH="$(dpkg --print-architecture)"; \
    case "$GOARCH" in \
      amd64) HL_ARCH="x86_64" ;; \
      arm64) HL_ARCH="arm64" ;; \
      *) echo "Unsupported arch: $GOARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-${HL_ARCH}" \
      -o /usr/local/bin/hadolint; \
    chmod +x /usr/local/bin/hadolint

# Prepare home directories for the node user.
# OpenCode reads global config from ~/.config/opencode/opencode.json and
# stores session/auth state under ~/.local/share/opencode.
RUN mkdir -p /home/node/.config/opencode /home/node/.local/share/opencode \
    && chown -R node:node /home/node/.config /home/node/.local

VOLUME /usercontent

WORKDIR /runner
COPY ./scripts ./

RUN chmod +x /runner/*.sh

# Starts as root; entrypoint fixes volume ownership then drops to node
ENTRYPOINT ["/runner/entrypoint.sh"]
