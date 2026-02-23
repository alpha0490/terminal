#!/usr/bin/env bash
set -euo pipefail

# =========================
# Terminal Setup v1
# =========================

SCRIPT_NAME="terminal-setup"
BASE_DIR="${HOME}/.terminal-setup"
PLUGINS_DIR="${BASE_DIR}/plugins"
BACKUP_DIR="${BASE_DIR}/backups"
MANIFEST_FILE="${BASE_DIR}/manifest.env"
ZSHRC_FILE="${HOME}/.zshrc"
MANAGED_START="# >>> terminal-setup managed block >>>"
MANAGED_END="# <<< terminal-setup managed block <<<"

# Defaults
DEFAULT_USE_STARSHIP="yes"
DEFAULT_USE_TMUX="yes"

# -------------------------
# Logging helpers
# -------------------------
log()  { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR ]\033[0m %s\n" "$*" >&2; }
ok()   { printf "\033[1;32m[OK  ]\033[0m %s\n" "$*"; }

# -------------------------
# Global runtime state
# -------------------------
PKG_MANAGER=""
INSTALL_CMD=""
REMOVE_CMD=""
UPDATE_CMD=""
SUDO_CMD=""
OS_NAME="$(uname -s)"

PACKAGES_INSTALLED=()
PLUGINS_CLONED=()
FILES_BACKED_UP=()
FILES_MODIFIED=()
OLD_SHELL=""
CHANGED_DEFAULT_SHELL="no"
OHMYZSH_INSTALLED_BY_SCRIPT="no"

# -------------------------
# Utils
# -------------------------
ensure_dirs() {
  mkdir -p "${BASE_DIR}" "${PLUGINS_DIR}" "${BACKUP_DIR}"
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

append_unique_array() {
  # append_unique_array "array_name" "value"
  local arr_name="$1"
  local value="$2"
  eval "local current=(\"\${${arr_name}[@]-}\")"
  for item in "${current[@]-}"; do
    [[ "$item" == "$value" ]] && return 0
  done
  eval "${arr_name}+=(\"\$value\")"
}

join_by() {
  local IFS="$1"
  shift
  echo "$*"
}

prompt_yes_no() {
  local msg="$1"
  local default="${2:-yes}" # yes or no
  local prompt="[y/N]"
  [[ "$default" == "yes" ]] && prompt="[Y/n]"

  while true; do
    read -r -p "${msg} ${prompt}: " ans || true
    ans="${ans:-}"
    if [[ -z "$ans" ]]; then
      [[ "$default" == "yes" ]] && return 0 || return 1
    fi

    local ans_lc
    ans_lc="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"

    case "$ans_lc" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please enter y or n." ;;
    esac
  done
}

# -------------------------
# Package manager detection
# -------------------------
detect_package_manager() {
  if command_exists brew; then
    PKG_MANAGER="brew"
    INSTALL_CMD="brew install"
    REMOVE_CMD="brew uninstall"
    UPDATE_CMD="brew update"
    SUDO_CMD=""
  elif command_exists apt-get; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt-get install -y"
    REMOVE_CMD="apt-get remove -y"
    UPDATE_CMD="apt-get update"
    SUDO_CMD="sudo"
  elif command_exists dnf; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    REMOVE_CMD="dnf remove -y"
    UPDATE_CMD="dnf makecache"
    SUDO_CMD="sudo"
  elif command_exists pacman; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
    REMOVE_CMD="pacman -R --noconfirm"
    UPDATE_CMD="pacman -Sy"
    SUDO_CMD="sudo"
  else
    err "No supported package manager found (brew/apt/dnf/pacman)."
    exit 1
  fi

  ok "Detected package manager: ${PKG_MANAGER}"
}

pkg_update() {
  log "Updating package metadata..."
  if [[ -n "${SUDO_CMD}" ]]; then
    ${SUDO_CMD} ${UPDATE_CMD}
  else
    ${UPDATE_CMD}
  fi
}

pkg_install() {
  local pkg="$1"

  # Quick already-installed checks
  case "${PKG_MANAGER}" in
    brew)
      if brew list --formula "$pkg" >/dev/null 2>&1 || brew list --cask "$pkg" >/dev/null 2>&1; then
        warn "Package already installed: ${pkg}"
        return 0
      fi
      ;;
    apt)
      if dpkg -s "$pkg" >/dev/null 2>&1; then
        warn "Package already installed: ${pkg}"
        return 0
      fi
      ;;
    dnf)
      if rpm -q "$pkg" >/dev/null 2>&1; then
        warn "Package already installed: ${pkg}"
        return 0
      fi
      ;;
    pacman)
      if pacman -Q "$pkg" >/dev/null 2>&1; then
        warn "Package already installed: ${pkg}"
        return 0
      fi
      ;;
  esac

  log "Installing package: ${pkg}"
  if [[ -n "${SUDO_CMD}" ]]; then
    ${SUDO_CMD} ${INSTALL_CMD} "$pkg"
  else
    ${INSTALL_CMD} "$pkg"
  fi

  append_unique_array PACKAGES_INSTALLED "$pkg"
}

