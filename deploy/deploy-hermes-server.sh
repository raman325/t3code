#!/usr/bin/env bash
# Install the Hermes fork's t3 server on a remote host as a systemd user service.
#
# Why not `t3 service install`? That path runs `npm install t3@<version>`, which
# fetches the PUBLISHED upstream package (no Hermes) and its launcher can later
# self-update to an upstream release, silently replacing the fork. A plain unit
# running our own build is immune: per docs/internals/server-updates.md,
# "Foreground CLI processes do not self-update".
#
# Usage: deploy-hermes-server.sh <tarball> [ssh-host]
set -euo pipefail

TARBALL="${1:?usage: deploy-hermes-server.sh <path-to-t3-*.tgz> [ssh-host]}"
HOST="${2:-hermes}"
PORT="${T3_PORT:-3737}"
BIND="${T3_BIND:-0.0.0.0}"
APP_DIR="t3code-hermes/app"
UNIT="t3code-hermes.service"
SRC_SHA="${T3_SRC_SHA:-$(git -C "${T3_WORKTREE:-$HOME/projects/t3code-hermes}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

[ -f "$TARBALL" ] || { echo "no such tarball: $TARBALL" >&2; exit 1; }

echo "[deploy] shipping $(basename "$TARBALL") to ${HOST}…"
scp -q "$TARBALL" "${HOST}:/tmp/t3-hermes-deploy.tgz"

echo "[deploy] installing on ${HOST}…"
ssh "$HOST" PORT="$PORT" BIND="$BIND" APP_DIR="$APP_DIR" UNIT="$UNIT" SRC_SHA="$SRC_SHA" 'bash -seuo pipefail' <<'REMOTE'
mkdir -p "$HOME/$APP_DIR"
# Installs the fork bundle plus its external native deps (node-pty, msgpackr-extract, …)
npm install --prefix "$HOME/$APP_DIR" --no-fund --no-audit --loglevel=error /tmp/t3-hermes-deploy.tgz
rm -f /tmp/t3-hermes-deploy.tgz

ENTRY="$HOME/$APP_DIR/node_modules/t3/dist/bin.mjs"
[ -f "$ENTRY" ] || { echo "install failed: $ENTRY missing" >&2; exit 1; }

cat > "$HOME/t3code-hermes/BUILD_INFO" <<INFO
source   = raman325/t3code feat/hermes-acp-provider @ ${SRC_SHA}
deployed = $(date -Iseconds)
entry    = ${ENTRY}
note     = Hermes-enabled fork. Do NOT run \`t3 service install\`; it would
           npm-install the upstream package over this deployment.
INFO

mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/$UNIT" <<UNITFILE
[Unit]
Description=T3 Code server (Hermes fork)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v node) ${ENTRY} serve --port ${PORT} --host ${BIND}
WorkingDirectory=%h
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
UNITFILE

loginctl enable-linger "$USER" >/dev/null 2>&1 || true
systemctl --user daemon-reload
systemctl --user enable --now "$UNIT"
sleep 3
systemctl --user --no-pager --lines=0 status "$UNIT" | head -5
REMOTE

echo
echo "[deploy] done. Next steps:"
echo "  logs:    ssh ${HOST} journalctl --user -u ${UNIT} -f"
echo "  pair:    ssh ${HOST} '~/${APP_DIR}/node_modules/.bin/t3 pair'"
echo "  connect: ssh -t ${HOST} '~/${APP_DIR}/node_modules/.bin/t3 connect login'"
