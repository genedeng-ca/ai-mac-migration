# Mac Migration Skill

AI-powered Mac-to-Mac migration that scans, analyzes, transfers, and verifies -- replacing blind copying with intelligent transfer.

## When to use

Trigger when user says: "migrate my mac", "transfer to new mac", "mac migration", "move to new macbook", "set up my new mac from old one", "copy my stuff to new mac", or similar.

## Prerequisites

Reuse known, authorized source-host, account and connection details. Establish observable facts through authorized read-only checks before asking the user:

1. Verify an authorized network route between the two Macs; prefer Ethernet/Thunderbolt for local transfers.
2. Test existing SSH access to the SOURCE Mac. Do not enable Remote Login, change network settings, bypass host-key checks or obtain new credentials without the applicable authorization.
3. Reuse the known source IP/hostname and username; ask only when these essential details cannot be established from authorized context or checks.
4. Check target disk space in Phase 1, rather than asking the user to confirm a fact the tools can inspect.
5. Check power status where available; ask only for a material prerequisite that cannot be verified.

Do not repeat already answered questions. Ordinary technical failures may be investigated using authorized read-only methods; missing approval or access blocks only the dependent step. All explicit approval, privacy and protected-path rules remain effective. These commands are templates, not permission to install tools, change privileges or write to either machine.

## Phase 1: Connect & Scan

### 1.1 Verify SSH connectivity

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 USER@SOURCE_IP "echo 'SSH connection successful'"
```

If this fails, inspect the actual error and authorized network/SSH state. Do not assume every failure means Remote Login is disabled. Ask for essential unresolved access or host details only after safe checks; enabling Remote Login or changing access requires its applicable approval.

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

Use already-authorized read-only inspection. Prefer individual commands below when source-side writes have not been approved. A missing tool is an explicit gap, not a reason to install it automatically.

**Option A: Use the scan script** (only when its upload and execution are authorized; review the script first)
```bash
scp skill/scripts/scan.sh USER@SOURCE_IP:/tmp/mac_scan.sh
ssh USER@SOURCE_IP "chmod +x /tmp/mac_scan.sh && /tmp/mac_scan.sh"
```

Uploading a script is a source-side write, even when the script's purpose is inspection. Do not treat it as automatically covered by read-only access.

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
# Photo library size is inventory information, not proof of complete transfer
ssh USER@SOURCE_IP 'du -sh ~/Pictures/Photos\ Library.photoslibrary 2>/dev/null'
ssh USER@SOURCE_IP 'find ~/Pictures -maxdepth 1 -type d 2>/dev/null'
```

## Phase 2: Analyze & Plan

After scanning, build a migration plan. Present it for approval BEFORE migration writes, overwrites, installations or service activation. This gate does not block already-authorized read-only scanning. Listing a command in the plan, making a backup or generating a verification file is not approval to execute it.

### 2.1 Architecture analysis

Categorize every app as:
- **Native ARM (arm64)**: Architecture-compatible; actual operation still requires verification
- **Universal (x86_64 + arm64)**: Architecture-compatible; actual operation still requires verification
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
# Generate inventory files only where local file creation is authorized
ssh USER@SOURCE_IP 'brew list --formula' > /tmp/brew_formula.txt
ssh USER@SOURCE_IP 'brew list --cask' > /tmp/brew_cask.txt

# On target, only after installation approval:
# xargs brew install < /tmp/brew_formula.txt
# xargs brew install --cask < /tmp/brew_cask.txt
```

### 2.3 Transfer plan categories

Organize everything into categories and present to the user:

| Category | Action | Estimated Size |
|----------|--------|----------------|
| **Home directory** | rsync with explicitly approved scope and exclusions | X GB |
| **Applications** | rsync ARM/Universal, skip Intel | X GB |
| **Homebrew** | Reinstall from list (arch mismatch) or rsync | X GB |
| **SSH keys & configs** | rsync + permission fix | < 1 MB |
| **Shell configs** | rsync + approved path rewrite | < 1 MB |
| **Git config** | rsync | < 1 MB |
| **LaunchAgents** | Named files; separate approval for copy and activation | < 1 MB |
| **Photos** | rsync + content verification; counts are supplemental | X GB |
| **Virtual Machines** | rsync (large, warn user) | X GB |
| **SKIP: Caches** | .cache, Library/Caches, etc. | X GB saved |
| **SKIP: Trash** | .Trash | X GB saved |
| **SKIP: Intel binaries** | Replaced by ARM versions | X GB saved |

### 2.4 Get user approval

Present the plan and ask:
```
Here's the migration plan. Review and confirm:

