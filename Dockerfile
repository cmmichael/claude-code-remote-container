# Web client for ttyd. The client embedded in the ttyd 1.7.7 binary (the latest
# release) bundles xterm.js 5.4 without the clipboard addon, so every OSC 52
# write is silently dropped: tmux mouse/copy-mode copies and Claude Code's
# "press c to copy" never reach the browser clipboard. Build the current client
# (xterm.js 5.5 + @xterm/addon-clipboard) from a pinned ttyd commit and serve it
# with --index. yarn honours the upstream lockfile, so the output is
# reproducible; the page is plain HTML/JS, so this stage runs on the build
# platform even for the arm64 image. Ported from the Home Assistant add-on
# con-ant/hass-addons (claudecode/Dockerfile). Drop the stage and --index once a
# ttyd release newer than 1.7.7 ships, but keep the shim or re-check it.
FROM --platform=$BUILDPLATFORM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da AS ttyd-client
# A failed download in `curl | tar` / `curl | bash` must fail the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
ARG TTYD_CLIENT_COMMIT=2922cb89f518bae4d0fcf4d757a7419638fc71fc
RUN curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
      "https://github.com/tsl0922/ttyd/archive/${TTYD_CLIENT_COMMIT}.tar.gz" \
    | tar xz && mv "ttyd-${TTYD_CLIENT_COMMIT}" /ttyd
WORKDIR /ttyd/html
# COREPACK_INTEGRITY_KEYS=0 keeps the pinned corepack working across npm
# signing-key rotations; dependency integrity comes from yarn.lock checksums.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    COREPACK_NPM_REGISTRY=https://registry.npmjs.org \
    COREPACK_INTEGRITY_KEYS=0
RUN npm install -g corepack@0.35.0 && corepack enable \
 && yarn install --immutable && yarn run inline
# The bundle captures the WebAssembly global at load time. Chrome removes that
# global when the JIT is blocked by policy, which leaves a blank page; the shim
# keeps the terminal working (only sixel images, never enabled here, use wasm).
COPY ttyd-client/ /ttyd-client/
RUN node /ttyd-client/inject-wasm-shim.js /ttyd/html/dist/inline.html /ttyd-client/wasm-shim.html

# Base images are pinned by digest; Dependabot opens a PR when they move.
FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget gawk git jq less nano openssh-client procps ripgrep \
    unzip zip gnupg htop lsof file rsync sqlite3 libnss-wrapper \
    python3 python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*

# tmux from bookworm-backports (3.5a). Bookworm's own 3.3a cannot forward OSC 8
# hyperlinks, which is what makes the wrapped /login URL clickable as one link.
RUN echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list \
 && apt-get update && apt-get install -y --no-install-recommends -t bookworm-backports tmux \
 && rm -rf /var/lib/apt/lists/*

# Node.js (NodeSource) -- handy for MCP servers and JS projects
ARG NODE_MAJOR=22
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# ttyd (web terminal) -- static release binary
ARG TTYD_VERSION=1.7.7
RUN curl -fsSL -o /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.$(uname -m)" \
 && chmod +x /usr/local/bin/ttyd
COPY --from=ttyd-client /ttyd/html/dist/inline.html /usr/share/ttyd/index.html

# Optional extras: Docker CLI (+compose plugin) and GitHub CLI.
# Build with --build-arg INSTALL_DOCKER_CLI=false / INSTALL_GH=false to skip.
ARG INSTALL_DOCKER_CLI=true
ARG INSTALL_GH=true
# $pkgs is a word list on purpose.
# hadolint ignore=SC2086
RUN install -m 0755 -d /etc/apt/keyrings \
 && if [ "$INSTALL_DOCKER_CLI" = "true" ]; then \
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list; \
    fi \
 && if [ "$INSTALL_GH" = "true" ]; then \
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
      && chmod a+r /etc/apt/keyrings/githubcli.gpg \
      && echo "deb [signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list; \
    fi \
 && apt-get update \
 && pkgs=""; \
    [ "$INSTALL_DOCKER_CLI" = "true" ] && pkgs="$pkgs docker-ce-cli docker-compose-plugin"; \
    [ "$INSTALL_GH" = "true" ] && pkgs="$pkgs gh"; \
    if [ -n "$pkgs" ]; then apt-get install -y --no-install-recommends $pkgs; fi \
 && rm -rf /var/lib/apt/lists/*

# HOME lives on a volume so the claude binary (native installer, self-updating in
# $HOME/.local/bin), login credentials, transcripts and user-level npm/pip installs
# all survive container rebuilds.
ENV HOME=/config
ENV NPM_CONFIG_PREFIX=/config/.npm-global
ENV PATH="/config/.local/bin:/config/.npm-global/bin:${PATH}"
WORKDIR /workspace

COPY tmux.conf /etc/tmux.conf
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/session.sh /usr/local/bin/claude-session
COPY scripts/update-watcher.sh /usr/local/bin/claude-update-watcher
COPY scripts/with-passwd.sh /usr/local/bin/with-passwd
COPY scripts/session-hook.sh /usr/local/bin/claude-session-hook
COPY scripts/web-front.js /usr/local/bin/claude-web-front
COPY scripts/web-badge.html /usr/local/share/claude-web/web-badge.html
COPY scripts/rc-server-filter.awk /usr/local/share/claude-web/rc-server-filter.awk
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/claude-session /usr/local/bin/claude-update-watcher /usr/local/bin/with-passwd /usr/local/bin/claude-session-hook /usr/local/bin/claude-web-front \
 && for t in ssh scp sftp ssh-keygen ssh-add; do ln -s with-passwd "/usr/local/bin/$t"; done

# ttyd web terminal. Put an authenticating reverse proxy in front of it, or set
# TTYD_CREDENTIAL; never publish it to an untrusted network bare.
EXPOSE 7681

# Healthy while the terminal answers. With the web front end (the default),
# /healthz checks ttyd behind it and skips the user check, so it works and logs
# nothing with CLAUDE_WEB_AUTH on. With CLAUDE_WEB_FRONT=false, ttyd itself is
# on 7681 and any reply counts (a 401 from TTYD_CREDENTIAL included).
# Docker only reports the status; nothing restarts on it unless something like
# autoheal watches it.
# Shell form for the `|| exit 1`, which maps any curl failure to Docker's "unhealthy" code.
# hadolint ignore=DL3025
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
    CMD if [ "$CLAUDE_WEB_FRONT" = "false" ]; then curl -so /dev/null http://127.0.0.1:7681/; \
        else curl -fso /dev/null http://127.0.0.1:7681/healthz; fi || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
