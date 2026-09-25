# Homelab Plan v2: FOSS-first rebuild

Plan for moving the current Windows + Google Drive setup to a Linux homelab that uses
free and open-source software (FOSS) wherever a real FOSS option exists. Plex stays
because it's the requirement. Everything else is FOSS.

*Written September 2026; prices checked September 2026. Check "Open decisions" (§12) before buying anything.*

---

## 0. Starting point

| Piece | Today |
|---|---|
| Host | Windows, services run through NSSM, everything lives under `C:\rclone` and `C:\ProgramData\NzbDrone` |
| New server | A spare PC currently running Unraid. Specs pending: run `host/inventory.sh` (§2) |
| Library | About 14 TB of media, played from an rclone crypt mount of Google Drive (`M:`); local X/B drives for seeding |
| Pipeline | Ombi → Sonarr/Radarr → Jackett → Deluge (labels route files to X or B) → copy to `M:` → Plex scans |
| Cloud | Google Drive and Backblaze. Both work, both cost more than you'd like |
| Remote viewers | Two households outside your network (parents, sister) |
| Extras | Tautulli |
| Open goals | nightly uploads, domain + login page, web troubleshooting, daily logs, move to Linux, drive pool / 12 TB RAID 5, backups of A/B/C/X, VPN tunnel |

Section 11 shows where each open goal ends up.

---

## 1. Guiding decisions

1. **Local disks hold the live library. Google Drive and Backblaze become cold storage.**
   Nothing plays from the cloud any more. The clouds only receive a nightly upload, and you read from
   them only to restore. A cloud mount as the live library is the root cause of most problems in these notes:
   API rate limits, the 750 GB/day upload cap, Plex scans hammering the mount, and outages like the
   Rick and Morty one on May 18.
2. **Each cloud holds the data it's cheapest for.** Backblaze B2 bills per TB, so it holds only small,
   irreplaceable data. Google Drive is a flat-rate plan, so it holds the copy of the media library. See §8.
3. **Plex stays, and Jellyfin runs next to it on the same files.** Family streaming from outside your home now
   requires a Plex Pass or per-viewer Remote Watch Passes (§6). Jellyfin does remote streaming and hardware transcoding
   for free. If both households are happy on Jellyfin, you can drop Plex Pass at renewal and be fully FOSS.
4. **Treat config as code.** Every service is defined in Docker Compose files kept in this repo.
5. **Keep the internet-facing surface small.** Only the apps family uses (Plex, Jellyfin, Seerr) and your VPN can be
   reached from outside. Admin tools are VPN-only.

---

## 2. Hardware: the spare Unraid PC

The spare PC becomes the server. What it needs:

| Part | Need | If it falls short |
|---|---|---|
| CPU / GPU | Hardware transcoding: Intel Quick Sync, 7th gen or newer (11th gen+ also decodes AV1) | Add an Intel Arc A310 (small, cheap, FOSS Linux drivers, AV1 encode). AMD CPUs without an iGPU need this |
| RAM | 16 GB minimum, 32 GB comfortable | Add RAM; the report shows free slots |
| Boot/app drive | SSD or NVMe for Debian, Docker appdata, Plex/Jellyfin metadata | The NVMe from the old notes |
| Download landing | The spare 1 TB SSD | This is your "1 TB as cache" idea: torrents write to SSD, finished files move to the HDD pool |
| Bulk storage | The existing Unraid disks, plus room to grow (§3) | |
| UPS | Any small UPS supported by NUT | Protects against unclean shutdowns and parity corruption |

Transcoding matters more now because of family streaming. Remote streams are usually bitrate-capped, so the server
re-encodes video on the fly. Without hardware transcoding, one 4K or HEVC stream can max out the CPU.

### Get the specs without guessing

`host/inventory.sh` is read-only. It reports:

- CPU, iGPU and RAM, including free RAM slots
- disk models, sizes and SMART health
- the Unraid array layout: which disk is parity, each disk's filesystem, and whether it's encrypted
- space used per share
- running containers and VMs

On Unraid, open the web terminal (the `>_` icon), then either:

```bash
# Repo public: download and run
curl -fsSL https://raw.githubusercontent.com/mrab1168/Plex-Personal-Server/main/host/inventory.sh | bash

# Repo private: paste the script's contents into nano, save, then run it
nano /tmp/inventory.sh
bash /tmp/inventory.sh
```