pkg_remove_if_installed() {
  local pkg="$1"
  case "${PKG_MANAGER}" in
    brew)
      if brew list --formula "$pkg" >/dev/null 2>&1 || brew list --cask "$pkg" >/dev/null 2>&1; then
        log "Removing package: ${pkg}"
        ${REMOVE_CMD} "$pkg" || warn "Failed to remove ${pkg}"
      fi
      ;;
    apt)
      if dpkg -s "$pkg" >/dev/null 2>&1; then
        log "Removing package: ${pkg}"
        ${SUDO_CMD} ${REMOVE_CMD} "$pkg" || warn "Failed to remove ${pkg}"
      fi
      ;;
    dnf)
      if rpm -q "$pkg" >/dev/null 2>&1; then
        log "Removing package: ${pkg}"
        ${SUDO_CMD} ${REMOVE_CMD} "$pkg" || warn "Failed to remove ${pkg}"
      fi
      ;;
    pacman)
      if pacman -Q "$pkg" >/dev/null 2>&1; then
        log "Removing package: ${pkg}"
        ${SUDO_CMD} ${REMOVE_CMD} "$pkg" || warn "Failed to remove ${pkg}"
      fi
      ;;
  esac
}

# -------------------------
# Config backup / restore
# -------------------------
backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local dst="${BACKUP_DIR}/$(basename "$src").$(timestamp).bak"
  cp "$src" "$dst"
  append_unique_array FILES_BACKED_UP "${src}|${dst}"
  ok "Backed up $(basename "$src") -> $dst"
}

# -------------------------
# Manifest
# -------------------------
write_manifest() {
  local ts
  ts="$(timestamp)"

  {
    printf 'MANIFEST_VERSION=%q\n' "1"
    printf 'CREATED_AT=%q\n' "${ts}"
    printf 'OS_NAME=%q\n' "${OS_NAME}"
    printf 'PKG_MANAGER=%q\n' "${PKG_MANAGER}"
    printf 'OLD_SHELL=%q\n' "${OLD_SHELL}"
    printf 'CHANGED_DEFAULT_SHELL=%q\n' "${CHANGED_DEFAULT_SHELL}"
    printf 'OHMYZSH_INSTALLED_BY_SCRIPT=%q\n' "${OHMYZSH_INSTALLED_BY_SCRIPT}"
    printf 'PACKAGES_INSTALLED=%q\n' "$(join_by ',' "${PACKAGES_INSTALLED[@]-}")"
    printf 'PLUGINS_CLONED=%q\n' "$(join_by ',' "${PLUGINS_CLONED[@]-}")"
    printf 'FILES_BACKED_UP=%q\n' "$(join_by ';' "${FILES_BACKED_UP[@]-}")"
    printf 'FILES_MODIFIED=%q\n' "$(join_by ',' "${FILES_MODIFIED[@]-}")"
  } > "${MANIFEST_FILE}"

  ok "Manifest written: ${MANIFEST_FILE}"
}