WILL TRANSFER:
- [exact source/target scope, exclusions and sizes]

WILL SKIP (saves X GB):
- [list with reasons]

WILL REINSTALL (architecture mismatch):
- [list]

LAUNCHAGENTS:
- [specific files approved for copying]
- [specific agents approved for loading; copy approval alone does not authorize loading]

OVERWRITES / TRANSFORMATIONS / ROLLBACK:
- [existing target conflicts, approved rewrites, backup and restoration steps]

REQUIRED ACCEPTANCE:
- [file-content verification, named package/version checks, app launch, service health and other required checks]

NEEDS YOUR ATTENTION:
- [license issues, Intel-only apps, etc.]

Proceed? (yes/no)
```

A still-valid approval for the exact unexecuted step need not be requested again. New services, new overwrite conflicts or additional runtime impact require renewed approval. Preserve any stricter per-action or channel-specific requirements.

Create `verification-plan.json` in an authorized location from the actual approved scope. It is a verification record, not an approval grant. Include every approved item: unchanged transfers in `entries`; intentional transformations, reinstalls and runtime checks in `manual_checks` with explicit expected outcomes and real evidence. Do not omit an item merely to obtain a passing result.

Example structure (replace with the actual approved paths, exclusions and approval reference; do not treat this example as approval):
```json
{
  "schema_version": 1,
  "approval_reference": "reference to the existing user-approved migration plan",
  "entries": [
    {"source": "Documents", "target": "Documents", "required": true, "exclude": []},
    {"source": "Pictures", "target": "Pictures", "required": true, "exclude": []},
    {"source": ".ssh", "target": ".ssh", "required": true, "exclude": []}
  ],
  "permissions": [
    {"path": ".ssh", "mode": "700"}
  ],
  "manual_checks": [
    {"name": "Critical app launch and migrated data access", "status": "pending", "evidence": ""},
    {"name": "Approved package identities and versions", "status": "pending", "evidence": ""},
    {"name": "Approved service health and configuration rewrites", "status": "pending", "evidence": ""},
    {"name": "Target backup and restore procedure", "status": "pending", "evidence": ""}
  ]
}
```

Paths are absolute or relative to the corresponding user's home; do not use `~` or `..`. Add checks for each actual private key's approved permission mode. `exclude` uses case-sensitive Python `fnmatch` patterns against paths relative to each entry; patterns without `/` also match basenames, and excluded directories skip their descendants. Translate the approved transfer exclusions deliberately; rsync filter syntax is not interchangeable with these patterns. Never add exclusions or downgrade a required check to hide a failure. `manual_checks` accept `passed`, `failed`, `pending` or `not_applicable`; passing or not-applicable records require evidence. Keep observed evidence distinct from the script's own automatic checks.

## Phase 3: Execute Migration

Execute only the approved plan. A missing approval or prerequisite pauses the dependent write, not independent authorized work or delivery of existing findings. Preserve the source, explicit deletion approval and all rollback safeguards.

### 3.1 Pre-migration safety

```bash
# Only with the applicable privilege and migration authorization:
# Create APFS snapshot on target (safety net)
sudo tmutil localsnapshot /

# Record the snapshot name for potential rollback
tmutil listlocalsnapshots /
```

Before target writes, document and verify the applicable restoration procedure. Snapshot creation alone is not evidence that rollback has been validated. If required rollback preparation cannot be completed, pause the affected change and deliver the diagnosis and remaining requirements.

### 3.2 Smart rsync for home directory

The following is a template for an approved whole-home scope. For narrower approvals, use the exact approved paths and exclusions instead. Keep LaunchAgents out of the bulk copy regardless; they are handled separately in Phase 3.8.

```bash
rsync -avHAX --progress \
  --exclude='.Trash/' \
  --exclude='.cache/' \
  --exclude='Library/Caches/' \
  --exclude='Library/Logs/' \
  --exclude='Library/Saved Application State/' \
  --exclude='Library/LaunchAgents/' \
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
# For each approved ARM/Universal app:
rsync -avHAX --progress "USER@SOURCE_IP:/Applications/AppName.app" "/Applications/"
```

For Intel-only apps with approved ARM alternatives:
```bash
# Install approved ARM version via Homebrew cask
brew install --cask app-name
```

### 3.4 SSH keys and configs

```bash
# Transfer SSH directory only within its approved source/target scope
rsync -avHAX --progress USER@SOURCE_IP:~/.ssh/ ~/.ssh/

