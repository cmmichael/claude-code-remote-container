# Contributing

Thanks for helping. Issues and pull requests are welcome.

- **Every merge to `main` is a release.** Write the PR description as the release notes. Add `release:minor` for new behaviour or settings, `release:major` for breaking changes, or `release:skip` for docs and CI-only changes. Patch is the default.
- **CI must pass.** It runs shellcheck, hadolint, actionlint, the web front end's unit tests (`node --test tests/*.test.js`), a secret scan, and a smoke test of the built image (`tests/smoke.sh`).
- **Add a test with new behaviour.** Use `tests/web-front.test.js` for the web front end and `tests/smoke.sh` for anything you can see from outside the container.
- **No secrets, hostnames or personal data** in code, examples or PR text. Use `example.com`.
- Scripts must stay LF and executable. If your checkout ignores file modes, run `git update-index --chmod=+x <file>` for new scripts.

Run the checks locally:

```sh
node --test tests/*.test.js
docker build -t claude-code-remote-container:ci . && tests/smoke.sh
```
