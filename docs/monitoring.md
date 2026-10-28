# Monitoring and the rest of the homelab

The container is meant to sit among the usual homelab services: a dashboard, an uptime monitor, an auto-updater, a reverse proxy. This page shows the settings each one needs.

## What to point monitors at

| URL | Answers | Use it for |
| --- | --- | --- |
| `http://claude:7681/healthz` | `200 ok` when the terminal answers, `503` when it doesn't | Up/down monitors |
| `http://claude:7681/healthz?full=1` | The same status code, with JSON detail (below) | Alerting on a specific part |
| `http://claude:7681/` | The terminal page. **403** when `CLAUDE_WEB_AUTH` is on and the request has no identity | Not for monitors |

`/healthz` skips the user check and logs nothing, so it works with `CLAUDE_WEB_AUTH` on and doesn't fill the log. It reports states only, never names, sessions or files.

```json
{"ok":true,"terminal":true,"claude_code":"2.1.308","remote_control_server":true,"update_watcher":true,"auth":"pomerium"}
```

| Field | What a bad value usually means |
| --- | --- |
| `terminal: false` | ttyd stopped; `ok` is false and the status is 503 |
| `claude_code: null` | The first install is still running, or it failed (see the container log) |
| `remote_control_server: false` | The Claude login has expired or was never done. Log in again from the web terminal (`/login`) |
| `update_watcher: false` | `CLAUDE_AUTO_UPDATE_RESTART=false`, or the watcher crashed |

Use the container name (`claude` here) from monitors on the same Docker network, or `127.0.0.1:7681` from the host when the port is published there.

## Uptime Kuma

**Up/down.** Add an HTTP(s) monitor for `http://claude:7681/healthz`. The default accepted codes (200-299) are right.

**Alert when the Claude login lapses.** Add an *HTTP(s) - Json Query* monitor for `http://claude:7681/healthz?full=1`, with the query `remote_control_server` and the expected value `true`.

**Docker health.** A *Docker Container* monitor reads the image's own health check, which calls `/healthz`. It needs Kuma to have Docker access, ideally through a read-only socket proxy.

### With AutoKuma

[AutoKuma](https://github.com/BigBoot/AutoKuma) creates monitors from container labels. Add these to the claude service:

```yaml
    labels:
      - kuma.claude.http.name=Claude Code
      - kuma.claude.http.url=http://claude:7681/healthz
      - kuma.claude-login.json-query.name=Claude Code login
      - kuma.claude-login.json-query.url=http://claude:7681/healthz?full=1
      - kuma.claude-login.json-query.json_path=remote_control_server
      - kuma.claude-login.json-query.expected_value=true
```

## Gatus

```yaml
endpoints:
  - name: claude-code
    url: http://claude:7681/healthz?full=1
    interval: 1m
    conditions:
      - "[STATUS] == 200"
      - "[BODY].remote_control_server == true"
```

## Homepage

```yaml
- Claude Code:
    href: https://claude.example.com
    icon: mdi-console
    description: Claude Code on the NAS
    siteMonitor: http://claude:7681/healthz
```

Point `href` at your proxied URL, the one you open in the browser, and `siteMonitor` at `/healthz`, so the status dot doesn't turn red over a 403.

## Watchtower

Watchtower can apply new image releases (see Images and updates in the README). Two settings matter:

- **`WATCHTOWER_TIMEOUT=30s`** on Watchtower. Its default stop timeout is 10 seconds, shorter than the container's clean stop (up to 20 seconds for Claude to finish its turn and close its app sessions).
- **Leave the container enabled.** Watchtower only skips containers labelled `com.centurylinklabs.watchtower.enable=false`. The example compose files set that label only where the image is built locally, since there's nothing to pull.

A restart from Watchtower is like any other: the terminal session resumes the same conversation by id, and app sessions reconnect.

## Traefik

```yaml
    labels:
      - traefik.enable=true
      - traefik.http.routers.claude.rule=Host(`claude.example.com`)
      - traefik.http.routers.claude.entrypoints=websecure
      - traefik.http.routers.claude.tls.certresolver=letsencrypt
      - traefik.http.services.claude.loadbalancer.server.port=7681
```

Traefik proxies websockets without extra settings. Remove the `ports:` entry from the claude service, so the terminal is reachable only through Traefik.

### Authelia or Authentik in front (forward auth)

Forward-auth providers pass the signed-in user to the backend in a header: `Remote-User` for Authelia, `X-authentik-username` for Authentik. Use header mode, and trust the Docker network Traefik reaches the container on:

```yaml
    environment:
      - CLAUDE_WEB_AUTH=header
      - CLAUDE_WEB_AUTH_HEADER=Remote-User                 # X-authentik-username for Authentik
      - CLAUDE_WEB_TRUSTED_PROXIES=172.20.0.0/16           # the proxy network's subnet
      - CLAUDE_WEB_ALLOWED_USERS=you
    labels:
      - traefik.http.routers.claude.middlewares=authelia@docker
```

Trusting a subnet means trusting every container on that network to set the header honestly. Put the claude container and Traefik on a network of their own, and use that network's subnet: `docker network inspect <network> -f '{{(index .IPAM.Config 0).Subnet}}'`. Pomerium's signed assertion (`CLAUDE_WEB_AUTH=pomerium`) doesn't need this trust, which is why it's the stronger option where you have the choice.

Exclude `/healthz` from the forward-auth middleware if a monitor reaches the container through Traefik. A monitor on the same Docker network doesn't need that, because it calls the container directly.
