# Security

The web terminal is a shell with your Claude login and whatever the container can reach. Treat access to it like SSH access.

## Reporting a vulnerability

Please use GitHub's private reporting: **Security → Report a vulnerability** on this repository. Don't open a public issue for anything that could let someone reach the terminal without being allowed in.

## What the project does to keep the terminal closed

- The compose file publishes the terminal on `127.0.0.1` only.
- With `CLAUDE_WEB_AUTH` set, the container checks every request itself (Pomerium's signed assertion, or a header from a trusted proxy) against `CLAUDE_WEB_ALLOWED_USERS`, websockets included. See the README, "Allowed users".
- ttyd listens on loopback behind the web front end.
- CI scans the full git history for secrets on every pull request.
- Base images are pinned by digest and GitHub Actions by commit.

## What you should do

- Put an authenticating proxy in front (Pomerium, Tailscale, or similar) and turn on `CLAUDE_WEB_AUTH` as a second check.
- Never publish port 7681 to the internet directly.
- Keep `./config` private. It holds your Claude credentials and transcripts.
- If you give the container Docker access, use a restricted socket proxy, never the raw socket.
