# What to use it for

claude-code-remote-container earns its place on a machine with no screen that runs your services: a Synology or other NAS, a Raspberry Pi, a mini PC. Mount the folder your configs live in at `/workspace`, and Claude Code works on them in place, from a browser tab or from the Claude app on your phone.

Each example below has a prompt you can paste and the setup it needs. The recipes are at the end.

## Your Docker stack

Most home servers keep their compose files in one folder: `/volume1/docker` on a Synology, `~/docker` on a Pi. Mount it at `/workspace` ([recipe](#mount-your-docker-folder)).

**Review before you change anything**

> Read docker-compose.yaml and list every published port, every bind mount outside this folder, and every service with access to the Docker socket. Say which ones you'd tighten and why.

**Add a service the way the rest are written**

> Add Jellyfin to the compose file. Match the existing services' logging, restart policy, timezone and user settings, keep its config under ./jellyfin, and don't publish a port: it'll sit behind the proxy.

**Move secrets out of the compose file**

> Find passwords, tokens and API keys written directly into docker-compose.yaml or the service configs. Move each one to an env file per service, add those files to .gitignore, and show me the diff. Don't print the values.

**Find out why a container keeps restarting** (needs [Docker read access](#let-claude-see-your-containers))

> paperless has restarted 30 times today. Read its last 200 log lines and those of its database, find the cause, and propose the smallest fix.

Claude can read logs and inspect containers through a restricted socket proxy. With the proxy's write access off, it can't create containers, which is what keeps that access safe. Applying a compose change stays with you, with `docker compose up -d` on the host.

## Your reverse proxy and sign-in

Proxy configs are where a typo locks you out, so it helps to have something careful in the loop.

**Add a route for a new service** (Pomerium)

> Add a Pomerium route for jellyfin.example.com to http://jellyfin:8096 with websockets, and the same policy as the photos route. Back up config.yaml next to itself with today's date, edit it in place (it's a single-file bind mount, so keep the inode), and tell me what to check in Pomerium's log after the hot reload.

**Explain a sign-in loop**

> Users get "400 Bad Request" from the sign-in page on one route only. Here's the request id from Pomerium's error page: ... Read Pomerium's log around that id and explain what happened.

**Audit who can reach what**

> Make a table of every route in pomerium/config.yaml: host, upstream, policy (resolve the YAML anchors to the actual emails or groups), whether identity headers are passed, and whether it's public. Flag anything public that shouldn't be.

The same works for Caddy, Traefik labels, nginx and Authelia. Mount the folder their config lives in.

## Monitoring and backups

**Monitors for everything**

> Uptime Kuma is managed by AutoKuma labels in docker-compose.yaml. Add an HTTP monitor label to every service with a web UI that doesn't have one yet, tagged "home", using each service's internal URL.

**A database backup you'll actually notice failing**

> Add a sidecar that pg_dumps the paperless database nightly to ./backups with 14 days' retention, and add a push monitor so a missed backup alerts me.

## Home Assistant, Pi-hole and friends

Mount the config folder of the service you want to work on, or the parent folder of all of them.

> In the Home Assistant config, find automations that reference entities that no longer exist, and list them with the file and line.

> Pi-hole on this Pi is slow to resolve local names. Look at its custom DNS and dnsmasq config and suggest what to change.

## Keep it in git

If your config folder is a git repository, Claude can commit each change with a clear message, so every edit it makes is reviewable and easy to revert:

> Commit the Pomerium route change on its own, with a message saying why.

Keep secrets out of the repository: env files in `.gitignore`, as in the secrets example above.

## Files and media

> Rename the files in /workspace/media/incoming to Jellyfin's naming scheme ("Show Name (Year)/Season 01/Show Name - S01E01.ext"). Show me the plan before moving anything.

## From your phone

All of the above works from the Claude app. Start a session on your server from claude.ai/code or the app (the Remote Control server picks it up), or open the terminal session that's already running. A long task keeps going while your phone is in your pocket. The app-sessions badge in the web terminal shows what's running.

---

# Recipes

## Mount your Docker folder

Synology, where everything lives under `/volume1/docker`:

```yaml
services:
  claude:
    image: ghcr.io/cmmichael/claude-code-remote-container:latest
    container_name: claude
    init: true
    stop_grace_period: 30s
    user: "1026:100"                      # your DSM user: `id your-user`
    environment:
      - TZ=Europe/London
      - CLAUDE_RC_NAME=nas-web
    volumes:
      - /volume1/docker/claude-code-remote-container/config:/config
      - /volume1/docker:/workspace        # every service's config, editable
    ports:
      - "127.0.0.1:7681:7681"
    restart: unless-stopped
```

Raspberry Pi (64-bit Raspberry Pi OS on a Pi 3, 4 or 5; the image is built for arm64 and amd64):

```yaml
services:
  claude:
    image: ghcr.io/cmmichael/claude-code-remote-container:latest
    container_name: claude
    init: true
    stop_grace_period: 30s
    user: "1000:1000"                     # the pi user: `id`
    environment:
      - TZ=Europe/London
      - CLAUDE_RC_NAME=pi-web
    volumes:
      - ./config:/config
      - /home/pi/docker:/workspace
    ports:
      - "127.0.0.1:7681:7681"
    restart: unless-stopped
```

On a Pi, put `config` on the SD card or SSD the system runs from, not on a USB stick that may not be mounted when the container starts.

## Let Claude see your containers

Never mount `/var/run/docker.sock` into the container. Docker access through that socket is root on the host. Use [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) and allow only reading:

```yaml
services:
  docker-proxy:
    image: tecnativa/docker-socket-proxy:latest
    environment:
      - CONTAINERS=1     # list, inspect, logs
      - INFO=1
      - EVENTS=1
      - POST=0           # no create, start, stop or delete
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped

  claude:
    # ... as above, plus:
    environment:
      - DOCKER_HOST=tcp://docker-proxy:2375
```

Claude can then run `docker ps`, `docker logs` and `docker inspect`. If you want it to restart containers too, add `ALLOW_START=1`, `ALLOW_STOP=1` and `ALLOW_RESTARTS=1`, and keep `POST=0` so it still can't create containers with the host's filesystem mounted.

## Let Claude write a shared config file

If a config file belongs to another service's user (for example a proxy config owned by a different UID), add that file's group to the container instead of loosening its permissions:

```yaml
  claude:
    group_add:
      - "100"            # the group that owns the file, with group write
```

## Give it git

Set your name and email once in the terminal: `git config --global user.name ...` and `user.email`. They're kept in `./config` with the rest of the container's home. For pushing, add a deploy key with write access for that one repository. SSH works in the container even though its user has no passwd entry.
