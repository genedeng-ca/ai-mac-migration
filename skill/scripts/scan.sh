#!/bin/bash
# Mac Migration Scanner
# Comprehensive scan of a Mac system, outputs JSON summary.
# Usage: ./scan.sh [--json]
#
# Designed to be run on the SOURCE Mac (the one you're migrating FROM).
# Can be invoked locally or via SSH: ssh user@source "/tmp/scan.sh --json"

set -euo pipefail

JSON_MODE=false
if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=true
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

count_files() {
  find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

dir_size_bytes() {
  du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
}

dir_size_human() {
  du -sh "$1" 2>/dev/null | cut -f1
}

# ── System Info ──────────────────────────────────────────────────────────────

HOSTNAME=$(hostname)
OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
BUILD=$(sw_vers -buildVersion 2>/dev/null || echo "unknown")
ARCH=$(uname -m)
CPU=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
RAM_GB=$(( RAM_BYTES / 1073741824 ))

# ── Disk Info ────────────────────────────────────────────────────────────────

DISK_TOTAL=$(diskutil info / 2>/dev/null | grep "Container Total Space" | awk -F': ' '{print $2}' | xargs)
DISK_FREE=$(diskutil info / 2>/dev/null | grep "Container Free Space" | awk -F': ' '{print $2}' | xargs)
if [[ -z "$DISK_TOTAL" ]]; then
  DISK_TOTAL=$(df -h / | tail -1 | awk '{print $2}')
  DISK_FREE=$(df -h / | tail -1 | awk '{print $4}')
fi
HOME_SIZE=$(dir_size_human "$HOME")

# ── Applications ─────────────────────────────────────────────────────────────

APP_COUNT_SYSTEM=0
APP_COUNT_USER=0
INTEL_APPS=0
ARM_APPS=0
UNIVERSAL_APPS=0
UNKNOWN_APPS=0
INTEL_APP_LIST=""
APP_TOTAL_SIZE=0

scan_apps() {
  local dir="$1"
  local count_var="$2"

  for app in "$dir"/*.app; do
    [[ -d "$app" ]] || continue
    eval "$count_var=\$(( $count_var + 1 ))"

    local name
    name=$(basename "$app")
    local binary
    binary=$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)
    local arch_info="unknown"

    if [[ -n "$binary" ]] && [[ -f "$app/Contents/MacOS/$binary" ]]; then
      arch_info=$(lipo -info "$app/Contents/MacOS/$binary" 2>/dev/null | sed 's/.*: //' || echo "unknown")
    fi

    case "$arch_info" in
      *arm64*x86_64*|*x86_64*arm64*) UNIVERSAL_APPS=$((UNIVERSAL_APPS + 1)) ;;
      *arm64*)                        ARM_APPS=$((ARM_APPS + 1)) ;;
      *x86_64*)                       INTEL_APPS=$((INTEL_APPS + 1))
                                      INTEL_APP_LIST="${INTEL_APP_LIST}${name}\n" ;;
      *)                              UNKNOWN_APPS=$((UNKNOWN_APPS + 1)) ;;
    esac

    local app_size
    app_size=$(dir_size_bytes "$app")
    APP_TOTAL_SIZE=$((APP_TOTAL_SIZE + app_size))
  done
}

scan_apps "/Applications" "APP_COUNT_SYSTEM"
scan_apps "$HOME/Applications" "APP_COUNT_USER"
APP_COUNT_TOTAL=$((APP_COUNT_SYSTEM + APP_COUNT_USER))
APP_TOTAL_SIZE_HUMAN=$(echo "$APP_TOTAL_SIZE" | awk '{printf "%.1f GB", $1/1073741824}')

# ── Homebrew ─────────────────────────────────────────────────────────────────

BREW_PREFIX=""
BREW_FORMULAE=0
BREW_CASKS=0
BREW_FORMULAE_LIST=""
BREW_CASK_LIST=""

if command -v brew &>/dev/null; then
  BREW_PREFIX=$(brew --prefix)
  BREW_FORMULAE_LIST=$(brew list --formula 2>/dev/null || true)
  BREW_CASK_LIST=$(brew list --cask 2>/dev/null || true)
  BREW_FORMULAE=$(echo "$BREW_FORMULAE_LIST" | grep -c . || true)
  BREW_CASKS=$(echo "$BREW_CASK_LIST" | grep -c . || true)
fi

# ── Package Managers ─────────────────────────────────────────────────────────

NPM_GLOBALS=0
if command -v npm &>/dev/null; then
  NPM_GLOBALS=$(npm list -g --depth=0 2>/dev/null | tail -n +2 | grep -c . || true)
fi

PIP_PACKAGES=0
if command -v pip3 &>/dev/null; then
  PIP_PACKAGES=$(pip3 list 2>/dev/null | tail -n +3 | grep -c . || true)
fi

PYENV_VERSIONS=0
if [[ -d "$HOME/.pyenv/versions" ]]; then
  PYENV_VERSIONS=$(ls "$HOME/.pyenv/versions/" 2>/dev/null | grep -c . || true)
fi

# ── SSH Keys ─────────────────────────────────────────────────────────────────

SSH_KEYS=""
SSH_KEY_COUNT=0
if [[ -d "$HOME/.ssh" ]]; then
  SSH_KEYS=$(ls "$HOME/.ssh/" 2>/dev/null | grep -v '.pub$' | grep -v 'known_hosts' | grep -v 'config' | grep -v 'authorized_keys' | grep -v 'agent' || true)
  SSH_KEY_COUNT=$(echo "$SSH_KEYS" | grep -c . || true)
  SSH_HAS_CONFIG="false"
  [[ -f "$HOME/.ssh/config" ]] && SSH_HAS_CONFIG="true"
fi

# ── LaunchAgents ─────────────────────────────────────────────────────────────

LAUNCH_AGENTS=""
LAUNCH_AGENT_COUNT=0
if [[ -d "$HOME/Library/LaunchAgents" ]]; then
  LAUNCH_AGENTS=$(ls "$HOME/Library/LaunchAgents/" 2>/dev/null || true)
  LAUNCH_AGENT_COUNT=$(echo "$LAUNCH_AGENTS" | grep -c . || true)
fi

# ── Large Directories ────────────────────────────────────────────────────────

LARGE_DIRS=""
for d in Desktop Documents Downloads Music Pictures Movies \
         "Virtual Machines" Parallels \
         .docker .vagrant .npm .cache .local .rustup .cargo .pyenv .conda .gradle .m2 .cocoapods \
         "Library/Application Support" "Library/Caches"; do
  full="$HOME/$d"
  if [[ -d "$full" ]]; then
    size_kb=$(du -sk "$full" 2>/dev/null | awk '{print $1}')
    if [[ -n "$size_kb" ]] && [[ "$size_kb" -gt 1048576 ]]; then  # > 1GB
      size_human=$(dir_size_human "$full")
      LARGE_DIRS="${LARGE_DIRS}  ${d}: ${size_human}\n"
    fi
  fi
done

# ── Virtual Machines ─────────────────────────────────────────────────────────

VM_COUNT=0
VM_LIST=""
for pattern in "Virtual Machines" "Parallels"; do
  if [[ -d "$HOME/$pattern" ]]; then
    count=$(ls "$HOME/$pattern/" 2>/dev/null | grep -c . || true)
    VM_COUNT=$((VM_COUNT + count))
  fi
done
VM_FILES=$(find "$HOME" -maxdepth 3 \( -name "*.vmx" -o -name "*.vmdk" -o -name "*.qcow2" \) 2>/dev/null | head -20 || true)
if [[ -n "$VM_FILES" ]]; then
  VM_COUNT=$((VM_COUNT + $(echo "$VM_FILES" | grep -c "\.vmx$" || true)))
fi

# ── Photo Library ────────────────────────────────────────────────────────────

PHOTO_LIB_SIZE="not found"
PHOTO_COUNT=0
if [[ -d "$HOME/Pictures/Photos Library.photoslibrary" ]]; then
  PHOTO_LIB_SIZE=$(dir_size_human "$HOME/Pictures/Photos Library.photoslibrary")
fi
PHOTO_COUNT=$(find "$HOME/Pictures" -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.heic" -o -name "*.mov" -o -name "*.mp4" -o -name "*.HEIC" -o -name "*.JPG" -o -name "*.PNG" \) 2>/dev/null | wc -l | tr -d ' ')

# ── Shell Configs ────────────────────────────────────────────────────────────

SHELL_CONFIGS=""
for f in .zshrc .bashrc .zprofile .bash_profile .zshenv; do
  if [[ -f "$HOME/$f" ]]; then
    lines=$(wc -l < "$HOME/$f" | tr -d ' ')
    SHELL_CONFIGS="${SHELL_CONFIGS}  $f ($lines lines)\n"
  fi
done

# ── Output ───────────────────────────────────────────────────────────────────

if $JSON_MODE; then
  cat <<ENDJSON
{
  "scan_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "system": {
    "hostname": "$HOSTNAME",
    "os_version": "$OS_VERSION",
    "build": "$BUILD",
    "architecture": "$ARCH",
    "cpu": "$CPU",
    "ram_gb": $RAM_GB
  },
  "disk": {
    "total": "$DISK_TOTAL",
    "free": "$DISK_FREE",
    "home_size": "$HOME_SIZE"
  },
  "applications": {
    "total": $APP_COUNT_TOTAL,
    "system_apps": $APP_COUNT_SYSTEM,
    "user_apps": $APP_COUNT_USER,
    "arm64": $ARM_APPS,
    "universal": $UNIVERSAL_APPS,
    "intel_only": $INTEL_APPS,
    "unknown_arch": $UNKNOWN_APPS,
    "total_size": "$APP_TOTAL_SIZE_HUMAN"
  },
  "homebrew": {
    "prefix": "$BREW_PREFIX",
    "formulae_count": $BREW_FORMULAE,
    "cask_count": $BREW_CASKS
  },
  "packages": {
    "npm_globals": $NPM_GLOBALS,
    "pip_packages": $PIP_PACKAGES,
    "pyenv_versions": $PYENV_VERSIONS
  },
  "ssh": {
    "key_count": $SSH_KEY_COUNT,
    "has_config": ${SSH_HAS_CONFIG:-false}
  },
  "launch_agents": $LAUNCH_AGENT_COUNT,
  "virtual_machines": $VM_COUNT,
  "photos": {
    "library_size": "$PHOTO_LIB_SIZE",
    "media_file_count": $PHOTO_COUNT
  }
}
ENDJSON
else
  echo "============================================"
  echo "  Mac Migration Scan Report"
  echo "  $(date)"
  echo "============================================"
  echo ""
  echo "SYSTEM"
  echo "  Hostname:     $HOSTNAME"
  echo "  macOS:        $OS_VERSION ($BUILD)"
  echo "  Architecture: $ARCH"
  echo "  CPU:          $CPU"
  echo "  RAM:          ${RAM_GB} GB"
  echo ""
  echo "DISK"
  echo "  Total:     $DISK_TOTAL"
  echo "  Free:      $DISK_FREE"
  echo "  Home dir:  $HOME_SIZE"
  echo ""
  echo "APPLICATIONS ($APP_COUNT_TOTAL total, $APP_TOTAL_SIZE_HUMAN)"
  echo "  System (/Applications):  $APP_COUNT_SYSTEM"
  echo "  User (~/Applications):   $APP_COUNT_USER"
  echo "  ARM (native):            $ARM_APPS"
  echo "  Universal:               $UNIVERSAL_APPS"
  echo "  Intel-only:              $INTEL_APPS"
  echo "  Unknown:                 $UNKNOWN_APPS"
  if [[ -n "$INTEL_APP_LIST" ]]; then
    echo ""
    echo "  Intel-only apps (need Rosetta or replacement):"
    echo -e "$INTEL_APP_LIST" | sed 's/^/    - /'
  fi
  echo ""
  echo "HOMEBREW"
  echo "  Prefix:   $BREW_PREFIX"
  echo "  Formulae: $BREW_FORMULAE"
  echo "  Casks:    $BREW_CASKS"
  echo ""
  echo "PACKAGE MANAGERS"
  echo "  npm globals:     $NPM_GLOBALS"
  echo "  pip packages:    $PIP_PACKAGES"
  echo "  pyenv versions:  $PYENV_VERSIONS"
  echo ""
  echo "SSH KEYS ($SSH_KEY_COUNT)"
  if [[ -n "$SSH_KEYS" ]]; then
    echo "$SSH_KEYS" | sed 's/^/    /'
  fi
  echo "  Has config: ${SSH_HAS_CONFIG:-false}"
  echo ""
  echo "LAUNCH AGENTS ($LAUNCH_AGENT_COUNT)"
  if [[ -n "$LAUNCH_AGENTS" ]]; then
    echo "$LAUNCH_AGENTS" | sed 's/^/    /'
  fi
  echo ""
  echo "SHELL CONFIGS"
  echo -e "$SHELL_CONFIGS"
  echo ""
  echo "LARGE DIRECTORIES (>1 GB)"
  if [[ -n "$LARGE_DIRS" ]]; then
    echo -e "$LARGE_DIRS"
  else
    echo "  (none over 1 GB)"
  fi
  echo ""
  echo "VIRTUAL MACHINES: $VM_COUNT found"
  echo ""
  echo "PHOTOS"
  echo "  Library size:    $PHOTO_LIB_SIZE"
  echo "  Media files:     $PHOTO_COUNT"
  echo ""
  echo "============================================"
  echo "  Scan complete. Ready for migration planning."
  echo "============================================"
fi
