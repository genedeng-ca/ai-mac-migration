# AI Mac Migration

**I haven't reinstalled macOS in 20 years.** Every Mac I've owned has been migrated forward -- from PowerBook G4 to M5 MacBook Pro, across 8 machines, carrying two decades of muscle memory, scripts, configs, and digital life. Apple's Migration Assistant got me 80% there each time. AI got me the rest.

---

## The Problem

Apple Migration Assistant is a black box. It copies *everything* -- the 50GB of Intel-only apps that will never run on Apple Silicon, the three conflicting Python installations, the orphaned preference files from software you uninstalled in 2019. You watch a progress bar for 6 hours and pray.

When it's done, you spend the next two weeks discovering what broke:

- That app needs Rosetta and runs at half speed
- Your SSH keys migrated but the permissions are wrong
- 30GB of duplicate photos because iCloud and local copies both came over
- VMware Fusion config migrated, but the actual VMs didn't
- Software licenses tied to hardware IDs are now invalid
- Homebrew packages compiled for Intel are silently failing

**Migration Assistant treats your Mac like a disk image. Your Mac is not a disk image. It's a living system.**

## The Solution

AI Mac Migration replaces blind copying with intelligent transfer. It scans, understands, decides, and verifies -- using a 122-billion-parameter LLM running locally on your Mac. No cloud. No API calls. No telemetry. Just a smarter migration.

```
Source Mac ──SSH──> AI Analysis ──rsync──> Target Mac
                      │
               Local LLM on M5 Max
               Qwen3.5 122B via OpenClaw
               "Should this transfer?
                Is there a better version?
                Will this even work on ARM?"
```

### How it works

1. **Scan** -- Inventory both machines: apps, configs, packages, hardware capabilities
2. **Analyze** -- LLM evaluates every item: architecture compatibility, version currency, size vs. value
3. **Plan** -- Generate a ranked transfer plan with explanations for every decision
4. **Execute** -- Adaptive rsync with real-time health monitoring
5. **Verify** -- Post-transfer checksums and functional testing

## Features

- [x] **Intelligent app scanning** -- Detects Intel vs ARM binaries, flags Rosetta-dependent apps, suggests native alternatives
- [x] **Cross-machine package reuse** -- If another machine on your network already has the ARM version of a package, grab it from there instead of downloading
- [x] **Real-time hardware health detection** -- Monitors disk I/O, CPU thermal, network throughput during transfer; backs off before your fans hit jet-engine mode
- [x] **Adaptive transfer speed optimization** -- Dynamically adjusts rsync parallelism and block size based on network conditions and disk speed
- [x] **Smart exclusion lists** -- AI-generated `.migrationignore` that understands what cache files, build artifacts, and temp data can be safely skipped
- [x] **Selective config migration** -- Migrates shell configs, SSH keys, git configs with permission fixup and path rewriting for the new machine
- [ ] **Automated photo dedup and organization** -- Detect and eliminate duplicate photos across iCloud, local library, and manual backups before transfer
- [ ] **Software license migration** -- Detect apps with hardware-locked licenses, generate a deactivation checklist for the old machine before wiping
- [ ] **End-to-end verification with checksums** -- Post-migration integrity check comparing source and destination with per-file SHA-256 verification
- [ ] **Rollback snapshots** -- APFS snapshot on target before migration starts; one-command rollback if anything goes wrong
- [ ] **Profile-based migration** -- Pre-built profiles for "Developer", "Creative Pro", "Business" that prioritize what matters for each workflow

## The Story

This tool was born from migrating an M4 Max MacBook Pro to an M5 Max MacBook Pro -- a machine carrying 20 years of accumulated digital life across 160TB of family data, dozens of development environments, and a fleet of AI services.

The migration was powered by Qwen3.5 122B running locally on the M5 Max itself via OpenClaw -- no cloud APIs, no subscriptions. The AI scanned both machines over SSH, made real-time decisions about what to transfer, and caught problems that Migration Assistant would have silently propagated.