load_manifest() {
  if [[ ! -f "${MANIFEST_FILE}" ]]; then
    err "No manifest found at ${MANIFEST_FILE}. Nothing to revert/status."
    return 1
  fi

  # shellcheck disable=SC1090
  source "${MANIFEST_FILE}"
  return 0
}

# -------------------------
# Zsh / Oh My Zsh
# -------------------------
install_zsh_if_needed() {
  if command_exists zsh; then
    ok "zsh already installed"
    return
  fi

  case "${PKG_MANAGER}" in
    apt|dnf|pacman|brew) pkg_install zsh ;;
    *) err "Unsupported package manager for zsh install"; exit 1 ;;
  esac
}

install_oh_my_zsh_if_needed() {
  if [[ -d "${HOME}/.oh-my-zsh" ]]; then
    warn "Oh My Zsh already exists at ~/.oh-my-zsh"
    return
  fi

  if ! command_exists curl; then
    pkg_install curl
  fi
  if ! command_exists git; then
    pkg_install git
  fi

  log "Installing Oh My Zsh (unattended)..."
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

  OHMYZSH_INSTALLED_BY_SCRIPT="yes"
  ok "Oh My Zsh installed"
}

clone_plugin() {
  local name="$1"
  local repo="$2"
  local dest="${PLUGINS_DIR}/${name}"

  if [[ -d "${dest}" ]]; then
    warn "Plugin already exists: ${name}"
    return
  fi

  log "Cloning ${name}..."
  git clone --depth=1 "${repo}" "${dest}"
  append_unique_array PLUGINS_CLONED "${dest}"
  ok "Installed plugin: ${name}"
}

# -------------------------
# .zshrc managed block
# -------------------------
remove_managed_block_from_zshrc() {
  [[ -f "${ZSHRC_FILE}" ]] || return 0

  if grep -qF "${MANAGED_START}" "${ZSHRC_FILE}"; then
    log "Removing existing managed block from ${ZSHRC_FILE}"
    awk -v start="${MANAGED_START}" -v end="${MANAGED_END}" '
      $0 == start {inblock=1; next}
      $0 == end   {inblock=0; next}
      !inblock {print}
    ' "${ZSHRC_FILE}" > "${ZSHRC_FILE}.tmp"
    mv "${ZSHRC_FILE}.tmp" "${ZSHRC_FILE}"
  fi
}

