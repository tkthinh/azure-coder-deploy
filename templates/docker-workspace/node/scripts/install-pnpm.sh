#!/bin/sh
set -eu
########################################
# Enable pnpm the robust way (Corepack)
########################################
# Node 16+ ships Corepack; Node 24 definitely does.
if command -v corepack >/dev/null 2>&1; then
  echo "[bootstrap] enabling pnpm via corepack"
  corepack enable
  corepack prepare pnpm@latest --activate
else
  echo "[bootstrap] corepack not found; falling back to user-local npm"
  npm config set prefix "$HOME/.npm-global"
  export PATH="$HOME/.npm-global/bin:$PATH"
  npm i -g pnpm
fi

########################################
# Pre-seed common global tools (optional)
########################################
if command -v pnpm >/dev/null 2>&1; then
  echo "[bootstrap] pnpm version: $(pnpm -v)"
fi

echo "[pnpm] Done."