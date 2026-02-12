# Checkmk Update Script

A single Bash script that automates Checkmk Raw Edition updates on Debian/Ubuntu. It handles dependency checks, site backup with live progress, package download with SHA256 verification, installation, and post-update verification -- all in one command.

```
  ╔══════════════════════════════════════════╗
  ║      Checkmk Update Script v1.3.0        ║
  ╚══════════════════════════════════════════╝
```

---

## Features

- **7-phase guided workflow** -- Prerequisites, script update check, site detection, backup, download, install, and verification with numbered phase headers.
- **SHA256 checksum verification** of every downloaded package.
- **Secure temp directory** (`mktemp -d` with `chmod 700`) instead of a predictable path.
- **HTTPS enforcement** (`--proto =https`) on all outgoing requests.
- **Live backup progress** showing compressed archive growth, percentage, and elapsed time.
- **Spinner animations** for long-running operations (dpkg install, omd stop/start).
- **Pre-update confirmation summary** showing site, versions, and backup location before committing.
- **Post-update completion summary** with version diff, backup size, site status, and total duration.
- **EXIT trap safety net** -- automatically restarts the site if the script exits unexpectedly mid-update.
- **`NO_COLOR` support** -- all color output respects the `NO_COLOR` environment variable and non-interactive terminals.
- **Self-update with shebang validation** -- checks GitHub releases and validates downloaded scripts before replacing.
- **Edition-aware version comparison** -- correctly strips `.cre`/`.cee` suffixes for accurate comparisons.

---

## Requirements

| Requirement | Details |
|---|---|
| **OS** | Debian or Ubuntu |
| **Privileges** | Root (the script checks at startup) |
| **Checkmk** | Raw Edition site managed by `omd` |
| **Commands** | `omd`, `lsb_release`, `wget`, `curl`, `dpkg`, `awk`, `grep`, `df`, `sort`, `sha256sum` |
| **Disk space** | At least 2 GB free on `/opt/omd/` plus enough space in `/var/backups/checkmk` for the backup |

Missing packages (except `omd`) are installed automatically via `apt-get` during the prerequisites phase.

---

## Installation

```bash
git clone https://github.com/KTOrTs/checkmk_update_script.git
cd checkmk_update_script
chmod +x cmkupdate.sh
```

---

## Usage

```
cmkupdate - Checkmk Raw Edition update helper (v1.3.0)

Usage:
  ./cmkupdate.sh [options]

Options:
  -h, --help        Show help text and exit
  -t, --self-test   Run dependency and syntax check without performing updates
  -y, --yes         Skip interactive confirmations (for automation/CI)
```

### Interactive update (recommended)

```bash
sudo ./cmkupdate.sh
```

The script walks through all 7 phases, pausing for confirmation before the update begins.

### Non-interactive / CI mode

```bash
sudo ./cmkupdate.sh --yes
```

Skips all confirmation prompts. Use with caution -- the script will proceed through backup, download, install, and site restart without asking.

### Self-test

```bash
./cmkupdate.sh --self-test
```

Validates script syntax and checks that all required commands are available. Does not modify anything on the system. Does not require root.

---

## What to Expect

The script runs through 7 numbered phases with semantic output prefixes (`[OK]`, `[INFO]`, `[WARN]`, `[ERROR]`):