What should have been a weekend of pain became an afternoon of supervised automation. The AI caught things a human would miss:

- 12 Intel-only apps that had native ARM replacements available
- 8GB of orphaned container images from a Docker version two releases old
- SSH config referencing hosts that no longer exist
- Homebrew packages that could be pulled from a local fleet machine instead of downloading 4GB over the internet

## Tech Stack

| Component | Role |
|-----------|------|
| **Python 3.12+** | Core orchestration |
| **Qwen3.5 122B via OpenClaw** | Decision engine running locally on M5 Max (no cloud dependency) |
| **SSH** | Secure cross-machine communication |
| **rsync** | Adaptive file transfer with resume support |
| **APFS snapshots** | Pre-migration safety net |
| **Homebrew** | Package reconciliation and cross-architecture detection |

## Quickstart

```bash
# On your NEW Mac:
git clone https://github.com/genedeng-ca/ai-mac-migration.git
cd ai-mac-migration
pip install -r requirements.txt

# Point it at your old Mac:
python migrate.py --source user@old-mac.local --target .

# Review the AI-generated migration plan before anything transfers:
# The tool will show you exactly what it wants to do and why.
```

## Lessons Learned (The Hard Way)

Real migrations taught us what AI gets wrong. These are now guardrails in the tool:

| Mistake | What Happened | The Fix |
|---------|--------------|---------|
| **Photo loss** | AI classified "IMG_" prefixed files as iOS duplicates. Some were unique screenshots. | Never delete -- only flag. Human reviews all dedup suggestions. |
| **App folder miss** | Some apps store data in `~/Library/Application Support/` with a different name than the `.app` bundle. | Map app bundles to their data directories using `lsregister` dump. |
| **VMware forget** | Migration Assistant copied VMware Fusion but not the VMs in `~/Virtual Machines/`. | Explicit VM detection: scan for `.vmx`, `.vmdk`, `.qcow2`, Parallels bundles. |
| **License gap** | Migrated apps that needed per-machine activation. Old machine was wiped. Licenses lost. | Pre-migration license audit with deactivation reminders. |
| **Permission drift** | SSH keys and GPG keyrings migrated with wrong permissions. Silent auth failures. | Post-transfer permission validator: `700` for `.ssh/`, `600` for private keys. |
| **Homebrew architecture mismatch** | Intel Homebrew (`/usr/local`) packages copied to ARM Mac. Binaries crash silently. | Detect architecture, reinstall from source or pull from fleet ARM cache. |

## Architecture

```
ai-mac-migration/
├── migrate.py              # Entry point
├── scanner/
│   ├── apps.py             # Application inventory & architecture detection
│   ├── packages.py         # Homebrew/pip/npm package analysis
│   ├── configs.py          # Shell, SSH, git config discovery
│   └── hardware.py         # Hardware capability comparison
├── analyzer/
│   ├── llm_engine.py       # Local LLM interface (OpenClaw compatible)
│   ├── compatibility.py    # ARM/Intel compatibility checker
│   └── dedup.py            # File & photo deduplication engine
├── executor/
│   ├── transfer.py         # Adaptive rsync orchestration
│   ├── health_monitor.py   # Real-time system health during transfer
│   └── verify.py           # Post-transfer integrity checks
└── plans/
    └── migration_plan.json  # AI-generated, human-reviewed transfer plan
```

## Contributing

This started as a personal tool for migrating my own Mac fleet. If you've felt the pain of Migration Assistant and want something better, contributions are welcome.

```bash
# Run tests
python -m pytest tests/

# Run a dry-run migration (no files transferred)
python migrate.py --source user@old-mac.local --target . --dry-run
```

## License

MIT License. See [LICENSE](LICENSE) for details.

---

*Built by someone who has mass-migrated too many Macs and finally got tired of doing it manually. Powered by Qwen3.5 122B running locally on Apple Silicon -- no cloud, no API keys, just your Mac understanding itself.*
