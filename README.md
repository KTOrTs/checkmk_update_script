# Checkmk Update Script

Interactive update helper for **Checkmk Raw Edition** OMD sites on Debian/Ubuntu.

- Default: terminal TUI (progress, confirmations, phase tracker)
- Automation: `--yes --no-ui`
- Backup is enabled by default (recommended)

## Highlights

- 7-phase guided run (prereqs, site detection, backup, download, install, update, verify)
- Pre-flight safety checks: APT/DPKG locks, `dpkg --audit`, download URL + temp space, backup destination free space
- Backup with live progress to `/var/backups/checkmk` (can be skipped with `--no-backup`, not recommended)
- Non-interactive OMD update (uses `omd --force ... update --conflict=install` to avoid prompts)
- Preserves initial site state (won't auto-start a site that was stopped before the run)
- Secure temp directory + debug log path printed at startup
- `NO_COLOR` supported (disable colored output)

## Suitable For

- Updating Checkmk **Raw** sites (edition `.cre`) managed by `omd`
- Single-host updates where you want a guided flow with safety checks
- CI/automation where you want a non-interactive run that fails fast on unsafe conditions

## Not Suitable For

- Checkmk Enterprise/managed editions (`.cee`, `.cme`, `.cce`) (the script aborts)
- Environments that require package checksum verification (the script does **not** verify checksums)

## Quick Start

```bash
git clone https://github.com/KTOrTs/checkmk_update_script.git
cd checkmk_update_script
chmod +x cmkupdate.sh
./cmkupdate.sh
```

Non-interactive example:

```bash
./cmkupdate.sh --yes --no-ui
```

Dry-run (download only, no changes):

```bash
./cmkupdate.sh --dry-run --no-ui
```

## Requirements

| Requirement | Details |
|---|---|
| OS | Debian / Ubuntu |
| Checkmk | Raw Edition site(s) managed by `omd` (edition `.cre`) |
| Privileges | Root for a real update. `--self-test` and `--dry-run` can run without root. |
| Network | HTTPS access to `checkmk.com` and `download.checkmk.com` (and `api.github.com` / `raw.githubusercontent.com` for self-update). |
| Disk space | `/opt/omd`: >= 2 GB free recommended. Backup dir `/var/backups/checkmk`: roughly >= site size (uncompressed estimate). Temp dir: roughly >= `.deb` size + buffer. |
| Required commands | `omd`, `lsb_release`, `curl`, `dpkg`, `awk`, `grep`, `df`, `sort`, `sed`, `find`, `du`, `stat`, `ps`, `tee` |
| Optional (better diagnostics) | `lsof` or `fuser` (shows lock holders for APT/DPKG locks) |

Missing dependencies (except `omd`) are installed automatically via `apt-get` on real runs. `--dry-run` and `--self-test` never install packages.

## Supported CLI Options

| Option | Meaning |
|---|---|
| `-h, --help` | Show help and exit |
| `-t, --self-test` | Syntax + dependency check (no changes) |
| `-d, --dry-run` | Download target package only (no stop/backup/install/update) |
| `-n` | Alias for `--dry-run` |
| `-b, --no-backup` | Skip `omd backup` (not recommended) |
| `-y, --yes` | Skip confirmations (automation/CI) |
| `--no-ui` | Disable the TUI for this run (plain prompts) |

## Examples

Interactive (recommended):

```bash
./cmkupdate.sh
```

Automation/CI (no prompts, no TUI):

```bash
./cmkupdate.sh --yes --no-ui
```

Dry-run (download only, keep the `.deb` in the temp directory):

```bash
./cmkupdate.sh --dry-run --no-ui
```

Skip backup (not recommended):

```bash
./cmkupdate.sh --no-backup
```

Disable colors:

```bash
NO_COLOR=1 ./cmkupdate.sh --no-ui
```

## What The Script Does

The run is split into 7 phases:

1. **Prerequisites**: checks for APT/DPKG locks and `dpkg --audit` issues.
2. **Script update check**: checks GitHub Releases for a newer version.
3. **Site detection**: selects an OMD site and validates it is Raw Edition (`.cre`).
4. **Stop + backup**: stops the site (only if it was running when the script started) and runs `omd backup` into `/var/backups/checkmk` unless `--no-backup` is set.
5. **Download**: downloads the matching `.deb` for your distro codename + architecture.
6. **Install + update**: `dpkg -i` and then runs a non-interactive OMD update:
   - `omd --force -V "<LATEST_VERSION>.cre" update --conflict=install "<SITE>"`
7. **Verify**: starts the site if it was running initially. If the site was stopped initially, it stays stopped and the script asks whether to start it.

## Backup & Restore

Backups are stored under `/var/backups/checkmk` and can be restored with:

```bash
omd restore <SITE_NAME> /var/backups/checkmk/<FILE>.omd.gz
omd start <SITE_NAME>
```

## Debugging & Troubleshooting

- The script prints a **debug log path** at startup, e.g. `/tmp/cmkupdate.*/checkmk_update_debug.log`.
- If you hit APT/DPKG lock errors: wait for `unattended-upgrades` / `apt` to finish and re-run.
- If `dpkg --audit` reports issues: fix with `dpkg --configure -a` and `apt-get -f install` before retrying.

## Self-Update Notes

- Self-update checks GitHub **Releases** (`/releases/latest`).
- Your release tags can be like `1.4.0` (no leading `v`). The script uses the release tag to download `cmkupdate.sh` from that tag.

## Release Notes

See `RELEASE_NOTES.md`.

## License

MIT (see `LICENSE`).
