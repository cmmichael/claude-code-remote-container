# Synology (DSM 7.2+, Container Manager)

This runs claude-code-web as a Container Manager project, using the published image so the NAS doesn't build anything.

## 1. Find your user and group IDs

The container runs as a user that owns your files, so edits on your shares keep the right owner. Over SSH (Control Panel → Terminal & SNMP → Enable SSH):

```sh
id your-dsm-user
# uid=1026(your-dsm-user) gid=100(users) ...
```

Note the `uid` and `gid`.

## 2. Create the folders first

Container Manager doesn't create missing bind-mount folders; the project fails to start instead. In File Station, or over SSH:

```sh
sudo mkdir -p /volume1/docker/claude-code-web/config
sudo chown -R 1026:100 /volume1/docker/claude-code-web      # your uid:gid
```

`config` becomes the container's home: the Claude login, transcripts and settings. Keep it private.

Pick the folder Claude should work in, for example an existing share such as `/volume1/projects`. It's mounted at `/workspace`.

## 3. Create the project

Container Manager → **Project** → **Create**. Path: `/volume1/docker/claude-code-web`. Choose **Create docker-compose.yml** and paste:

```yaml
services:
  claude:
    image: ghcr.io/cmmichael/claude-code-web:latest
    container_name: claude
    hostname: claude
    init: true
    stop_grace_period: 30s
    user: "1026:100"                    # your uid:gid from step 1
    environment:
      - TZ=Europe/London
      - CLAUDE_RC_NAME=nas-web          # name shown in the Claude app
      # Turn these on once a proxy is in front (step 5):
      # - CLAUDE_WEB_AUTH=header
      # - CLAUDE_WEB_ALLOWED_USERS=you@github
      # - CLAUDE_WEB_TRUSTED_PROXIES=172.17.0.1/32
    volumes:
      - ./config:/config
      - /volume1/projects:/workspace    # what Claude works on
    ports:
      - "127.0.0.1:7681:7681"           # loopback only
    restart: unless-stopped
```

Build and start it.

## 4. First login

The terminal is only on the NAS's loopback, so the first time, use an SSH tunnel from your computer:

```sh
ssh -L 7681:127.0.0.1:7681 you@your-nas
```

Open http://127.0.0.1:7681, run `/login` with your claude.ai account, and accept the trust prompt for `/workspace`. Within a minute the session shows up in the Claude app as `nas-web`. From then on you can use it from the app without the tunnel.

## 5. Reach the terminal from your devices

The simplest way on a Synology is Tailscale's DSM package. Install it from Package Center and sign in, then over SSH:

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:7681
```

The terminal is now at `https://<nas-name>.<tailnet>.ts.net` for devices on your tailnet. Tailscale adds a `Tailscale-User-Login` header to each request, and the container can check it. The request reaches the container from Docker's bridge gateway, so trust that address only:

```sh
sudo docker inspect claude -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'
# 172.17.0.1
```

Uncomment the three `CLAUDE_WEB_*` lines in the project, with that address and your tailnet login, and rebuild the project. Then check it from a tailnet device:

```sh
curl -s https://<nas-name>.<tailnet>.ts.net/api/whoami
# {"auth":"header","user":"you@github"}
```

Prefer an identity-aware proxy with your Google or GitHub login? See [Pomerium](pomerium.md).

## Updates

Claude Code updates itself inside the container, and idle sessions move onto new releases without you. For new images, Container Manager → Project → **Action → Build** pulls the latest. To do that unattended, run Watchtower with `WATCHTOWER_TIMEOUT=30s`.

## Letting Claude manage your containers (optional)

Don't mount `/var/run/docker.sock`: that's root on the NAS. Run [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) with only what you want to allow (for example `CONTAINERS=1`, `INFO=1`, `POST=0`), and set `DOCKER_HOST=tcp://docker-socket-proxy:2375` in the claude service.
