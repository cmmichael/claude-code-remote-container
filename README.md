# claude-code-web

Claude Code in a container that is always on:

- **Web terminal.** A persistent tmux session served by [ttyd](https://github.com/tsl0922/ttyd) on port 7681. Closing the browser tab doesn't stop anything; reopening it reattaches.
- **Resumes itself.** The session restarts automatically and resumes the same conversation, across crashes and container restarts.
- **Remote Control.** The web-terminal session also appears in claude.ai/code and the Claude app, and a separate Remote Control server lets you start new sessions from there.
- **Applies updates.** Claude Code downloads updates in the background. A watcher restarts idle sessions onto the new version, so "restart to update" never piles up.

## Quick start

```sh
cp .env.example .env            # set PUID/PGID, WORKSPACE_DIR, TTYD_CREDENTIAL
mkdir -p config workspace
sudo chown "$(id -u):$(id -g)" config workspace   # must match PUID/PGID
docker compose up -d --build
```

Open http://127.0.0.1:7681 (or your proxied URL). On first start:

1. Run `/login` with a claude.ai account. Remote Control needs one; API keys don't work for it.
2. Accept the trust prompt for `/workspace`.

The Remote Control server retries every 30 seconds and picks up the login by itself.

## Exposing it

The web terminal is a shell with your Claude login. The compose file binds it to `127.0.0.1` only. To reach it from elsewhere, put an authenticating reverse proxy in front:

- `examples/pomerium-route.yaml` for Pomerium (identity-aware, recommended).
- `examples/caddy.Caddyfile` for Caddy with basic auth.
- Or set `TTYD_CREDENTIAL=user:password` for ttyd's own basic auth, only over TLS.

The proxy must allow websockets.

## Copy and paste

tmux and Claude Code both hold the mouse, so a plain drag is tmux's selection, not the browser's. All of these land on your clipboard:

| To | Do |
| --- | --- |
| Copy what you drag | Drag with the mouse. tmux copies the selection when you let go. |
| Copy from Claude Code | Use its own copy keys, such as `c` on the `/login` screen. |
| Copy with the browser's own selection | Hold `Option` (macOS) or `Shift` (Windows, Linux) while dragging. Look for the brief ✂ icon. |
| Open the login URL | Click any row of it. It is a real link, so the whole URL opens even though it wraps. |
| Paste | `Cmd+V` or `Ctrl+Shift+V`, or `Shift+Insert`. |

The first two travel as OSC 52 escape sequences, and browsers accept those only on HTTPS or `localhost`. Behind a plain-HTTP proxy, use the modifier drag instead.

ttyd 1.7.7, the current release, embeds a web client that ignores OSC 52 entirely. The image therefore builds the newer ttyd client (xterm.js 5.5 with its clipboard addon) from a pinned commit and serves it with `--index`. `tmux.conf` labels every copy the way that client accepts and forwards hyperlinks, which needs the tmux 3.5 from bookworm-backports.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PUID` / `PGID` | 1000 | User the container runs as; must own `./config` |
| `WORKSPACE_DIR` | `./workspace` | Host folder mounted at `/workspace` |
| `CLAUDE_RC_NAME` | `claude-web` | Session name in claude.ai/code |
| `TTYD_CREDENTIAL` | empty | Optional `user:password` for the web terminal |
| `TTYD_PORT` | 7681 | Host port, loopback only |
| `CLAUDE_AUTO_UPDATE_RESTART` | `true` | Run the update watcher |
| `CLAUDE_UPDATE_IDLE_SECS` | 900 | Idle time before an update restart |
| `CLAUDE_UPDATE_CHANNEL` | `stable` | Claude Code releases to follow: `stable`, typically about a week behind and skipping releases with major regressions, or `latest`. It sets the first install and Claude Code's own background updater (`autoUpdatesChannel`) |
| `CLAUDE_REMOTE_CONTROL_SERVER` | `true` | Run the separate Remote Control server |
| `CLAUDE_WEB_FRONT` | `true` | Serve the terminal through the front end that adds the app-sessions badge; `false` lets ttyd take port 7681 directly |
| `TTYD_INTERNAL_PORT` | 7683 | Loopback port ttyd uses behind the front end |
| `CLAUDE_STOP_GRACE_SECS` | 20 | How long Claude gets to exit when the container stops. Keep it under `stop_grace_period` (30s) |

Build arguments `INSTALL_DOCKER_CLI` and `INSTALL_GH` (both `true`) control the optional Docker and GitHub CLIs. To let Claude manage containers, point `DOCKER_HOST` at a restricted socket proxy such as `tecnativa/docker-socket-proxy`. Don't mount the raw Docker socket: that is root on the host.

## App sessions

Sessions started from claude.ai/code or the Claude app run headless under the Remote Control server, so the web terminal can't show them. A badge in the terminal's top-right corner shows how many there are, with a pulsing dot while one is working. Click it for the list: each entry links to the session on claude.ai/code. Esc or a click elsewhere closes it. The badge stays hidden when there are none.

`scripts/web-front.js` provides it. It takes port 7681, proxies the terminal (websockets included) to ttyd on loopback, serves the list as JSON at `/api/sessions`, and adds `scripts/web-badge.html` to the terminal page. Busy and idle come from the session hook's per-process stamps. With `TTYD_CREDENTIAL` set, `/api/sessions` asks for the same credential.

## How it works

- `scripts/entrypoint.sh` installs Claude Code into `$HOME/.local/bin` if missing, adds two hooks to `$HOME/.claude/settings.json`, and starts tmux, ttyd, the watcher and the Remote Control server.
- `scripts/session.sh` runs inside tmux. It loops `claude --resume <id> --remote-control <name>`, falling back to `--continue`, then a fresh session.
- The hooks (UserPromptSubmit and Stop) record when a turn starts and ends and the current session id in `$HOME/.claude/autoupdate-state/`. They only act in the web-terminal session.
- `scripts/update-watcher.sh` checks every minute whether the running binary is older than the installed one. When no turn is in flight and the terminal has been quiet for the idle time, it sends SIGTERM, and the session loop resumes on the new version. A turn interrupted with Esc never records its end, so after an hour of quiet it stops counting. A permission question left unanswered that long looks the same: the restart drops it, and you ask again in the resumed conversation. Before restarting anything onto a release, it checks that the release answers `claude --version`. A release that fails is not moved onto, and it is checked again every 10 minutes, so a failure that passes, such as a timeout under load, does not strand the session.
- On `docker stop`, the entrypoint stops its restart loops, sends every Claude process SIGTERM and waits up to `CLAUDE_STOP_GRACE_SECS` before taking tmux down. Claude finishes cleanly and its Remote Control sessions close instead of being killed.
- Claude Code installs in the background on first start, so the web terminal is up at once. The session waits for the binary, and Ctrl-C there gives a shell.
- The image's health check reports healthy while the web terminal answers.

## What's private

Everything personal lives in `./config` (the container's `$HOME`): Claude credentials, transcripts and settings. It is gitignored. Never commit or share it.

## Prebuilt image

Every push to `main` builds `ghcr.io/<owner>/claude-code-web` for amd64 and arm64 (see `.github/workflows/image.yml`). The package is private while the repo is. To use it, run `docker login ghcr.io` with a token that has `read:packages`, then swap `build: .` for that `image:` line in `docker-compose.yml`.

## SSH as an arbitrary user

The container runs as whatever `PUID` you choose, which has no entry in `/etc/passwd`. OpenSSH refuses to run without one. `ssh`, `scp`, `sftp`, `ssh-keygen` and `ssh-add` therefore go through `scripts/with-passwd.sh`, which uses nss_wrapper to supply an entry for that process only. Keys and `~/.ssh/config` live in `./config/.ssh` and persist.
