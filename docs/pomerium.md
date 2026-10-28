# Behind Pomerium

[Pomerium](https://www.pomerium.com) signs users in with your identity provider (Google, GitHub, any OIDC) before a request reaches the terminal. With `CLAUDE_WEB_AUTH=pomerium`, the container then verifies Pomerium's signed assertion itself on every request. A request that gets to the container some other way, without passing the policy, is refused.

## Already running Pomerium

Add a route (`examples/pomerium/route.yaml`):

```yaml
- from: https://claude.example.com
  to: http://claude:7681
  allow_websockets: true
  pass_identity_headers: true      # sends X-Pomerium-Jwt-Assertion
  policy:
    - allow:
        or:
          - email:
              is: you@example.com
```

And set this in the claude container's environment:

```yaml
- CLAUDE_WEB_AUTH=pomerium
- CLAUDE_WEB_POMERIUM_JWKS_URL=https://claude.example.com/.well-known/pomerium/jwks.json
- CLAUDE_WEB_POMERIUM_AUDIENCE=claude.example.com
- CLAUDE_WEB_ALLOWED_USERS=you@example.com
```

- **`CLAUDE_WEB_POMERIUM_JWKS_URL`** is where the container fetches Pomerium's public signing keys. Any Pomerium route host serves them at `/.well-known/pomerium/jwks.json` without sign-in. The container must be able to reach that URL. The URL is always configured, never taken from the request, so a forged `Host` header can't supply its own keys.
- **`CLAUDE_WEB_POMERIUM_AUDIENCE`** is the route's host. Pomerium issues assertions per route, so this stops an assertion for a different route from opening the terminal.
- **`CLAUDE_WEB_ALLOWED_USERS`** should match the route's policy. The policy decides who reaches the container, and the list decides who gets the terminal.

Set a stable `SIGNING_KEY` in Pomerium. Without one, the key changes on every Pomerium restart. The container then fetches the new key on the first request that names it (at most once a minute), so it still works, but a stable key avoids the extra fetch.

## Starting from scratch

`examples/pomerium/` runs Pomerium with Let's Encrypt and the claude container on one host:

```sh
cd examples/pomerium
cp pomerium.env.example pomerium.env   # secrets and your OAuth client; see comments
# edit config.yaml and docker-compose.yml: replace example.com and you@example.com
docker compose up -d
```

It needs DNS for `claude.example.com` and `auth.example.com` pointing at the host, and ports 80 and 443 reachable for Let's Encrypt.

## Check it

```sh
curl -s https://claude.example.com/api/whoami     # in a signed-in browser, or with the session cookie
# {"auth":"pomerium","user":"you@example.com"}
```

| You see | Meaning |
| --- | --- |
| `no Pomerium assertion` | The route doesn't have `pass_identity_headers: true`, or the request skipped Pomerium |
| `unknown kid …` | The container can't fetch the JWKS URL, or it points at a different Pomerium. The container log shows the fetch error |
| `audience X is not Y` | `CLAUDE_WEB_POMERIUM_AUDIENCE` isn't this route's host |
| `bad signature` | The token wasn't signed by the Pomerium at the JWKS URL |
| `you@… is not in CLAUDE_WEB_ALLOWED_USERS` | Signed in fine, but not on the list |
