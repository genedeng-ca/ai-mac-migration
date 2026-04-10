# Mac Migration Skill

AI-powered Mac-to-Mac migration that scans, analyzes, transfers, and verifies -- replacing blind copying with intelligent transfer.

## When to use

Trigger when user says: "migrate my mac", "transfer to new mac", "mac migration", "move to new macbook", "set up my new mac from old one", "copy my stuff to new mac", or similar.

## Prerequisites

Before starting, confirm ALL of these with the user:

1. **Both Macs on the same network** (Wi-Fi or Ethernet -- Ethernet/Thunderbolt strongly preferred for speed)
2. **SSH enabled on the SOURCE Mac**: System Settings > General > Sharing > Remote Login
3. **User knows the source Mac's IP or hostname** (run `ipconfig getifaddr en0` on source to find it)
4. **Sufficient disk space on the target** (you will check this in Phase 1)
5. **Both machines plugged into power** (migrations can take hours)

Ask the user:
```
To start migration, I need:
1. Source Mac IP or hostname (e.g., 192.168.50.42 or old-mac.local)
2. Username on the source Mac
3. Are both Macs on the same local network?
4. Is SSH/Remote Login enabled on the source Mac?
```

## Phase 1: Connect & Scan

### 1.1 Verify SSH connectivity

```bash
ssh -o ConnectTimeout=5 USER@SOURCE_IP "echo 'SSH connection successful'"
```

If this fails, guide the user:
- "On your source Mac, go to System Settings > General > Sharing > Remote Login and turn it ON"
- "Make sure both Macs are on the same network"
- If still failing: `ping SOURCE_IP` to check network

### 1.2 Scan the TARGET Mac (local)

Run these commands locally on the target Mac to understand what already exists:

```bash
# Hardware info
sysctl -n machdep.cpu.brand_string
sw_vers
uname -m
diskutil info / | grep -E "(Free|Total|Volume Name|File System)"

# Homebrew status
which brew && brew --prefix && brew list --formula 2>/dev/null | wc -l
which brew && brew list --cask 2>/dev/null | wc -l

# Existing apps
ls /Applications/ 2>/dev/null | wc -l
ls ~/Applications/ 2>/dev/null | wc -l
```

### 1.3 Scan the SOURCE Mac (remote)

Run the comprehensive scan script on the source machine. You can either copy `scan.sh` over or run commands directly via SSH.

**Option A: Use the scan script** (preferred)
```bash
scp skill/scripts/scan.sh USER@SOURCE_IP:/tmp/mac_scan.sh
ssh USER@SOURCE_IP "chmod +x /tmp/mac_scan.sh && /tmp/mac_scan.sh"
```

**Option B: Run commands individually via SSH**

#### Applications inventory
```bash
# List all apps with architecture detection
ssh USER@SOURCE_IP 'for app in /Applications/*.app ~/Applications/*.app; do
  [ -d "$app" ] || continue
  name=$(basename "$app")
  binary=$(defaults read "$app/Contents/Info.plist" CFBundleExecutable 2>/dev/null)
  if [ -n "$binary" ] && [ -f "$app/Contents/MacOS/$binary" ]; then
    arch=$(lipo -info "$app/Contents/MacOS/$binary" 2>/dev/null | sed "s/.*: //")
  else
    arch="unknown"
  fi
  size=$(du -sh "$app" 2>/dev/null | cut -f1)
  echo "$size | $arch | $name"
done'
```

#### Package managers
```bash
# Homebrew
ssh USER@SOURCE_IP 'brew list --formula 2>/dev/null'
ssh USER@SOURCE_IP 'brew list --cask 2>/dev/null'

# npm globals
ssh USER@SOURCE_IP 'npm list -g --depth=0 2>/dev/null'

# Python packages (user-installed)
ssh USER@SOURCE_IP 'pip3 list --user 2>/dev/null || pip3 list 2>/dev/null'

# Python via pyenv/conda
ssh USER@SOURCE_IP 'ls ~/.pyenv/versions/ 2>/dev/null'
ssh USER@SOURCE_IP 'conda env list 2>/dev/null'

# Ruby gems
ssh USER@SOURCE_IP 'gem list --local 2>/dev/null | head -20'

# Rust/Cargo
ssh USER@SOURCE_IP 'ls ~/.cargo/bin/ 2>/dev/null'
```