# IMMEDIATELY fix permissions as approved
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_* ~/.ssh/*_key 2>/dev/null
chmod 644 ~/.ssh/*.pub 2>/dev/null
chmod 644 ~/.ssh/config 2>/dev/null
chmod 644 ~/.ssh/known_hosts 2>/dev/null
chmod 644 ~/.ssh/authorized_keys 2>/dev/null
```

### 3.5 Shell configuration

```bash
# Transfer approved shell configs
for f in .zshrc .bashrc .zprofile .bash_profile .zshenv; do
  rsync -avHAX --progress "USER@SOURCE_IP:~/$f" ~/ 2>/dev/null
done
```

**Post-transfer path rewriting** -- check for Intel Homebrew paths:
```bash
# Check if any config references /usr/local (Intel Homebrew)
grep -n '/usr/local' ~/.zshrc ~/.bashrc ~/.zprofile 2>/dev/null
# Apply only exact rewrites already approved; otherwise propose the changes
```

### 3.6 Homebrew reinstall (if architecture mismatch)

```bash
# Run only when installation has been approved
# Install Homebrew on target if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install formulae (batch, will skip already-installed)
cat /tmp/brew_formula.txt | xargs brew install

# Install casks
cat /tmp/brew_cask.txt | xargs brew install --cask
```

### 3.7 npm globals

```bash
# Reinstall only the approved global npm package list
ssh USER@SOURCE_IP "npm list -g --depth=0 --json 2>/dev/null" | \
  python3 -c "import sys,json; d=json.load(sys.stdin).get('dependencies',{}); [print(k) for k in d if k!='npm']" | \
  xargs npm install -g
```

### 3.8 LaunchAgents (selective)

Read the list approved in Phase 2.4. Do not ask again for the same still-authorized step. A file approved for copying is not automatically approved for loading; new agents, overwrite conflicts or runtime effects require approval before proceeding.

```bash
# Read-only inventory; this is not permission to copy or load every listed agent
ssh USER@SOURCE_IP 'ls ~/Library/LaunchAgents/'

# For each specific file approved for copying:
rsync -avHAX --progress "USER@SOURCE_IP:~/Library/LaunchAgents/AGENT.plist" ~/Library/LaunchAgents/

# Only for an agent separately approved for activation:
launchctl load ~/Library/LaunchAgents/AGENT.plist
```

## Phase 4: Verify

Verify the actual approved plan, not aggregate counts. File counts, sizes, directory existence and successful service startup alone are not end-to-end acceptance. Continue independent checks after an individual failure, retain the result, and always produce a summary.

### 4.1 Approved-plan verification

`verify.sh` requires Python 3 on both hosts and existing authorized SSH access. It streams its fixed read-only scanner over SSH without installing a remote script. It checks each declared unchanged transfer by relative path, type, SHA-256 content digest and symlink target; it does not follow symlink targets, delete files or modify permissions. Target-only files are retained and reported. Add actual approved permission checks to the plan.

```bash
# Run on the target; preserve the verifier's status
if bash skill/scripts/verify.sh USER@SOURCE_IP verification-plan.json; then
  verification_status=0
else
  verification_status=$?
fi
printf 'Verifier exit status: %s\n' "$verification_status"
```

Exit `0` means declared checks passed; `1` means a mismatch or failed check; `2` means evidence is incomplete. Missing plans, missing Python, SSH failure, unreadable/changing files and pending manual checks must not be reported as success. The default source-inventory timeout is 900 seconds; set `VERIFY_TIMEOUT_SECONDS` explicitly for larger approved scopes. A timeout is incomplete evidence, not an empty source. The script's success covers its declared plan only; it cannot authenticate approval or prove that an omitted migration requirement was satisfied.

### 4.2 Photo verification (CRITICAL)

Include every approved photo library and RAW/media directory in content verification, without limiting checks to selected extensions. Counts and sizes are supplemental diagnostics. If files change during verification or the library cannot be read, report incomplete evidence and investigate within the approved scope; do not suppress the problem or wipe the source. Record the actual ability to open the migrated library and access its expected data in the required runtime evidence.

### 4.3 SSH key verification

Add the actual transferred `.ssh` paths and required modes to `permissions` in the plan. A permissions pass does not prove authentication. Perform any required authentication or agent-forwarding test through the already-authorized destination and record its result. Never print private-key contents, replace credentials or change host trust merely to make a test pass.

### 4.4 Tool verification

Check each approved package/tool by identity, expected version and applicable operation; a larger package count does not prove the required packages are present. Missing or untestable required tools remain failed or incomplete. Record actual results for reinstalls and intentionally transformed configurations in the plan's manual evidence, rather than incorrectly comparing them byte-for-byte with pre-transformation source files.

### 4.5 Application presence and launch checks

```bash
# Presence check only: this does NOT launch applications or verify their data
for app in "Safari" "Terminal" "Visual Studio Code" "iTerm"; do
  if [ -d "/Applications/$app.app" ]; then
    echo "Present only, launch unverified: $app.app"
  else
    echo "Missing: $app.app"
  fi
done
```

Use the actual approved critical-app list, including per-user applications where relevant. Perform permitted launch/data-access tests or obtain user-provided evidence; do not interrupt a running user session or bypass an activation prompt. Record `pending` when launch cannot be tested. A manual evidence record must identify the observed result and its source; the verifier labels it as recorded evidence, not an independently executed launch test.

### 4.6 VM and service verification

Include approved VM files in content verification. Presence alone does not prove a VM boots or a service is healthy; perform only approved runtime tests and record their actual outcomes. Services approved only for copying must remain unloaded; record activation as not applicable with the approval-scope reason when it genuinely was outside scope. Do not relabel a failed required activation as not applicable.

### 4.7 Final summary

Derive the final status from actual evidence:

- **VERIFIED COMPLETE**: Every required approved action and acceptance check passed, and the result was delivered.
- **PARTIALLY COMPLETE**: Some work is verified, but required work, cleanup or verification remains.
- **BLOCKED**: An essential permission, approval or prerequisite prevents the dependent work.
- **FAILED**: Required acceptance failed; report any approved rollback and its verified outcome.

Never print an unconditional `MIGRATION COMPLETE` heading. Report already-verified results while cleanup or approval is pending, but do not mark the entire task complete. Keep explicit deletion approval; no temporary-file exception is introduced.

```
MIGRATION STATUS: [status justified by the evidence]

Approved scope and reference:
  - [source, target, approved items and exclusions]

Verified results:
  - [actual transferred content, exact package identities and completed runtime checks]

Failed / incomplete / not applicable:
  - [each item, reason and evidence; distinguish these states]

Skipped:
  - [approved exclusions and reasons]

Rollback:
  - [prepared method; any rollback performed and its verified result]

Remaining actions or approval:
  - [exact blocked steps, pending cleanup, activation or license checks]
```

Restarting machines, activating services, deactivating licenses, deleting files or wiping the source still requires the applicable approval. Do not turn a suggested next step into an unauthorized action.

## Hard-Won Lessons (Guardrails)

These rules are non-negotiable. They come from real migration failures:

1. **ALWAYS check `~/Applications/` not just `/Applications/`** -- many apps install per-user
2. **ALWAYS verify photo contents against the approved plan** -- counts alone cannot establish completeness
3. **ALWAYS check for VMs** in `~/Virtual Machines/`, `~/Parallels/`, and search for `.vmx`/`.vmdk`/`.qcow2`
4. **ALWAYS look for software licenses** in `~/Library/Application Support/` -- some are hardware-locked
5. **NEVER use `rsync -z`** on local/fast networks -- compression wastes CPU, slows transfer dramatically
6. **NEVER blindly copy Intel Homebrew** to ARM Mac -- binaries will crash silently
7. **WARN about Homebrew path differences**: `/usr/local` (Intel) vs `/opt/homebrew` (ARM)
8. **CHECK large hidden directories**: `.docker`, `.vagrant`, `.npm`, `.cache`, `.rustup`, `.cargo`, `.pyenv`, `.conda`, `.gradle`, `.m2`
9. **FIX SSH permissions immediately** after transfer within the approved scope -- wrong permissions = silent auth failure
10. **CHECK shell configs for hardcoded paths** -- Intel Homebrew paths in `.zshrc` will break on ARM
11. **MAP app bundles to data directories** -- app name in `/Applications/` often differs from `~/Library/Application Support/` directory name
12. **NEVER delete during migration** -- only flag duplicates; human reviews all deletion suggestions
13. **ALWAYS create an APFS snapshot** on the target before starting approved writes, and validate the applicable restoration procedure; pause affected writes if this prerequisite cannot be met
14. **VERIFY Time Machine** is set up on the new Mac before wiping the old one
15. **TEST SSH agent forwarding** if the user relies on it for git operations