The report is saved to `/boot/homelab-inventory.txt` on the Unraid flash drive, which is reachable at `\\TOWER\flash` if that share is enabled.

---

## 3. Storage layout

**mergerfs + SnapRAID** (both FOSS). Unraid's array works the same way, so your disks carry straight over (§4):

| Unraid | Here |
|---|---|
| Each data disk has its own filesystem | Same. The disks keep their data |
| One or two dedicated parity disks | SnapRAID parity disk(s) |
| User shares merge the disks (`/mnt/user`) | mergerfs pool (`/mnt/storage`) |

Differences from Unraid:

- SnapRAID computes parity on a schedule (nightly), not on every write. Files added since the last sync aren't
  protected yet. That's fine for media, which is written once and read many times.
- If more drives fail than parity covers, you lose only the files on those drives.
- Rule (same as Unraid): the parity disk must be at least as large as the largest data disk.

**Sizing:** with about 14 TB of media, aim for about 20 TB or more usable so you have room to grow. For example,
2 × 12 TB data + 1 × 12 TB parity gives 24 TB usable. Keep your existing disks as data disks. Add bigger ones
later, one at a time.

**Alternative: ZFS RAIDZ.** It gives real-time redundancy and checksums but works best with identical drives. If you
add Immich or Paperless later, consider a small ZFS mirror just for that data.

**RAID/parity is not a backup.** See §8.

### Folder layout (one tree, so hardlinks work)

```
/mnt/storage/data            ← mergerfs pool
├── torrents/
│   ├── tv/  movies/  books/
├── media/
│   ├── tv/  movies/  books/  audiobooks/
└── ingest/
    └── books/               ← drop folder watched by Calibre-Web-Automated

/srv/appdata/<service>/      ← on the NVMe, backed up nightly
```

