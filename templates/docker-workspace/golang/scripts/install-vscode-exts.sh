#!/bin/sh
# Install VS Code Desktop extensions into ~/.vscode-server/extensions
# for Go, Node.js, and Python, using the Desktop 'code' CLI.
set -eu

EXT_DIR="${HOME}/.vscode-server/extensions"
mkdir -p "${EXT_DIR}"

# Detect stacks
has_go=0
has_node=0
has_python=0

command -v go >/dev/null 2>&1 && has_go=1
command -v node >/dev/null 2>&1 && has_node=1
command -v python3 >/dev/null 2>&1 && has_python=1
[ $has_python -eq 0 ] && command -v python >/dev/null 2>&1 && has_python=1

# Extension sets (space-separated)
COMMON_EXTS="eamodio.gitlens"
GO_EXTS="golang.go"
NODE_EXTS="dbaeumer.vscode-eslint esbenp.prettier-vscode"
PY_EXTS="ms-python.python ms-python.vscode-pylance"

DESIRED="${COMMON_EXTS}"
[ $has_go -eq 1 ] && DESIRED="${DESIRED} ${GO_EXTS}"
[ $has_node -eq 1 ] && DESIRED="${DESIRED} ${NODE_EXTS}"
[ $has_python -eq 1 ] && DESIRED="${DESIRED} ${PY_EXTS}"

echo "[vscode-exts] Desired: ${DESIRED}"

# Wait for VS Code Desktop 'code' CLI (appears after first Desktop connect)
wait_for_code_cli() {
  max_wait="${1:-300}" # seconds
  slept=0
  while ! command -v code >/dev/null 2>&1; do
    if [ "${slept}" -ge "${max_wait}" ]; then
      echo "[vscode-exts] 'code' CLI not found after ${max_wait}s. Exiting gracefully."
      return 1
    fi
    if [ $((slept % 10)) -eq 0 ]; then
      echo "[vscode-exts] Waiting for VS Code Desktop server... (${slept}s)"
    fi
    sleep 2
    slept=$((slept + 2))
  done
  return 0
}

if ! wait_for_code_cli 300; then
  # Not an error—the user just hasn't opened VS Code Desktop yet.
  exit 0
fi

# Install idempotently
installed="$(code --list-extensions 2>/dev/null || true)"
for ext in ${DESIRED}; do
  echo "${installed}" | grep -qi "^${ext}\$" && { echo "[vscode-exts] Already installed: ${ext}"; continue; }
  echo "[vscode-exts] Installing: ${ext}"
  code --extensions-dir "${EXT_DIR}" --install-extension "${ext}" || echo "[vscode-exts] Failed: ${ext}"
done

echo "[vscode-exts] Done."
