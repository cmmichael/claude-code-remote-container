FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl wget git jq less nano openssh-client procps ripgrep \
    unzip zip gnupg tmux htop lsof file rsync sqlite3 libnss-wrapper \
    python3 python3-pip python3-venv \
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

# Optional extras: Docker CLI (+compose plugin) and GitHub CLI.
# Build with --build-arg INSTALL_DOCKER_CLI=false / INSTALL_GH=false to skip.
ARG INSTALL_DOCKER_CLI=true
ARG INSTALL_GH=true
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
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/claude-session /usr/local/bin/claude-update-watcher /usr/local/bin/with-passwd \
 && for t in ssh scp sftp ssh-keygen ssh-add; do ln -s with-passwd "/usr/local/bin/$t"; done

# ttyd web terminal. Put an authenticating reverse proxy in front of it, or set
# TTYD_CREDENTIAL; never publish it to an untrusted network bare.
EXPOSE 7681

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
