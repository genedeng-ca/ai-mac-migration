#!/bin/bash
# Mac Migration Verification Script
# Run on the TARGET Mac after migration to verify everything transferred correctly.
#
# Usage: ./verify.sh SOURCE_USER@SOURCE_IP
#
# Example: ./verify.sh gene@192.168.50.42

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 USER@SOURCE_IP"
  echo "Example: $0 gene@192.168.50.42"
  exit 1
fi

SOURCE="$1"
PASS=0
WARN=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "============================================"
echo "  Post-Migration Verification"
echo "  Target: $(hostname)"
echo "  Source: $SOURCE"
echo "  $(date)"
echo "============================================"
echo ""

# ── 1. File Count Comparison ────────────────────────────────────────────────

echo "── File Count Comparison ──"
for dir in Documents Desktop Pictures Music Downloads; do
  if [[ -d "$HOME/$dir" ]]; then
    src=$(ssh "$SOURCE" "find ~/$dir -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
    dst=$(find "$HOME/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')

    if [[ -z "$src" ]] || [[ "$src" == "0" ]]; then
      warn "$dir: source empty or unreachable (source=$src, target=$dst)"
    elif [[ "$src" == "$dst" ]]; then
      pass "$dir: $dst/$src files match"
    else
      diff=$((src - dst))
      if [[ $diff -gt 0 ]]; then
        fail "$dir: MISSING $diff files (source=$src, target=$dst)"
      else
        warn "$dir: target has $((-diff)) MORE files than source (source=$src, target=$dst)"
      fi
    fi
  else
    warn "$dir: directory does not exist on target"
  fi
done
echo ""

# ── 2. Photo Verification ───────────────────────────────────────────────────

echo "── Photo Verification ──"
PHOTO_EXTENSIONS='-name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.heic" -o -name "*.HEIC" -o -name "*.JPG" -o -name "*.PNG" -o -name "*.mov" -o -name "*.mp4" -o -name "*.MOV" -o -name "*.MP4"'

src_photos=$(ssh "$SOURCE" "find ~/Pictures -type f \( $PHOTO_EXTENSIONS \) 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')
dst_photos=$(eval "find $HOME/Pictures -type f \( $PHOTO_EXTENSIONS \) 2>/dev/null | wc -l" | tr -d ' ')

if [[ -n "$src_photos" ]] && [[ "$src_photos" != "0" ]]; then
  if [[ "$src_photos" == "$dst_photos" ]]; then
    pass "Photos: $dst_photos/$src_photos media files match"
  else
    fail "Photos: MISMATCH (source=$src_photos, target=$dst_photos)"
  fi
else
  warn "Photos: source count unavailable or zero"
fi

# Photo Library size comparison
src_lib_size=$(ssh "$SOURCE" 'du -sk ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null | cut -f1' 2>/dev/null | tr -d ' ')
dst_lib_size=$(du -sk "$HOME/Pictures/Photos Library.photoslibrary" 2>/dev/null | cut -f1 | tr -d ' ')

if [[ -n "$src_lib_size" ]] && [[ -n "$dst_lib_size" ]] && [[ "$src_lib_size" != "0" ]]; then
  # Allow 1% variance for filesystem differences
  tolerance=$((src_lib_size / 100))
  diff=$((src_lib_size - dst_lib_size))
  abs_diff=${diff#-}
  if [[ $abs_diff -le $tolerance ]]; then
    pass "Photo Library: sizes match within 1% tolerance"
  else
    src_human=$(echo "$src_lib_size" | awk '{printf "%.1f GB", $1/1048576}')
    dst_human=$(echo "$dst_lib_size" | awk '{printf "%.1f GB", $1/1048576}')
    fail "Photo Library: size mismatch (source=$src_human, target=$dst_human)"
  fi
fi
echo ""

# ── 3. SSH Key Verification ─────────────────────────────────────────────────

echo "── SSH Key Verification ──"
if [[ -d "$HOME/.ssh" ]]; then
  ssh_dir_perms=$(stat -f "%Lp" "$HOME/.ssh" 2>/dev/null || stat -c "%a" "$HOME/.ssh" 2>/dev/null)
  if [[ "$ssh_dir_perms" == "700" ]]; then
    pass ".ssh directory permissions: 700"
  else
    fail ".ssh directory permissions: $ssh_dir_perms (should be 700)"
  fi

  # Check private key permissions
  for key in "$HOME"/.ssh/id_* "$HOME"/.ssh/*_key; do
    [[ -f "$key" ]] || continue
    [[ "$key" == *.pub ]] && continue

    key_perms=$(stat -f "%Lp" "$key" 2>/dev/null || stat -c "%a" "$key" 2>/dev/null)
    key_name=$(basename "$key")
    if [[ "$key_perms" == "600" ]]; then
      pass "SSH key $key_name: permissions 600"
    else
      fail "SSH key $key_name: permissions $key_perms (should be 600)"
      echo "      Fix: chmod 600 $key"
    fi
  done

  # Check SSH config exists
  if [[ -f "$HOME/.ssh/config" ]]; then
    pass "SSH config exists"
  else
    warn "No SSH config file found"
  fi

  # Test GitHub SSH
  github_test=$(ssh -o ConnectTimeout=5 -T git@github.com 2>&1 || true)
  if echo "$github_test" | grep -q "successfully authenticated"; then
    pass "GitHub SSH authentication works"
  else
    warn "GitHub SSH test inconclusive: $github_test"
  fi
else
  fail ".ssh directory not found"
fi
echo ""

# ── 4. Homebrew Verification ────────────────────────────────────────────────

echo "── Homebrew Verification ──"
if command -v brew &>/dev/null; then
  pass "Homebrew installed at $(brew --prefix)"

  brew_arch=$(brew --prefix)
  if [[ "$(uname -m)" == "arm64" ]] && [[ "$brew_arch" == "/opt/homebrew" ]]; then
    pass "Homebrew on correct ARM path (/opt/homebrew)"
  elif [[ "$(uname -m)" == "x86_64" ]] && [[ "$brew_arch" == "/usr/local" ]]; then
    pass "Homebrew on correct Intel path (/usr/local)"
  else
    warn "Homebrew path may be mismatched: $brew_arch for $(uname -m)"
  fi

  # Count packages
  local_formulae=$(brew list --formula 2>/dev/null | wc -l | tr -d ' ')
  local_casks=$(brew list --cask 2>/dev/null | wc -l | tr -d ' ')

  src_formulae=$(ssh "$SOURCE" 'brew list --formula 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')
  src_casks=$(ssh "$SOURCE" 'brew list --cask 2>/dev/null | wc -l' 2>/dev/null | tr -d ' ')

  if [[ -n "$src_formulae" ]]; then
    if [[ "$local_formulae" -ge "$src_formulae" ]]; then
      pass "Homebrew formulae: $local_formulae/$src_formulae"
    else
      warn "Homebrew formulae: $local_formulae/$src_formulae (some missing)"
    fi
  fi

  if [[ -n "$src_casks" ]]; then
    if [[ "$local_casks" -ge "$src_casks" ]]; then
      pass "Homebrew casks: $local_casks/$src_casks"
    else
      warn "Homebrew casks: $local_casks/$src_casks (some missing)"
    fi
  fi

  # Quick doctor check
  doctor_issues=$(brew doctor 2>&1 | grep -c "Warning" || true)
  if [[ "$doctor_issues" == "0" ]]; then
    pass "brew doctor: no warnings"
  else
    warn "brew doctor: $doctor_issues warnings (run 'brew doctor' for details)"
  fi
else
  fail "Homebrew not installed"
fi
echo ""

# ── 5. Developer Tools ──────────────────────────────────────────────────────

echo "── Developer Tools ──"
for cmd in git python3 node npm ruby; do
  if command -v "$cmd" &>/dev/null; then
    version=$("$cmd" --version 2>&1 | head -1)
    pass "$cmd: $version"
  else
    warn "$cmd: not found"
  fi
done

# Optional tools -- only warn if they were on source
for cmd in cargo go java docker rustc; do
  src_has=$(ssh "$SOURCE" "command -v $cmd &>/dev/null && echo yes || echo no" 2>/dev/null)
  if [[ "$src_has" == "yes" ]]; then
    if command -v "$cmd" &>/dev/null; then
      version=$("$cmd" --version 2>&1 | head -1)
      pass "$cmd: $version"
    else
      warn "$cmd: was on source but missing on target"
    fi
  fi
done
echo ""

# ── 6. Shell Config Verification ────────────────────────────────────────────

echo "── Shell Configuration ──"
for f in .zshrc .bashrc .zprofile .bash_profile .zshenv; do
  src_exists=$(ssh "$SOURCE" "[[ -f ~/$f ]] && echo yes || echo no" 2>/dev/null)
  dst_exists="no"
  [[ -f "$HOME/$f" ]] && dst_exists="yes"

  if [[ "$src_exists" == "yes" ]] && [[ "$dst_exists" == "yes" ]]; then
    pass "$f: transferred"

    # Check for Intel Homebrew paths on ARM target
    if [[ "$(uname -m)" == "arm64" ]]; then
      intel_refs=$(grep -c '/usr/local/bin\|/usr/local/opt\|/usr/local/Cellar' "$HOME/$f" 2>/dev/null || true)
      if [[ "$intel_refs" -gt 0 ]]; then
        warn "$f: contains $intel_refs Intel Homebrew path references (/usr/local) -- may need updating to /opt/homebrew"
      fi
    fi
  elif [[ "$src_exists" == "yes" ]] && [[ "$dst_exists" == "no" ]]; then
    fail "$f: exists on source but missing on target"
  fi
done
echo ""

# ── 7. Virtual Machines ─────────────────────────────────────────────────────

echo "── Virtual Machines ──"
src_vms=$(ssh "$SOURCE" 'ls ~/Virtual\ Machines/ ~/Parallels/ 2>/dev/null | grep -c . || echo 0' 2>/dev/null)
dst_vms=$(ls "$HOME/Virtual Machines/" "$HOME/Parallels/" 2>/dev/null | grep -c . || echo 0)

if [[ "$src_vms" != "0" ]]; then
  if [[ "$dst_vms" -ge "$src_vms" ]]; then
    pass "Virtual machines: $dst_vms/$src_vms transferred"
  else
    fail "Virtual machines: $dst_vms/$src_vms (some missing)"
  fi
else
  pass "No virtual machines to verify"
fi
echo ""

# ── 8. LaunchAgents ──────────────────────────────────────────────────────────

echo "── LaunchAgents ──"
src_agents=$(ssh "$SOURCE" 'ls ~/Library/LaunchAgents/ 2>/dev/null | grep -c . || echo 0' 2>/dev/null)
dst_agents=$(ls "$HOME/Library/LaunchAgents/" 2>/dev/null | grep -c . || echo 0)

if [[ "$src_agents" != "0" ]]; then
  echo "  Source agents: $src_agents, Target agents: $dst_agents"
  if [[ "$dst_agents" -ge "$src_agents" ]]; then
    pass "LaunchAgents: $dst_agents/$src_agents present"
  else
    warn "LaunchAgents: $dst_agents/$src_agents (review which ones should migrate)"
  fi
else
  pass "No LaunchAgents to verify"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

TOTAL=$((PASS + WARN + FAIL))
echo "============================================"
echo "  VERIFICATION SUMMARY"
echo "============================================"
echo "  Passed:   $PASS"
echo "  Warnings: $WARN"
echo "  Failed:   $FAIL"
echo "  Total:    $TOTAL checks"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo "  STATUS: ISSUES FOUND -- review FAIL items above"
  echo ""
  echo "  Recommended actions:"
  echo "  1. Fix any SSH key permission issues immediately"
  echo "  2. Re-run rsync for directories with missing files"
  echo "  3. Update Intel Homebrew paths in shell configs"
  echo "  4. Reinstall missing Homebrew packages"
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo "  STATUS: MOSTLY OK -- review WARN items"
  exit 0
else
  echo "  STATUS: ALL CLEAR -- migration verified successfully"
  exit 0
fi