#### Shell and config files
```bash
ssh USER@SOURCE_IP 'for f in .zshrc .bashrc .zprofile .bash_profile .zshenv; do
  [ -f ~/$f ] && echo "EXISTS: $f ($(wc -l < ~/$f) lines)" || echo "MISSING: $f"
done'

# Git config
ssh USER@SOURCE_IP 'cat ~/.gitconfig 2>/dev/null'

# SSH keys
ssh USER@SOURCE_IP 'ls -la ~/.ssh/ 2>/dev/null'
ssh USER@SOURCE_IP 'cat ~/.ssh/config 2>/dev/null'
```

#### Large directories and hidden storage
```bash
# Top-level home directory sizes
ssh USER@SOURCE_IP 'du -sh ~/* ~/.[!.]* 2>/dev/null | sort -rh | head -30'

# Known large hidden directories
ssh USER@SOURCE_IP 'for d in .docker .vagrant .npm .cache .local .rustup .cargo .pyenv .conda .gradle .m2 .cocoapods; do
  [ -d ~/$d ] && du -sh ~/$d 2>/dev/null
done'

# Virtual machines
ssh USER@SOURCE_IP 'ls -la ~/Virtual\ Machines/ 2>/dev/null; ls -la ~/Parallels/ 2>/dev/null'
ssh USER@SOURCE_IP 'find ~ -maxdepth 3 -name "*.vmx" -o -name "*.vmdk" -o -name "*.qcow2" 2>/dev/null'
```

#### System services and agents
```bash
# LaunchAgents
ssh USER@SOURCE_IP 'ls ~/Library/LaunchAgents/ 2>/dev/null'

# Login items
ssh USER@SOURCE_IP 'osascript -e "tell application \"System Events\" to get the name of every login item" 2>/dev/null'
```

#### Disk and transfer planning
```bash
# Source disk usage
ssh USER@SOURCE_IP 'df -h / | tail -1'
ssh USER@SOURCE_IP 'du -sh ~ 2>/dev/null'

# Local (target) disk space
df -h / | tail -1
```

#### Software licenses
```bash
# Check for license files in common locations
ssh USER@SOURCE_IP 'find ~/Library/Application\ Support -maxdepth 2 -name "*license*" -o -name "*License*" -o -name "*serial*" 2>/dev/null'
ssh USER@SOURCE_IP 'find ~/Library/Preferences -name "*.plist" 2>/dev/null | head -30'
```

#### Photo library
```bash
# Photo library size -- CRITICAL to track for verification
ssh USER@SOURCE_IP 'du -sh ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null'
ssh USER@SOURCE_IP 'find ~/Pictures -maxdepth 1 -type d 2>/dev/null'
```

## Phase 2: Analyze & Plan

After scanning, build a migration plan. Present this to the user for review BEFORE executing anything.

### 2.1 Architecture analysis

Categorize every app as:
- **Native ARM (arm64)**: Will work perfectly on Apple Silicon target
- **Universal (x86_64 + arm64)**: Will work, no action needed
- **Intel-only (x86_64)**: Needs Rosetta 2 or a native replacement
- **Unknown**: Manual verification needed

