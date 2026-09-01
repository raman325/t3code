# Deploying the Hermes fork to VM 104

Builds the `feat/hermes-acp-provider` server and installs it on the Hermes VM
(`ssh hermes`) as a systemd user service.

## Build + deploy

```bash
./deploy/build-hermes-server.sh                 # -> /tmp/t3-0.0.37.tgz
./deploy/deploy-hermes-server.sh /tmp/t3-0.0.37.tgz hermes
```

`build` runs the repo's own `vp run --filter t3 build` (which also builds and
bundles the web client), then resolves pnpm `catalog:` specs and drops
`devDependencies` so plain `npm install` works on the target.

`deploy` ships the tarball, `npm install`s it under `~/t3code-hermes/app`,
writes `~/.config/systemd/user/t3code-hermes.service`, enables lingering, and
starts the unit.

## Do not run `t3 service install` on this host

The stock service path runs `npm install t3@<version>`, which fetches the
**published upstream package** (no Hermes), and its launcher can later
self-update to an upstream release — silently replacing the fork. The custom
unit avoids this entirely: per `docs/internals/server-updates.md`, *"Foreground
CLI processes do not self-update."*

## Enabling Hermes

The provider is off by default. `~/.t3/userdata/settings.json`:

```json
{
  "providers": {
    "hermes": {
      "enabled": true,
      "binaryPath": "/home/raman/.hermes/hermes-agent/venv/bin/hermes"
    }
  }
}
```

The explicit path is required because the Hermes CLI lives in a venv and is not
on the service's `PATH`. Restart after editing:
`systemctl --user restart t3code-hermes.service`.

## Operating

```bash
ssh hermes systemctl --user status t3code-hermes.service
ssh hermes journalctl --user -u t3code-hermes.service -f
ssh hermes systemctl --user restart t3code-hermes.service
```

A fresh pairing URL (token rotates each start) is printed at startup:

```bash
ssh hermes journalctl --user -u t3code-hermes.service --no-pager \
  | grep -oE 'http://[^ ]*/pair#token=[A-Z0-9]+' | tail -1
```

To link this environment to T3 Connect (hosted web/mobile), run interactively —
it needs a browser login:

```bash
ssh -t hermes '~/t3code-hermes/app/node_modules/.bin/t3 connect login'
ssh -t hermes '~/t3code-hermes/app/node_modules/.bin/t3 connect link'
```

## Redeploying a new build

Re-run both scripts. `npm install` overwrites the app directory in place; the
unit file is rewritten and the service restarted. State in `~/.t3` is untouched.
