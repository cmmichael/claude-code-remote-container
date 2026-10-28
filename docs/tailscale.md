# Behind Tailscale

[Tailscale Serve](https://tailscale.com/kb/1312/serve) puts the terminal on your tailnet with HTTPS. It also tells the backend who is asking: each request carries a `Tailscale-User-Login` header. With `CLAUDE_WEB_AUTH=header`, the container checks that header against `CLAUDE_WEB_ALLOWED_USERS`. It believes the header only from addresses in `CLAUDE_WEB_TRUSTED_PROXIES`, so nothing else can claim to be you.

Don't use Tailscale Funnel for the terminal. Funnel publishes to the internet, and Funnel requests don't carry the user header, so the container refuses them anyway.

## Option A: a Tailscale sidecar (any Docker host)

`examples/tailscale/` runs a Tailscale container next to claude. The claude container shares its network, so Serve reaches the terminal on `127.0.0.1`. That's the default trusted proxy, so there's nothing to configure:

```sh
cd examples/tailscale
TS_AUTHKEY=tskey-auth-... CLAUDE_WEB_ALLOWED_USERS=you@github docker compose up -d
```

The terminal is at `https://claude.<tailnet>.ts.net`. Create the auth key in the Tailscale admin console under Settings → Keys.

## Option B: Tailscale already on the host (Synology package, Linux)

Publish the terminal on the host's loopback (the default compose file does), then:

```sh
sudo tailscale serve --bg --https=443 http://127.0.0.1:7681
```

Requests now reach the container from Docker's bridge gateway rather than from `127.0.0.1`. Trust that address only:

```sh
docker inspect claude -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'
# 172.17.0.1
```

```yaml
- CLAUDE_WEB_AUTH=header
- CLAUDE_WEB_TRUSTED_PROXIES=172.17.0.1/32
- CLAUDE_WEB_ALLOWED_USERS=you@github
```

Other containers on the same Docker network reach the terminal from their own addresses, not the gateway, so they're refused. Processes on the host itself can still set the header. That's the usual trust boundary for a home server.

## Check it

From a device on your tailnet:

```sh
curl -s https://claude.<tailnet>.ts.net/api/whoami
# {"auth":"header","user":"you@github"}
```

| You see | Meaning |
| --- | --- |
| `request from 172.x.x.x, not a trusted proxy` | Add that address, or the gateway from Option B, to `CLAUDE_WEB_TRUSTED_PROXIES` |
| `no Tailscale-User-Login header` | The request didn't come through Serve, or it came through Funnel |
| `you@… is not in CLAUDE_WEB_ALLOWED_USERS` | Use your login exactly as Tailscale shows it in the admin console, for example `you@github` |

Your tailnet's access controls still decide which devices can reach the node at all. Limit them to your own devices.