Every container mounts `/mnt/storage/data` as `/data`. The *arrs then **hardlink** finished downloads into
`media/` instead of copying them, so imports are instant and seeding files use no extra space. This replaces the
Deluge-label X/B drive split. Use a path-preserving mergerfs create policy so hardlinks stay on one disk
([TRaSH Guides](https://trash-guides.info/) documents the exact mergerfs settings).

---

## 4. Operating system

**Recommendation: Debian 13 "Trixie" + Docker Engine + Docker Compose + Cockpit.**

- Stable, fully FOSS, and needs little babysitting.
- **Cockpit** gives you a browser UI for the server: terminal, logs, services, storage, updates.
  This covers the "VNC troubleshoot via web" goal.

Unraid isn't FOSS, and everything it does here has a FOSS equivalent:

| Unraid feature | Replacement |
|---|---|
| Array | mergerfs + SnapRAID |
| Docker tab | Docker Compose |
| Web UI | Cockpit |

Other FOSS options:

| Option | Pick it if |
|---|---|
| OpenMediaVault | You want an Unraid-style GUI (it has mergerfs, SnapRAID and Compose plugins). It's Debian underneath |
| Proxmox VE | You run VMs on Unraid today and want to keep doing that |

### Moving off Unraid without copying data

Each Unraid data disk is a normal filesystem (usually XFS, sometimes btrfs or ZFS). Debian can mount these as-is.

1. **Before touching anything:**
   - Run `host/inventory.sh` to record which disk is parity.
   - Take a flash backup (Main → Flash → Flash Backup).
   - If Unraid runs Docker containers, copy `/mnt/user/appdata` somewhere safe. linuxserver.io images can reuse those configs.
2. **Install Debian on the SSD/NVMe, not on the Unraid USB stick.** Leave the stick alone so you can boot back into
   Unraid if something goes wrong. If that SSD is Unraid's cache pool, copy anything on it that you need first.
3. **Mount the old data disks read-only** in Debian and check the files are there. Then remount them read-write
   and add them to the mergerfs pool.
   - Encrypted disks show `luks` in the report. Unlock them with `cryptsetup` using your Unraid passphrase or keyfile.
   - ZFS disks import with `zpool import`.
4. **Format the old parity disk.** It has no filesystem. Make it the SnapRAID parity disk and run the first
   `snapraid sync`. Until that finishes you have no parity, so confirm the Google Drive copy is complete first.
5. **Going back to Unraid later?** Once Debian writes to the disks, Unraid's parity is stale. Run a parity sync after booting back.

---

## 5. Service map

| Role | Today | Plan | FOSS | Notes |
|---|---|---|---|---|
| Media server | Plex | **Plex** + **Jellyfin** | Plex ✗ / Jellyfin ✓ | Both read the same `/data/media` read-only. Family setup in §6 |
| Requests | Ombi | **Seerr** | ✓ | Overseerr + Jellyseerr merged into Seerr (Feb 2026). Family signs in with their Plex accounts and requests shows themselves |
| TV / Movies | Sonarr / Radarr | **Sonarr / Radarr** | ✓ | Add **Recyclarr** to sync TRaSH quality profiles |
| Indexers | Jackett | **Prowlarr** | ✓ | Pushes indexers into every *arr automatically. Add FlareSolverr only if needed |
| Downloads | Deluge | **qBittorrent** (keeping Deluge is fine) | ✓ | Runs inside **Gluetun** so all torrent traffic goes through your VPN provider. Categories replace the Deluge label logic |
| Subtitles | none | **Bazarr** | ✓ | |
| Stats | Tautulli | **Tautulli** (Plex) + **Jellystat** (Jellyfin) | ✓ | Shows which family streams are transcoding and why |
| Ebooks | none | **Calibre-Web-Automated** | ✓ | Auto-imports anything dropped in `ingest/books`, converts formats, fixes metadata, and does Kobo sync and OPDS |
| Audiobooks / podcasts | none | **Audiobookshelf** | ✓ | Has good mobile apps and keeps listening progress in sync |
| Comics / manga (optional) | none | **Kavita** | ✓ | |
| Book automation (optional) | none | **LazyLibrarian** | ✓ | Readarr is retired because its metadata source died |
| Reverse proxy | none | **Caddy** + **CrowdSec** | ✓ | Automatic HTTPS on your domain; CrowdSec blocks brute-force attempts on public apps |
| Login page / SSO | none | **Authelia** | ✓ | 2FA in front of web UIs you expose. Not in front of Plex, Jellyfin, Seerr or Audiobookshelf: their apps can't get through it |
| Remote access (you) | OpenVPN (planned) | **WireGuard** via wg-easy | ✓ | For admin access. Family doesn't need it |
| Web admin | VNC idea | **Cockpit** | ✓ | |
| Dashboard | none | **Homepage** | ✓ | |
| Monitoring | none | **Uptime Kuma** + **Beszel** | ✓ | Uptime alerts, plus CPU, disk and temperature history |
| Backups | Backblaze, Google Drive | **restic** + **Backrest** UI, **rclone** | ✓ | Cold-storage design in §8 |
| DNS / ad-block (optional) | none | **AdGuard Home** | ✓ | Also provides split DNS so `*.home.yourdomain` resolves locally |

**Later, if you want:** Immich (photos), Paperless-ngx (documents), Vaultwarden (passwords), Syncthing, Home Assistant.

---

## 6. Family streaming

### Paying for remote play (prices as of September 2026)

| Option | Cost | Covers |
|---|---|---|
| Plex Pass on your account, yearly | $69.99/yr | Every remote viewer on your server, plus hardware transcoding |
| Plex Pass, 5-year | $249.99 (≈ $50/yr) | Same |
| Plex Pass, lifetime | $749.99 since July 2026 | Same. Not worth it compared with the 5-year plan |
| Remote Watch Pass, per viewer account | $29.99/yr each | Just that viewer. You still don't get hardware transcoding |
| Jellyfin | $0 | Everything, including hardware transcoding |

**Recommendation:**

1. Buy a **yearly** Plex Pass when family starts streaming from the new server.
2. Set up Jellyfin alongside it and try it with one household first.
3. If both households are happy on Jellyfin, let the Plex Pass lapse. You're then fully FOSS.

### Their devices decide how easy Jellyfin is

| Device | Plex | Jellyfin |
|---|---|---|
| Roku | ✓ | ✓ official app |
| Fire TV / Android TV / Google TV | ✓ | ✓ official app |
| Apple TV | ✓ | ✓ Swiftfin (FOSS) or Infuse |
| LG TV | ✓ | ✓ official app |
| Samsung TV | ✓ | ⚠ historically needed sideloading; check their TV's app store |
| Phone / browser | ✓ | ✓ |

If a household has a Samsung TV, a ~$30 streaming stick makes Jellyfin painless.

### Your upload speed is the limit

- Budget about 8–10 Mbps of **upload** per 1080p stream. If both homes watch at once, you need about 25 Mbps of upload with headroom.
- Many cable plans only give 20–35 Mbps upload; fiber is usually symmetric. Run a speed test and look at the upload number.
- Cap remote quality so one 4K file can't use all of it. In Plex this is a server-wide limit under Settings → Remote Access. In Jellyfin, set an internet streaming bitrate limit for each user.

### How they connect

Their TV apps can't use a VPN (Roku can't run WireGuard at all), so the family-facing apps have to be reachable from the internet:

- **Plex:** forward TCP 32400 on your router. Plex's relay fallback is bandwidth-capped, so without the port forward, quality suffers.
- **Jellyfin:** publish it at `https://watch.yourdomain.com` through Caddy, with CrowdSec in front and a strong password per user.
- **Seerr:** publish it at `https://requests.yourdomain.com`. Family signs in with their Plex accounts.
- **If your ISP uses CGNAT** (§7), none of this works directly. Rent a small VPS (a few dollars a month) and tunnel through it with WireGuard or Pangolin (FOSS).
  Avoid Cloudflare Tunnel for video; their terms restrict it.

---

## 7. Networking and security

- **Port forwards:**

  | Port | For |
  |---|---|
  | TCP 32400 | Plex, family |
  | TCP 443 | Caddy: Jellyfin, Seerr and anything else family uses |
  | UDP 51820 | WireGuard, you |

  Nothing else. The *arrs, qBittorrent, Cockpit and other admin UIs are reachable only on your LAN or over WireGuard.
  The ports in `Backend/ports` become internal-only.
- **Check for CGNAT first.** If the WAN IP on your router doesn't match what whatismyip reports, port forwarding won't work (see §6).
- **Internal HTTPS:** Caddy with a DNS-01 challenge gets a wildcard cert for `*.home.yourdomain`
  without exposing anything. AdGuard Home points those names at the server's LAN IP.
- **Torrent client:** reachable only through Gluetun, with a kill switch so traffic can't leak.
- **Secrets:** keep them in `.env` files that are in `.gitignore`. This repo is on GitHub.

---

## 8. Backups and cold storage (covers "Matt Todo" 1–4)

### What goes where

| Data | Size (est.) | Local | Google Drive | Backblaze B2 |
|---|---|---|---|---|
| Media library | ~14 TB | mergerfs pool + SnapRAID | ✓ encrypted rclone copy, nightly | ✗ too expensive per TB |
| Irreplaceable files (photos, documents) | < 1 TB | pool | ✓ restic | ✓ restic |
| Appdata (Plex DB, *arr DBs, configs) | < 100 GB | NVMe | ✓ restic | ✓ restic |
| Compose files | tiny | this repo | GitHub | — |

Irreplaceable data ends up with three copies in three places. Media gets two copies (local + Google), which is enough for files you could re-download.

### Why this split

| Service | Price (Sept 2026) | 14 TB of media costs |
|---|---|---|
| Backblaze B2 | $6.95/TB/month | ~$97/month |
| Google One | 10 TB $49/month, 20 TB $99/month (flat) | $99/month (needs the 20 TB plan) |

If both clouds hold a full copy of the media today, you're paying about $196/month for two copies of replaceable
files. Moving media out of B2 cuts that bill to a few dollars a month (e.g. 500 GB ≈ $3.50). Google Workspace plans
price differently; the same logic applies.

**Before deleting anything from B2:** confirm the local pool is healthy, SnapRAID has synced, and the Google copy
passes `rclone check`.

**If "Backblaze" is the flat-rate Personal Backup plan rather than B2:** that plan only runs on Windows and Mac,
so it won't carry over to Linux. B2 or the family box below replaces it.

### Cheaper later: a backup box at family's house

Put a small computer and one large HDD at your parents' or sister's house:

- It connects out to your server over WireGuard or Headscale, so their router needs no changes.
- Fill it at your place first, because 14 TB over the internet takes weeks. Then drop it off.
- After that, nightly rclone and restic runs keep it current.

It costs the price of the drive and a small computer once, instead of a monthly fee. Once it's running, you can
drop Google to the 2 TB plan ($9.99/month) for irreplaceable data only. The total cloud bill ends up around $15/month.

### Nightly cold-storage upload (old goal (a) is back)

```bash
# host/scripts/cold-sync.sh (sketch; run once per folder: tv, movies)
rclone sync /mnt/storage/data/media/tv "Google_Crypt:Plex/TV Shows" \
  --backup-dir "Google_Crypt:_deleted/$(date +%F)" \
  --max-delete 200 \
  --max-transfer 700G --cutoff-mode soft \
  --drive-stop-on-upload-limit \
  --log-level INFO
```

- **Target the existing cloud folders** (`Plex/TV Shows`, `Plex/Movies`). rclone sees the files are already there and
  uploads only new ones, so nothing re-uploads. This works because files pulled down with `rclone copy` keep their size and modtime.
- **`--backup-dir`** moves files that were deleted or replaced locally into `_deleted/` instead of erasing them. Prune it monthly.
- **`--max-delete`** stops the job if a failed disk makes hundreds of files look deleted.
- **`--max-transfer 700G`** stays under Google's 750 GB/day upload cap.
- **Big rename (goal h):** do it before the first cold sync. Run that sync with `--dry-run` first so you can see
  what rclone would re-upload. Adding `--track-renames --track-renames-strategy modtime` lets rclone move files in
  the cloud instead of re-uploading them.

### restic for everything irreplaceable

- restic to B2 (native backend) and to Google Drive (through rclone: `rclone:gdrive:restic`). restic already
  encrypts, so point it at a plain remote, not the crypt one.
- Retention: `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune`.
- Backrest gives restic a web UI, schedules and alerts.

### Scheduling, parity, logs

- **systemd timers, not cron**, because they handle time zones and DST. Your notes list 2:30 AM PST as 07:30 UTC.
  It's actually **10:30 UTC in winter (PST)** and **09:30 UTC in summer (PDT)**. Put the time zone in the timer and systemd handles DST:

  ```ini
  # /etc/systemd/system/cold-sync.timer
  [Timer]
  OnCalendar=*-*-* 02:30:00 America/Los_Angeles
  Persistent=true

  [Install]
  WantedBy=timers.target
  ```

- **SnapRAID:** nightly `sync`, weekly partial `scrub`, run after the backup window.
- **Test a restore every quarter.** A backup you've never restored from is unverified.
- **Logs** (goal e): journald keeps and rotates logs per service (`journalctl -u cold-sync`). You don't need a daily log-file script.

---

## 9. Books and Anna's Archive

The library side works with files from any source: CWA picks up whatever lands in `ingest/books`, and
Audiobookshelf picks up whatever lands in `media/audiobooks`.

I didn't wire an automated Anna's Archive downloader into this plan, for two reasons:

- **Legal:** most of its catalog is copyrighted books mirrored without permission. Downloading those
  is infringement in the US. In 2026 US courts entered judgments against it, including a
  worldwide domain injunction.
- **Practical:** its domains keep getting suspended, and lookalike "mirror" sites are circulating.
  An automated job that pulls files from whichever domain works this week is a malware and phishing risk
  for your server.

Legitimate sources that fit into the same pipeline:

| Need | Source |
|---|---|
| Classics, well formatted | Standard Ebooks (has an OPDS feed), Project Gutenberg |
| Free audiobooks | LibriVox |
| New books you keep | DRM-free stores (many Kobo titles, publisher stores, Humble Bundle), Libro.fm for audiobooks |
| Borrowing | Your public library via Libby |
| Academic papers | Unpaywall (finds legal open-access copies), arXiv, PubMed Central, or the author's own page |

On an e-reader, **KOReader** (FOSS) can browse CWA's OPDS catalog directly.

---

## 10. Migration phases

Each phase leaves you with a working system. Keep the Windows box running until phase 7.

| Phase | Work | Done when |
|---|---|---|
| **0. Inventory** | Run `host/inventory.sh` on the spare PC. Speed-test your upload. Check cloud contents: `rclone size Google_Crypt:` and your B2 bucket sizes. Download Sonarr/Radarr backup zips (System → Backup). Turn on Plex's watch-state sync | You know the specs, the TB to move, and your upload speed |
| **1. Base** | Install Debian 13 on the spare PC's SSD (leave the Unraid stick alone). Bring over the Unraid data disks (§4). Set up mergerfs and SnapRAID on the old parity disk, and create the folder layout | `/mnt/storage/data` exists; first `snapraid sync` passes |
| **2. Pull library home** | `rclone copy Google_Crypt: /mnt/storage/data/media -P --transfers 4` for whatever isn't already on the Unraid disks. Google caps downloads at about 10 TB/day | `rclone check` passes |
| **3. Media stack** | Plex (hardware transcoding on), Jellyfin, Sonarr/Radarr (restore backups, update root folders to `/data/media/...`), Prowlarr, qBittorrent + Gluetun, Seerr, Bazarr, Tautulli | Request → download → hardlink → shows up in Plex and Jellyfin |
| **4. Access + family** | Domain DNS, Caddy + CrowdSec, WireGuard, port forwards (§7). Test from your phone on cellular. Then invite family: Plex share, Jellyfin accounts, Seerr | Both households can play something on their TVs |
| **5. Books** | Calibre-Web-Automated, Audiobookshelf, optionally Kavita / LazyLibrarian | A file dropped in `ingest/books` shows up in CWA and on your e-reader |
| **6. Ops + cold storage** | restic + Backrest to B2 and Google; cold-sync timer to Google; SnapRAID schedule; Uptime Kuma, Beszel, Homepage. Once everything's verified, remove the media copy from B2 | A restore test passes; the B2 bill drops |
| **7. Retire** | Shut down NSSM services and the `M:` mount; wipe or repurpose the Windows box. Optional: family backup box, then shrink the Google plan | Nothing depends on Windows |

### Proposed repo layout

```
compose/
  media/compose.yaml     # plex, jellyfin, *arrs, prowlarr, qbittorrent+gluetun, seerr, bazarr, tautulli
  books/compose.yaml     # calibre-web-automated, audiobookshelf, kavita
  access/compose.yaml    # caddy, crowdsec, authelia, wg-easy, adguardhome
  ops/compose.yaml       # backrest, uptime-kuma, beszel, homepage
  .env.example
host/
  inventory.sh           # read-only spec report (§2)
  snapraid.conf
  mergerfs.fstab
  scripts/cold-sync.sh
  systemd/               # cold-sync, restic and snapraid timers
HOMELAB-PLAN.md          # this file
```

---

## 11. Where each old goal ends up

| Old goal | Resolution |
|---|---|
| a) Upload only at 2:30 AM Pacific | Nightly cold-storage upload to Google Drive on a systemd timer at that time (§8) |
| b) Login page on personal domain | Caddy + Authelia, and CrowdSec for the public apps (§5, §7) |
| c) Web-based troubleshooting | Cockpit |
| d) Learn rclone cache | No longer needed; rclone isn't in the playback path |
| e) Daily rclone logs via NSSM | journald (§8) |
| f) Rick and Morty outage, May 18 | Almost certainly the Google Drive mount; that failure mode goes away |
| g) Move to Linux, pool drives, 12 TB RAID 5 | Debian 13 + mergerfs + SnapRAID on the spare PC (§3, §4) |
| h) Rename everything | Single `/data` tree (§3); do it before the first cold sync (§8) |
| Todo 1–4: daily drive backups | restic + Backrest to B2 and Google Drive (§8) |
| Todo 5: OpenVPN tunnel | WireGuard (§5, §7) |

---

## 12. Open decisions

1. **Spare PC specs:** run `host/inventory.sh` and share the report.
2. **Upload speed** at your house. This decides how many family streams can run at once, and at what quality.
3. **Family devices:** what do your parents and sister watch on (Roku, Fire TV, Apple TV, smart TV brand)?
4. **Backblaze:** is it B2 or the Personal Backup plan, and does it hold a full copy of the media?
5. **Family backup box:** would your parents or sister be OK hosting a small, quiet box on their network?