```
==> [1/7] Checking prerequisites
[OK]      All dependencies satisfied.

==> [2/7] Checking for updates
[OK]      Script is up to date (1.3.0).

==> [3/7] Detecting Checkmk site
[OK]      Disk space: 18432 MB available.
[INFO]    Installed: 2.3.0p24
[INFO]    Available: 2.3.0p25

  Update Summary
  ──────────────────────────────────────────
  Site:                  mysite
  Current version:       2.3.0p24
  Target version:        2.3.0p25
  Backup location:       /var/backups/checkmk
  ──────────────────────────────────────────

==> [4/7] Creating backup
[OK]      Site stopped.
[OK]      Backup created: /var/backups/checkmk/mysite_20250601_140000.omd.gz (312 MB)

==> [5/7] Downloading update
[OK]      SHA256 checksum verified.

==> [6/7] Installing update
[OK]      Package installed.
[OK]      omd update completed.

==> [7/7] Verifying and starting site
[OK]      Site started.

  ╔══════════════════════════════════════════╗
  ║            Update Complete                ║
  ╚══════════════════════════════════════════╝
  Site:                  mysite
  Previous version:      2.3.0p24
  New version:           2.3.0p25
  Backup:                /var/backups/checkmk/mysite_20250601_140000.omd.gz (312 MB)
  Site status:           Running
  Duration:              4m 23s
```

---

## Backup Behavior

1. The script **stops the site** before creating the archive to ensure data consistency.
2. Available space in `/var/backups/checkmk` is checked against the uncompressed site size estimate.
3. `omd backup` writes a compressed archive while the script displays **live progress** (current MB, percentage relative to estimate, elapsed time).
4. The final backup path and size are shown in both the console output and the debug log.

Backups are stored in `/var/backups/checkmk` with the naming pattern:

```
<SITE>_<YYYYMMDD>_<HHMMSS>.omd.gz
```

---

## Restore from Backup

1. Locate the backup in `/var/backups/checkmk`:
   ```bash
   ls -lh /var/backups/checkmk/
   ```
2. Restore with `omd restore` (requires root):
   ```bash
   omd restore <SITE_NAME> /var/backups/checkmk/<FILE>.omd.gz
   ```
3. Start the site:
   ```bash
   omd start <SITE_NAME>
   ```

---

## Troubleshooting

**Debug log location** -- The log path is printed at startup and uses a secure temp directory. Look for the `[INFO] Debug log:` line in the script output, for example:

```
[INFO]    Debug log: /tmp/cmkupdate.XXXXXXXXXX/checkmk_update_debug.log
```

Follow it live during a run:

```bash
tail -f /tmp/cmkupdate.*/checkmk_update_debug.log
```

**Step failures** -- If any phase fails, the script shows a contextual error message explaining the consequences and asks whether to continue (unless `--yes` is set).

**Unexpected exit** -- The EXIT trap automatically restarts the site if it was stopped and the script exits before completing. The debug log is preserved even after temp file cleanup.

**Dependency issues** -- Run `./cmkupdate.sh --self-test` to verify that all required commands are available.

---

## What's New in v1.3.0

### Security

- SHA256 checksum verification of downloaded `.deb` packages.
- Secure temp directory via `mktemp -d` with restricted permissions (`chmod 700`).
- HTTPS enforcement (`--proto =https`) on all `curl` calls.
- Shebang validation on self-update downloads.

### CLI

- New `--yes` / `-y` flag to skip all interactive confirmations (automation/CI).
- New short flags: `-h` for `--help`, `-t` for `--self-test`.

### UX

- 7 numbered phases with clear `==> [N/7]` headers.
- Semantic output prefixes: `[OK]`, `[ERROR]`, `[WARN]`, `[INFO]` with color coding.
- `NO_COLOR` environment variable support (see [no-color.org](https://no-color.org)).
- Spinner animations for long-running background operations.
- Pre-update confirmation summary box.
- Post-update completion summary with version diff, backup size, site status, and elapsed time.
- Contextual error messages that explain consequences of continuing.
- EXIT trap auto-restarts the site on unexpected script exit.

### Bug Fixes

- Debug log uses append (`>>`) instead of overwrite -- no more accidental log loss.
- Correct `omd version <SITE>` for site-specific version detection.
- Edition suffix stripping (`.cre`, `.cee`) for accurate version comparison.
- Self-update URL now matches the actual repository filename.
- Safe array parsing via `mapfile -t` for the site list.

---

## Disclaimer

This script is provided "as is" without warranty of any kind. Use it at your own risk and always test in a staging environment before running against production systems.
