#!/usr/bin/env bash
set -euo pipefail

THEME_NAME="quick-term"
FONT_NAME="meslo"
INSTALL_DIR="$HOME/.local/bin"

SHELL_NAME="$(basename "$SHELL")"
[ -z "$SHELL_NAME" ] && SHELL_NAME="bash"

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"; return
  elif command -v pacman >/dev/null 2>&1; then echo "pacman"; return
  else echo "none"; return
  fi
}

ensure_tools() {
  pm="$(detect_pm)"
  case "$pm" in
    apt)
      if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update -y && sudo apt-get install -y curl unzip fontconfig
      else
        apt-get update -y && apt-get install -y curl unzip fontconfig
      fi
      ;;
    dnf)
      if command -v sudo >/dev/null 2>&1; then
        sudo dnf install -y curl unzip fontconfig
      else
        dnf install -y curl unzip fontconfig
      fi
      ;;
    pacman)
      if command -v sudo >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm curl unzip fontconfig
      else
        pacman -Sy --noconfirm curl unzip fontconfig
      fi
      ;;
    *)
      echo "No supported package manager found. Ensure curl/unzip/fontconfig exist."
      ;;
  esac
}

install_omp() {
  mkdir -p "$INSTALL_DIR"
  curl -fsSL https://ohmyposh.dev/install.sh | bash -s -- -d "$INSTALL_DIR"
  export PATH="$INSTALL_DIR:$PATH"
  command -v oh-my-posh >/dev/null || { echo "oh-my-posh not found on PATH." >&2; exit 1; }
}

install_font() {
  oh-my-posh font install "$FONT_NAME" || true
  fc-cache -fv >/dev/null || true
}

configure_shell() {
  local rc_file init_line path_line
  case "$SHELL_NAME" in
    zsh)
      rc_file="$HOME/.zshrc"
      init_line="eval \"\$(oh-my-posh init zsh --config '$THEME_NAME')\""
      ;;
    bash|*)
      rc_file="$HOME/.bashrc"
      init_line="eval \"\$(oh-my-posh init bash --config '$THEME_NAME')\""
      ;;
  esac

  path_line='export PATH="$HOME/.local/bin:$PATH"'
  grep -Fq "$path_line" "$rc_file" 2>/dev/null || printf '\n# oh-my-posh: ensure local bin is on PATH\n%s\n' "$path_line" >> "$rc_file"
  grep -Fq "$init_line" "$rc_file" 2>/dev/null || printf '\n# oh-my-posh: init with %s theme\n%s\n' "$THEME_NAME" "$init_line" >> "$rc_file"
  eval "$init_line"
}

echo ">>> installing prerequisites"; ensure_tools
echo ">>> installing oh-my-posh to $INSTALL_DIR"; install_omp
echo ">>> installing Nerd Font ($FONT_NAME)"; install_font
echo ">>> configuring $SHELL_NAME with theme: $THEME_NAME"; configure_shell
echo "Done. Restart your terminal (or run 'exec $SHELL_NAME') and select a Nerd Font in the terminal UI."