write_managed_block_to_zshrc() {
  local use_autocomplete="$1"
  local use_autosuggestions="$2"
  local use_syntax_highlighting="$3"
  local use_starship="$4"
  local use_fzf="$5"
  local use_zoxide="$6"
  local use_direnv="$7"
  local use_atuin="$8"

  touch "${ZSHRC_FILE}"
  remove_managed_block_from_zshrc

  cat >> "${ZSHRC_FILE}" <<EOF

${MANAGED_START}
# Generated by ${SCRIPT_NAME}

export TERMINAL_SETUP_HOME="${BASE_DIR}"

# Oh My Zsh base path (if installed)
export ZSH="\$HOME/.oh-my-zsh"

# Source Oh My Zsh if present
if [ -s "\$ZSH/oh-my-zsh.sh" ]; then
  plugins=(git)
  source "\$ZSH/oh-my-zsh.sh"
fi

EOF

  if [[ "${use_autocomplete}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# zsh-autocomplete (should be sourced early)
if [ -f "$TERMINAL_SETUP_HOME/plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh" ]; then
  source "$TERMINAL_SETUP_HOME/plugins/zsh-autocomplete/zsh-autocomplete.plugin.zsh"
fi

EOF
  fi

  if [[ "${use_autosuggestions}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# zsh-autosuggestions
if [ -f "$TERMINAL_SETUP_HOME/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]; then
  source "$TERMINAL_SETUP_HOME/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

EOF
  fi

  if [[ "${use_syntax_highlighting}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# zsh-syntax-highlighting (usually near end of zshrc)
if [ -f "$TERMINAL_SETUP_HOME/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]; then
  source "$TERMINAL_SETUP_HOME/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

EOF
  fi

  if [[ "${use_fzf}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# fzf shell integration
if command -v fzf >/dev/null 2>&1; then
  if [ -f ~/.fzf.zsh ]; then
    source ~/.fzf.zsh
  elif [ -f /usr/share/fzf/key-bindings.zsh ]; then
    source /usr/share/fzf/key-bindings.zsh
    [ -f /usr/share/fzf/completion.zsh ] && source /usr/share/fzf/completion.zsh
  fi
fi

EOF
  fi

  if [[ "${use_zoxide}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# zoxide init
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

EOF
  fi

  if [[ "${use_direnv}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# direnv init
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook zsh)"
fi

EOF
  fi

  if [[ "${use_atuin}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# atuin init
if command -v atuin >/dev/null 2>&1; then
  eval "$(atuin init zsh --disable-up-arrow)"
fi

EOF
  fi

  if [[ "${use_starship}" == "yes" ]]; then
    cat >> "${ZSHRC_FILE}" <<'EOF'
# starship prompt
if command -v starship >/dev/null 2>&1; then
  eval "$(starship init zsh)"
fi

EOF
  else
    cat >> "${ZSHRC_FILE}" <<'EOF'
# Using default Oh My Zsh theme (Starship not enabled)
EOF
  fi

  cat >> "${ZSHRC_FILE}" <<'EOF'
# Helpful aliases (safe defaults)
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -la --group-directories-first --icons=auto'
else
  alias ll='ls -la'
fi

if command -v bat >/dev/null 2>&1; then
  alias cat='bat --paging=never'
elif command -v batcat >/dev/null 2>&1; then
  alias cat='batcat --paging=never'
fi

EOF

  cat >> "${ZSHRC_FILE}" <<EOF
${MANAGED_END}
EOF

  append_unique_array FILES_MODIFIED "${ZSHRC_FILE}"
  ok "Updated ${ZSHRC_FILE} with managed block"
}

change_default_shell_to_zsh() {
  local zsh_path
  zsh_path="$(command -v zsh || true)"
  [[ -n "${zsh_path}" ]] || { err "zsh not found"; return 1; }

  OLD_SHELL="${SHELL:-}"
  if [[ "${SHELL:-}" == "${zsh_path}" ]]; then
    ok "Default shell already zsh"
    return 0
  fi

  log "Changing default shell to zsh (${zsh_path})"
  chsh -s "${zsh_path}" || {
    warn "Failed to change default shell automatically. You can run: chsh -s ${zsh_path}"
    return 1
  }
  CHANGED_DEFAULT_SHELL="yes"
  ok "Default shell changed to zsh"
}

restore_default_shell_if_changed() {
  if [[ "${CHANGED_DEFAULT_SHELL:-no}" != "yes" ]]; then
    return 0
  fi
  if [[ -z "${OLD_SHELL:-}" ]]; then
    warn "No OLD_SHELL recorded; skipping shell restore"
    return 0
  fi
  if [[ ! -x "${OLD_SHELL}" ]]; then
    warn "Recorded OLD_SHELL not executable: ${OLD_SHELL}"
    return 0
  fi

  log "Restoring default shell to ${OLD_SHELL}"
  chsh -s "${OLD_SHELL}" || warn "Failed to restore default shell. You may need: chsh -s ${OLD_SHELL}"
}

# -------------------------
# Interactive menu
# -------------------------
ask_tool_selection() {
  USE_OHMYZSH="yes"
  USE_AUTOCOMPLETE="yes"
  USE_AUTOSUGGESTIONS="yes"
  USE_SYNTAX_HIGHLIGHTING="yes"

  USE_FZF="yes"
  USE_ZOXIDE="yes"
  USE_EZA="yes"
  USE_BAT="yes"
  USE_RG="yes"
  USE_FD="yes"
  USE_JQ="yes"
  USE_DIRENV="yes"
  USE_ATUIN="yes"

  USE_STARSHIP="${DEFAULT_USE_STARSHIP}"
  USE_TMUX="${DEFAULT_USE_TMUX}"
  CHANGE_SHELL="no"

  echo
  log "Interactive setup (press Enter for defaults)"
  echo

  prompt_yes_no "Backup ~/.zshrc before making changes?" "yes" && DO_BACKUP="yes" || DO_BACKUP="no"
  prompt_yes_no "Install Oh My Zsh?" "yes" && USE_OHMYZSH="yes" || USE_OHMYZSH="no"

  echo
  log "Zsh plugins"
  prompt_yes_no "Install zsh-autocomplete?" "yes" && USE_AUTOCOMPLETE="yes" || USE_AUTOCOMPLETE="no"
  prompt_yes_no "Install zsh-autosuggestions?" "yes" && USE_AUTOSUGGESTIONS="yes" || USE_AUTOSUGGESTIONS="no"
  prompt_yes_no "Install zsh-syntax-highlighting?" "yes" && USE_SYNTAX_HIGHLIGHTING="yes" || USE_SYNTAX_HIGHLIGHTING="no"

  echo
  log "CLI productivity tools"
  prompt_yes_no "Install fzf?" "yes" && USE_FZF="yes" || USE_FZF="no"
  prompt_yes_no "Install zoxide?" "yes" && USE_ZOXIDE="yes" || USE_ZOXIDE="no"
  prompt_yes_no "Install eza?" "yes" && USE_EZA="yes" || USE_EZA="no"
  prompt_yes_no "Install bat?" "yes" && USE_BAT="yes" || USE_BAT="no"
  prompt_yes_no "Install ripgrep (rg)?" "yes" && USE_RG="yes" || USE_RG="no"
  prompt_yes_no "Install fd?" "yes" && USE_FD="yes" || USE_FD="no"
  prompt_yes_no "Install jq?" "yes" && USE_JQ="yes" || USE_JQ="no"
  prompt_yes_no "Install direnv?" "yes" && USE_DIRENV="yes" || USE_DIRENV="no"
  prompt_yes_no "Install atuin?" "yes" && USE_ATUIN="yes" || USE_ATUIN="no"

  echo
  log "Prompt"
  prompt_yes_no "Use Starship prompt (recommended)?" "${DEFAULT_USE_STARSHIP}" && USE_STARSHIP="yes" || USE_STARSHIP="no"

  echo
  log "Session manager"
  prompt_yes_no "Install tmux?" "${DEFAULT_USE_TMUX}" && USE_TMUX="yes" || USE_TMUX="no"

  echo
  prompt_yes_no "Change default shell to zsh?" "no" && CHANGE_SHELL="yes" || CHANGE_SHELL="no"

  echo
  log "Summary"
  echo "  Oh My Zsh:               ${USE_OHMYZSH}"
  echo "  zsh-autocomplete:        ${USE_AUTOCOMPLETE}"
  echo "  zsh-autosuggestions:     ${USE_AUTOSUGGESTIONS}"
  echo "  zsh-syntax-highlighting: ${USE_SYNTAX_HIGHLIGHTING}"
  echo "  fzf:                     ${USE_FZF}"
  echo "  zoxide:                  ${USE_ZOXIDE}"
  echo "  eza:                     ${USE_EZA}"
  echo "  bat:                     ${USE_BAT}"
  echo "  ripgrep:                 ${USE_RG}"
  echo "  fd:                      ${USE_FD}"
  echo "  jq:                      ${USE_JQ}"
  echo "  direnv:                  ${USE_DIRENV}"
  echo "  atuin:                   ${USE_ATUIN}"
  echo "  Starship:                ${USE_STARSHIP}"
  echo "  tmux:                    ${USE_TMUX}"
  echo "  Change shell to zsh:     ${CHANGE_SHELL}"
  echo

  prompt_yes_no "Proceed with installation?" "yes"
}

# -------------------------
# Install flow
# -------------------------
install_flow() {
  ensure_dirs
  detect_package_manager
  ask_tool_selection

  pkg_update
  pkg_install git
  pkg_install curl

  if [[ "${DO_BACKUP}" == "yes" ]]; then
    backup_file "${ZSHRC_FILE}"
  fi

  install_zsh_if_needed

  if [[ "${USE_OHMYZSH}" == "yes" ]]; then
    install_oh_my_zsh_if_needed
  fi

  # Shell plugins
  [[ "${USE_AUTOCOMPLETE}" == "yes" ]] && clone_plugin "zsh-autocomplete" "https://github.com/marlonrichert/zsh-autocomplete.git"
  [[ "${USE_AUTOSUGGESTIONS}" == "yes" ]] && clone_plugin "zsh-autosuggestions" "https://github.com/zsh-users/zsh-autosuggestions.git"
  [[ "${USE_SYNTAX_HIGHLIGHTING}" == "yes" ]] && clone_plugin "zsh-syntax-highlighting" "https://github.com/zsh-users/zsh-syntax-highlighting.git"

  # CLI tools
  [[ "${USE_FZF}" == "yes" ]] && pkg_install fzf
  [[ "${USE_ZOXIDE}" == "yes" ]] && pkg_install zoxide
  [[ "${USE_EZA}" == "yes" ]] && pkg_install eza || true

  if [[ "${USE_BAT}" == "yes" ]]; then
    if [[ "${PKG_MANAGER}" == "apt" ]]; then
      pkg_install bat || pkg_install batcat
    else
      pkg_install bat
    fi
  fi

  [[ "${USE_RG}" == "yes" ]] && pkg_install ripgrep

  if [[ "${USE_FD}" == "yes" ]]; then
    if [[ "${PKG_MANAGER}" == "apt" ]]; then
      pkg_install fd-find || pkg_install fd
    else
      pkg_install fd
    fi
  fi

  [[ "${USE_JQ}" == "yes" ]] && pkg_install jq
  [[ "${USE_DIRENV}" == "yes" ]] && pkg_install direnv
  [[ "${USE_ATUIN}" == "yes" ]] && pkg_install atuin
  [[ "${USE_STARSHIP}" == "yes" ]] && pkg_install starship
  [[ "${USE_TMUX}" == "yes" ]] && pkg_install tmux

  write_managed_block_to_zshrc \
    "${USE_AUTOCOMPLETE}" \
    "${USE_AUTOSUGGESTIONS}" \
    "${USE_SYNTAX_HIGHLIGHTING}" \
    "${USE_STARSHIP}" \
    "${USE_FZF}" \
    "${USE_ZOXIDE}" \
    "${USE_DIRENV}" \
    "${USE_ATUIN}"

  if [[ "${CHANGE_SHELL}" == "yes" ]]; then
    change_default_shell_to_zsh || true
  else
    OLD_SHELL="${SHELL:-}"
  fi

  write_manifest

  echo
  ok "Install complete."
  echo "Next steps:"
  echo "  1) Restart terminal OR run: exec zsh"
  echo "  2) Check status: ./${0##*/} status"
}

# -------------------------
# Revert flow
# -------------------------
revert_flow() {
  ensure_dirs
  detect_package_manager
  load_manifest

  echo
  warn "This will revert changes recorded in manifest."
  prompt_yes_no "Continue?" "no" || { log "Revert cancelled."; exit 0; }

  # Parse arrays from manifest strings
  IFS=',' read -r -a manifest_packages <<< "${PACKAGES_INSTALLED:-}"
  IFS=',' read -r -a manifest_plugins <<< "${PLUGINS_CLONED:-}"
  IFS=';' read -r -a manifest_backups <<< "${FILES_BACKED_UP:-}"

  # Remove managed block from .zshrc
  remove_managed_block_from_zshrc

  # Restore latest .zshrc backup if available
  local restored
  restored="no"

  local pair
  local src
  local backup

  for pair in "${manifest_backups[@]-}"; do
    [[ -z "${pair}" ]] && continue
    src="${pair%%|*}"
    backup="${pair#*|}"
    if [[ "${src}" == "${ZSHRC_FILE}" && -f "${backup}" ]]; then
      cp "${backup}" "${ZSHRC_FILE}"
      ok "Restored ${ZSHRC_FILE} from backup ${backup}"
      restored="yes"
      break
    fi
  done

  if [[ "${restored}" != "yes" ]]; then
    warn "No .zshrc backup found in manifest; left current .zshrc in place (managed block removed)."
  fi

  # Remove cloned plugins
  local p
  for p in "${manifest_plugins[@]-}"; do
    [[ -z "${p}" ]] && continue
    if [[ -d "${p}" ]]; then
      rm -rf "${p}"
      ok "Removed plugin dir: ${p}"
    fi
  done

  # Remove Oh My Zsh if this script installed it
  if [[ "${OHMYZSH_INSTALLED_BY_SCRIPT:-no}" == "yes" && -d "${HOME}/.oh-my-zsh" ]]; then
    if prompt_yes_no "Remove ~/.oh-my-zsh (installed by this script)?" "yes"; then
      rm -rf "${HOME}/.oh-my-zsh"
      ok "Removed ~/.oh-my-zsh"
    fi
  fi

  # Restore default shell if changed
  restore_default_shell_if_changed || true

  # Optional package uninstall
  if prompt_yes_no "Uninstall packages installed by this script?" "no"; then
    local pkg
    for pkg in "${manifest_packages[@]-}"; do
      [[ -z "${pkg}" ]] && continue
      pkg_remove_if_installed "${pkg}"
    done
  fi

  rm -f "${MANIFEST_FILE}"
  ok "Manifest removed"

  echo
  ok "Revert complete."
}

# -------------------------
# Status flow
# -------------------------
status_flow() {
  ensure_dirs

  echo "== ${SCRIPT_NAME} status =="
  echo "Base dir:     ${BASE_DIR}"
  echo "Plugins dir:  ${PLUGINS_DIR}"
  echo "Manifest:     ${MANIFEST_FILE}"
  echo

  if [[ -f "${MANIFEST_FILE}" ]]; then
    load_manifest || true
    echo "Manifest present: yes"
    echo "Created at:        ${CREATED_AT:-unknown}"
    echo "OS:                ${OS_NAME:-unknown}"
    echo "Pkg manager:       ${PKG_MANAGER:-unknown}"
    echo "Changed shell:     ${CHANGED_DEFAULT_SHELL:-unknown}"
    echo "Old shell:         ${OLD_SHELL:-unknown}"
    echo "Packages:          ${PACKAGES_INSTALLED:-}"
    echo "Plugins:           ${PLUGINS_CLONED:-}"
  else
    echo "Manifest present: no"
  fi

  echo
  if [[ -f "${ZSHRC_FILE}" ]] && grep -qF "${MANAGED_START}" "${ZSHRC_FILE}"; then
    echo ".zshrc managed block: present"
  else
    echo ".zshrc managed block: not found"
  fi

  echo
  local tool
  for tool in zsh git curl fzf zoxide eza bat batcat rg ripgrep fd fd-find jq direnv atuin starship tmux; do
    if command_exists "${tool}"; then
      printf "  %-12s %s\n" "${tool}" "installed"
    fi
  done
}

# -------------------------
# Main
# -------------------------
usage() {
  cat <<EOF
Usage: ${0##*/} <install|revert|status>

Commands:
  install   Interactive install of shell tools + config
  revert    Revert changes recorded in manifest
  status    Show current setup status
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    install) install_flow ;;
    revert)  revert_flow ;;
    status)  status_flow ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