For Intel-only apps, research and suggest:
- Is there a native ARM version available? (check `brew info APPNAME` or the developer's website)
- Is this app still actively maintained?
- Is there a better alternative?

### 2.2 Homebrew strategy

Detect architecture mismatch:
```bash
# Source Homebrew location
ssh USER@SOURCE_IP 'brew --prefix'
# /usr/local = Intel, /opt/homebrew = Apple Silicon

# Target Homebrew location
brew --prefix
```

**CRITICAL**: If source is Intel (`/usr/local`) and target is ARM (`/opt/homebrew`):
- Do NOT rsync Homebrew binaries -- they won't work
- Instead, generate a `brew install` script from the package list
- Casks can usually be reinstalled: `brew install --cask APP_NAME`

```bash
# Generate reinstall script
ssh USER@SOURCE_IP 'brew list --formula' > /tmp/brew_formula.txt
ssh USER@SOURCE_IP 'brew list --cask' > /tmp/brew_cask.txt

# On target:
# xargs brew install < /tmp/brew_formula.txt
# xargs brew install --cask < /tmp/brew_cask.txt
```

### 2.3 Transfer plan categories

Organize everything into categories and present to the user:

| Category | Action | Estimated Size |
|----------|--------|----------------|
| **Home directory** | rsync with smart exclusions | X GB |
| **Applications** | rsync ARM/Universal, skip Intel | X GB |
| **Homebrew** | Reinstall from list (arch mismatch) or rsync | X GB |
| **SSH keys & configs** | rsync + permission fix | < 1 MB |
| **Shell configs** | rsync + path rewrite check | < 1 MB |
| **Git config** | rsync | < 1 MB |
| **LaunchAgents** | Review & selective copy | < 1 MB |
| **Photos** | rsync + count verification | X GB |
| **Virtual Machines** | rsync (large, warn user) | X GB |
| **SKIP: Caches** | .cache, Library/Caches, etc. | X GB saved |
| **SKIP: Trash** | .Trash | X GB saved |
| **SKIP: Intel binaries** | Replaced by ARM versions | X GB saved |

### 2.4 Get user approval

Present the plan and ask:
```
Here's the migration plan. Review and confirm:

WILL TRANSFER:
- [list with sizes]

WILL SKIP (saves X GB):
- [list with reasons]

WILL REINSTALL (architecture mismatch):
- [list]

NEEDS YOUR ATTENTION:
- [license issues, Intel-only apps, etc.]

Proceed? (yes/no)
```

## Phase 3: Execute Migration

### 3.1 Pre-migration safety

```bash
# Create APFS snapshot on target (safety net)
sudo tmutil localsnapshot /

# Record the snapshot name for potential rollback
tmutil listlocalsnapshots /
```

### 3.2 Smart rsync for home directory

The master rsync command with intelligent exclusions:

```bash
rsync -avHAX --progress \
  --exclude='.Trash/' \
  --exclude='.cache/' \
  --exclude='Library/Caches/' \
  --exclude='Library/Logs/' \
  --exclude='Library/Saved Application State/' \
  --exclude='.docker/' \
  --exclude='.vagrant/' \
  --exclude='node_modules/' \
  --exclude='.npm/_cacache/' \
  --exclude='__pycache__/' \
  --exclude='*.pyc' \
  --exclude='.DS_Store' \
  --exclude='Library/Developer/Xcode/DerivedData/' \
  --exclude='Library/Developer/Xcode/Archives/' \
  --exclude='Library/Developer/CoreSimulator/' \
  --exclude='.gradle/caches/' \
  --exclude='.m2/repository/' \
  --exclude='Library/Application Support/Google/Chrome/Default/Service Worker/' \
  --exclude='Library/Application Support/Slack/Service Worker/' \
  --exclude='.local/share/Trash/' \
  --exclude='*.app/Contents/MacOS/*.dSYM' \
  USER@SOURCE_IP:~/ ~/
```

**CRITICAL RULES:**
- **NEVER use `rsync -z` on local/fast networks** -- compression wastes CPU and slows transfer on gigabit+ connections
- **ALWAYS use `-H` flag** to preserve hard links
- **ALWAYS use `--progress`** so the user can see what's happening
- For Thunderbolt or 10GbE connections, add `--no-compress` explicitly to be safe

### 3.3 Applications transfer

Only transfer ARM-compatible apps:

```bash
# Transfer universal and ARM apps
rsync -avHAX --progress \
  USER@SOURCE_IP:/Applications/ /Applications/ \
  --exclude='*.app' \
  --include='*/' \
  --filter='merge /tmp/app_include_list.txt'
```

Or more practically, transfer specific apps:
```bash
# For each ARM/Universal app:
rsync -avHAX --progress "USER@SOURCE_IP:/Applications/AppName.app" "/Applications/"
```

For Intel-only apps with ARM alternatives:
```bash
# Install ARM version via Homebrew cask
brew install --cask app-name
```

### 3.4 SSH keys and configs

```bash
# Transfer SSH directory
rsync -avHAX --progress USER@SOURCE_IP:~/.ssh/ ~/.ssh/

# IMMEDIATELY fix permissions
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_* ~/.ssh/*_key 2>/dev/null
chmod 644 ~/.ssh/*.pub 2>/dev/null
chmod 644 ~/.ssh/config 2>/dev/null
chmod 644 ~/.ssh/known_hosts 2>/dev/null
chmod 644 ~/.ssh/authorized_keys 2>/dev/null
```

### 3.5 Shell configuration

```bash
# Transfer shell configs
for f in .zshrc .bashrc .zprofile .bash_profile .zshenv; do
  rsync -avHAX --progress "USER@SOURCE_IP:~/$f" ~/ 2>/dev/null
done
```

**Post-transfer path rewriting** -- check for Intel Homebrew paths:
```bash
# Check if any config references /usr/local (Intel Homebrew)
grep -n '/usr/local' ~/.zshrc ~/.bashrc ~/.zprofile 2>/dev/null
# If found, warn user and offer to replace with /opt/homebrew
```

### 3.6 Homebrew reinstall (if architecture mismatch)

```bash
# Install Homebrew on target if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install formulae (batch, will skip already-installed)
cat /tmp/brew_formula.txt | xargs brew install

# Install casks
cat /tmp/brew_cask.txt | xargs brew install --cask
```

### 3.7 npm globals

```bash
# Reinstall global npm packages
ssh USER@SOURCE_IP "npm list -g --depth=0 --json 2>/dev/null" | \
  python3 -c "import sys,json; d=json.load(sys.stdin).get('dependencies',{}); [print(k) for k in d if k!='npm']" | \
  xargs npm install -g
```

### 3.8 LaunchAgents (selective)

```bash
# List and let user choose which to migrate
ssh USER@SOURCE_IP 'ls ~/Library/LaunchAgents/'

# For each approved agent:
rsync -avHAX --progress "USER@SOURCE_IP:~/Library/LaunchAgents/AGENT.plist" ~/Library/LaunchAgents/

# Load it
launchctl load ~/Library/LaunchAgents/AGENT.plist
```

## Phase 4: Verify

Run the verification script or execute checks manually.

### 4.1 File count comparison

```bash
# Compare file counts for critical directories
for dir in Documents Desktop Pictures Music Downloads; do
  src=$(ssh USER@SOURCE_IP "find ~/$dir -type f 2>/dev/null | wc -l")
  dst=$(find ~/$dir -type f 2>/dev/null | wc -l)
  echo "$dir: source=$src target=$dst $([ "$src" = "$dst" ] && echo 'OK' || echo 'MISMATCH')"
done
```

### 4.2 Photo verification (CRITICAL)

Photos are irreplaceable. Always verify counts:

```bash
# Count photos in library
src_photos=$(ssh USER@SOURCE_IP 'find ~/Pictures -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.heic" -o -name "*.mov" -o -name "*.mp4" \) 2>/dev/null | wc -l')
dst_photos=$(find ~/Pictures -type f \( -name "*.jpg" -o -name "*.jpeg" -o -name "*.png" -o -name "*.heic" -o -name "*.mov" -o -name "*.mp4" \) 2>/dev/null | wc -l)
echo "Photos: source=$src_photos target=$dst_photos"

# Also check Photo Library specifically
src_lib=$(ssh USER@SOURCE_IP 'du -sh ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null')
dst_lib=$(du -sh ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null)
echo "Photo Library: source=$src_lib target=$dst_lib"
```

### 4.3 SSH key verification

```bash
# Check permissions
ls -la ~/.ssh/
stat -f "%Sp %SN" ~/.ssh/id_* 2>/dev/null

# Test SSH works
ssh -T git@github.com 2>&1 | head -1
```

### 4.4 Tool verification

```bash
# Check common developer tools
for cmd in git python3 node npm ruby cargo go java docker; do
  if command -v $cmd &>/dev/null; then
    echo "OK: $cmd ($(command -v $cmd)) -- $($cmd --version 2>&1 | head -1)"
  else
    echo "MISSING: $cmd"
  fi
done

# Homebrew health
brew doctor 2>&1 | head -10
```

### 4.5 Application launch test

```bash
# Verify key apps can launch (open and immediately quit)
for app in "Safari" "Terminal" "Visual Studio Code" "iTerm"; do
  if [ -d "/Applications/$app.app" ]; then
    echo "Found: $app.app"
  else
    echo "Missing: $app.app"
  fi
done
```

### 4.6 VM verification

```bash
# If VMs were transferred, verify they exist
ls -la ~/Virtual\ Machines/ 2>/dev/null
ls -la ~/Parallels/ 2>/dev/null
find ~ -maxdepth 3 -name "*.vmx" 2>/dev/null
```

### 4.7 Final summary

Present a complete migration report:

```
MIGRATION COMPLETE

Transferred:
  - X files from home directory
  - X applications
  - X Homebrew formulae, X casks
  - SSH keys and config
  - Shell configuration files

Verification:
  - Documents: X/X files (OK/MISMATCH)
  - Pictures: X/X files (OK/MISMATCH)
  - Photos Library: X GB / X GB
  - SSH keys: permissions OK/NEEDS FIX
  - Developer tools: X/X working

Skipped (saved X GB):
  - Caches, logs, trash
  - Intel-only apps: [list]

Needs manual attention:
  - [Intel apps without ARM alternatives]
  - [License reactivation needed for: list]
  - [Path rewrites needed in configs: list]

Recommended next steps:
  1. Restart the Mac to ensure all services start correctly
  2. Open each critical app to verify it works
  3. Deactivate licenses on the old Mac before wiping
  4. Check iCloud sync status
  5. Verify Time Machine is configured for the new machine
```

## Hard-Won Lessons (Guardrails)

These rules are non-negotiable. They come from real migration failures:

1. **ALWAYS check `~/Applications/` not just `/Applications/`** -- many apps install per-user
2. **ALWAYS verify photo counts** after transfer -- compare source vs destination file counts
3. **ALWAYS check for VMs** in `~/Virtual Machines/`, `~/Parallels/`, and search for `.vmx`/`.vmdk`/`.qcow2`
4. **ALWAYS look for software licenses** in `~/Library/Application Support/` -- some are hardware-locked
5. **NEVER use `rsync -z`** on local/fast networks -- compression wastes CPU, slows transfer dramatically
6. **NEVER blindly copy Intel Homebrew** to ARM Mac -- binaries will crash silently
7. **WARN about Homebrew path differences**: `/usr/local` (Intel) vs `/opt/homebrew` (ARM)
8. **CHECK large hidden directories**: `.docker`, `.vagrant`, `.npm`, `.cache`, `.rustup`, `.cargo`, `.pyenv`, `.conda`, `.gradle`, `.m2`
9. **FIX SSH permissions immediately** after transfer -- wrong permissions = silent auth failure
10. **CHECK shell configs for hardcoded paths** -- Intel Homebrew paths in `.zshrc` will break on ARM
11. **MAP app bundles to data directories** -- app name in `/Applications/` often differs from `~/Library/Application Support/` directory name
12. **NEVER delete during migration** -- only flag duplicates; human reviews all deletion suggestions
13. **ALWAYS create an APFS snapshot** on the target before starting -- one-command rollback if anything goes wrong
14. **VERIFY Time Machine** is set up on the new Mac before wiping the old one
15. **TEST SSH agent forwarding** if the user relies on it for git operations
