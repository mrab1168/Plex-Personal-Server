# Homelab Plan v2: FOSS-first rebuild

Plan for moving the current Windows + Google Drive setup to a Linux homelab that uses
free and open-source software (FOSS) wherever a real FOSS option exists. Plex stays
because it's the requirement. Everything else is FOSS.

*Written September 2026. Check the "Open decisions" section before buying anything.*

---

## 0. Current setup (from the notes in this repo)

| Piece | Today |
|---|---|
| Host | Windows, services run through NSSM, everything lives under `C:\rclone` and `C:\ProgramData\NzbDrone` |
| Library storage | rclone crypt mount of Google Drive as `M:` (the FUSE mount), local X/B drives for seeding |
| Pipeline | Ombi → Sonarr/Radarr → Jackett → Deluge (labels route files to X or B) → copy to `M:` → Plex scans |
| Extras | Tautulli |
| Open goals | nightly uploads, domain + login page, web troubleshooting, daily logs, move to Linux, drive pool / 12 TB RAID 5, backups of A/B/C/X, VPN tunnel |

Section 10 shows where each open goal ends up.

---

## 1. Guiding decisions

1. **Keep your library on local disks. Use the cloud only for encrypted backups.**
   A Google Drive mount as the live library is the root cause of most problems in these notes:
   API rate limits, the 750 GB/day upload cap, Plex scans hammering the mount, and
   unexplained outages like the Rick and Morty one on May 18. Keep the rclone crypt remote and reuse it for backups.
2. **Plex is the one proprietary exception. Run Jellyfin next to it on the same files.**
   Plex now requires a Plex Pass (the admin's) or a Remote Watch Pass (the viewer's)
   for remote streaming, and hardware transcoding needs a Plex Pass. Jellyfin does both for free.
   Running both costs no extra disk space, and you can decide later whether to drop Plex.
3. **Treat config as code.** Every service is defined in Docker Compose files kept in this repo,
   so the repo holds the actual setup instead of notes about it.
4. **Keep the internet-facing surface small.** Only the VPN (and Plex, if you want direct remote play) gets a
   forwarded port. Everything else sits behind the VPN, or behind a reverse proxy with SSO and 2FA.

---

## 2. Hardware

One box is enough.

| Part | Recommendation | Why |
|---|---|---|
| CPU | Intel with Quick Sync: **N100/N305** (low power, 1–3 transcodes) or **i5-12500 / 13500** (more headroom) | Hardware transcoding for Plex and Jellyfin. Intel iGPUs have the best Linux support for this |
| RAM | 16 GB minimum, 32 GB comfortable | Enough for the *arrs, Jellyfin, Immich later, and ZFS/page cache |
| Boot/app drive | The NVMe you already have | OS, Docker appdata, Plex/Jellyfin metadata, transcode temp |
| Download landing | The spare 1 TB SSD | This is your "1 TB as cache" idea: torrents write to SSD, finished files move to the HDD pool |
| Bulk storage | 3–5 HDDs (see §3) | Media |
| UPS | Any small UPS supported by NUT | Protects against unclean shutdowns and parity corruption |

If the current Windows PC has an Intel 7th-gen or newer CPU, reuse it. Buy only drives.

---

## 3. Storage layout

**Recommended for media: mergerfs + SnapRAID** (both FOSS).

- **mergerfs** pools disks of any size into one mount (`/mnt/storage`). This replaces the "drive pooling" goal.
- **SnapRAID** keeps parity on one disk (two for 6+ disks) and syncs nightly. It gives RAID-5-style protection, and
  - drives can be mixed sizes and added one at a time
  - if more drives fail than parity covers, you lose only the files on those drives, not the whole array
  - drives that aren't being read can spin down
- Tradeoff: protection isn't real-time. Files added since the last sync aren't covered. That's fine for media, which is written once and read many times.
- Rule: the parity drive must be at least as large as the largest data drive.

Example matching the 12 TB goal: **3 × 12 TB data + 1 × 12 TB parity = 36 TB usable**. Or start at
**1 data + 1 parity** and add data drives as you grow.

**Alternative: ZFS RAIDZ1/RAIDZ2.** It gives real-time redundancy, checksums and snapshots, but works best with
identical drives. It's the better choice for irreplaceable data (photos, documents). If you add
Immich or Paperless later, consider a small ZFS mirror just for that data.

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

Every container mounts `/mnt/storage/data` as `/data`. The *arrs then **hardlink** finished downloads
into `media/` instead of copying them, so imports are instant and seeding files use no extra space. This replaces the
Deluge-label X/B drive split. Use a path-preserving mergerfs create policy so hardlinks
stay on one disk ([TRaSH Guides](https://trash-guides.info/) documents the exact mergerfs settings).

---

## 4. Operating system

**Recommendation: Debian 13 "Trixie" + Docker Engine + Docker Compose + Cockpit.**

- Stable, fully FOSS, and needs little babysitting. Every homelab guide covers it.
- **Cockpit** gives you a browser UI for the server: terminal, logs, services, storage, updates.
  This covers the "VNC troubleshoot via web" goal. A headless Linux server doesn't need a desktop or VNC.

Alternatives, all FOSS:

| Option | Pick it if |
|---|---|
| OpenMediaVault | You want a NAS-style GUI (it has mergerfs, SnapRAID and Compose plugins). It's Debian underneath |
| Proxmox VE | You want to run VMs as well as containers (e.g. a Home Assistant VM, test machines) |
| TrueNAS Community Edition | You go ZFS-first instead of mergerfs + SnapRAID |

Unraid was left out because it isn't FOSS.

---

## 5. Service map

| Role | Today | Plan | FOSS | Notes |
|---|---|---|---|---|
| Media server | Plex | **Plex** + **Jellyfin** | Plex ✗ / Jellyfin ✓ | Both read the same `/data/media` read-only |
| Requests | Ombi | **Seerr** | ✓ | Overseerr + Jellyseerr merged into Seerr (Feb 2026). It supports both Plex and Jellyfin, and family can log in with Plex accounts |
| TV / Movies | Sonarr / Radarr | **Sonarr / Radarr** | ✓ | Add **Recyclarr** to sync TRaSH quality profiles |
| Indexers | Jackett | **Prowlarr** | ✓ | Pushes indexers into every *arr automatically. Add FlareSolverr only if needed |
| Downloads | Deluge | **qBittorrent** (keeping Deluge is fine) | ✓ | Runs inside **Gluetun** so all torrent traffic goes through your VPN provider. Categories replace the Deluge label logic |
| Subtitles | none | **Bazarr** | ✓ | |
| Stats | Tautulli | **Tautulli** (Plex) + **Jellystat** (Jellyfin) | ✓ | |
| Ebooks | none | **Calibre-Web-Automated** | ✓ | Auto-imports anything dropped in `ingest/books`, converts formats, fixes metadata, and does Kobo sync and OPDS |
| Audiobooks / podcasts | none | **Audiobookshelf** | ✓ | Has good mobile apps and keeps listening progress in sync |
| Comics / manga (optional) | none | **Kavita** | ✓ | |
| Book automation (optional) | none | **LazyLibrarian** | ✓ | Readarr is retired because its metadata source died. LazyLibrarian is the maintained option |
| Reverse proxy | none | **Caddy** | ✓ | Automatic HTTPS on your domain |
| Login page / SSO | none | **Authelia** | ✓ | 2FA in front of web UIs. Don't put it in front of Plex or Jellyfin because their TV and phone apps can't handle it |
| Remote access | OpenVPN (planned) | **WireGuard** via wg-easy | ✓ | Faster and simpler than OpenVPN. If your ISP uses CGNAT, use **Headscale** or **NetBird** instead |
| Web admin | VNC idea | **Cockpit** | ✓ | |
| Dashboard | none | **Homepage** | ✓ | One page linking every service, with live status widgets |
| Monitoring | none | **Uptime Kuma** + **Beszel** | ✓ | Uptime alerts, plus CPU, disk and temperature history |
| Backups | none | **restic** + **Backrest** UI | ✓ | See §8 |
| DNS / ad-block (optional) | none | **AdGuard Home** | ✓ | Also provides split DNS so `*.home.yourdomain` resolves locally |

**Later, if you want:** Immich (photos), Paperless-ngx (documents), Vaultwarden (passwords),
Syncthing (file sync), Home Assistant.

---

## 6. Books and Anna's Archive

The library side above works with files from any source: CWA picks up whatever lands in
`ingest/books`, and Audiobookshelf picks up whatever lands in `media/audiobooks`.

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

## 7. Networking and security

- **Port forwards:** WireGuard (UDP 51820). Add Plex 32400 only if you want direct remote play instead of relay.
  The ports in `Backend/ports` become internal-only.
- **Check for CGNAT first.** If the WAN IP on your router doesn't match what whatismyip reports,
  port forwarding won't work. Use Headscale or NetBird, or a small VPS as a relay.
- **Services family uses (Seerr, Audiobookshelf):** Caddy + Authelia with 2FA, or give family members WireGuard.
- **Internal HTTPS:** Caddy with a DNS-01 challenge gets a wildcard cert for `*.home.yourdomain`
  without exposing anything. AdGuard Home points those names at the server's LAN IP.
- **Torrent client:** reachable only through Gluetun, with a kill switch so traffic can't leak.
- **Secrets:** keep them in `.env` files that are in `.gitignore`. This repo is on GitHub.

---

## 8. Backups (covers "Matt Todo" 1–4)

Follow 3-2-1: three copies, on two kinds of media, with one offsite.

| What | How | Where |
|---|---|---|
| Appdata (Plex DB, *arr DBs, configs) | restic, nightly | Local USB disk + offsite |
| This repo (compose files) | git | GitHub |
| Irreplaceable personal files | restic, nightly | Local USB disk + offsite |
| Media | SnapRAID parity covers disk failure | Offsite copy only if re-downloading would be painful |

- **Offsite target:** anything rclone can reach. restic can write through rclone
  (`rclone:remote:path`), so your existing Google Drive or B2 remote works. restic already encrypts,
  so point it at a plain remote, not the crypt one.
- **Scheduling:** use systemd timers, not cron, because they handle time zones and DST. Your notes list 2:30 AM PST
  as 07:30 UTC. It's actually **10:30 UTC in winter (PST)** and **09:30 UTC in summer (PDT)**.
  Put the time zone in the timer and systemd handles DST:

  ```ini
  # /etc/systemd/system/restic-backup.timer
  [Timer]
  OnCalendar=*-*-* 02:30:00 America/Los_Angeles
  Persistent=true

  [Install]
  WantedBy=timers.target
  ```

- **SnapRAID:** nightly `sync`, weekly partial `scrub`, run after the backup window.
- **Test a restore every quarter.** A backup you've never restored from is unverified.
- **Logs** (goal e): journald already keeps and rotates logs per service (`journalctl -u restic-backup`,
  `docker compose logs`). You don't need a daily log-file script.

---

## 9. Migration phases

Each phase leaves you with a working system. Keep the Windows box running until phase 7.

| Phase | Work | Done when |
|---|---|---|
| **0. Inventory** | List drives and sizes; check how much is on Google Drive and whether your plan still covers it; download Sonarr/Radarr backup zips (System → Backup); turn on Plex's watch-state sync | You know how many TB you're moving |
| **1. Base** | Install Debian 13, Docker, Cockpit. SMART-test every drive. Set up mergerfs + SnapRAID and the folder layout | `/mnt/storage/data` exists; first `snapraid sync` passes |
| **2. Pull library home** | `rclone copy Google_Crypt: /mnt/storage/data/media -P --transfers 4`. Google caps downloads at about 10 TB/day, so large libraries take several days | Local copy verified (`rclone check`) |
| **3. Media stack** | Plex (hardware transcoding on), Jellyfin, Sonarr/Radarr (restore backups, update root folders to `/data/media/...`), Prowlarr, qBittorrent + Gluetun, Seerr, Bazarr, Tautulli | Request → download → hardlink → shows up in Plex and Jellyfin |
| **4. Access** | Domain DNS, Caddy, Authelia, WireGuard, AdGuard Home | You can reach everything from your phone off Wi-Fi |
| **5. Books** | Calibre-Web-Automated, Audiobookshelf, optionally Kavita / LazyLibrarian | A file dropped in `ingest/books` shows up in CWA and on your e-reader |
| **6. Ops** | restic + Backrest, SnapRAID schedule, Uptime Kuma, Beszel, Homepage; pin image versions and update monthly | A restore test passes; alerts reach your phone |
| **7. Retire** | Shut down NSSM services and the `M:` mount; wipe or repurpose the Windows box | Nothing depends on Windows |

### Proposed repo layout

```
compose/
  media/compose.yaml     # plex, jellyfin, *arrs, prowlarr, qbittorrent+gluetun, seerr, bazarr, tautulli
  books/compose.yaml     # calibre-web-automated, audiobookshelf, kavita
  access/compose.yaml    # caddy, authelia, wg-easy, adguardhome
  ops/compose.yaml       # backrest, uptime-kuma, beszel, homepage
  .env.example
host/
  snapraid.conf
  mergerfs.fstab
  systemd/               # backup + snapraid timers
HOMELAB-PLAN.md          # this file
```

---

## 10. Where each old goal ends up

| Old goal | Resolution |
|---|---|
| a) Upload only at 2:30 AM Pacific | Library is local, so there's no upload step. Offsite backup runs on a systemd timer at that time (§8) |
| b) Login page on personal domain | Caddy + Authelia (§5, §7) |
| c) Web-based troubleshooting | Cockpit |
| d) Learn rclone cache | No longer needed; rclone isn't in the playback path |
| e) Daily rclone logs via NSSM | journald (§8) |
| f) Rick and Morty outage, May 18 | Almost certainly the Google Drive mount; that failure mode goes away |
| g) Move to Linux, pool drives, 12 TB RAID 5 | Debian 13 + mergerfs + SnapRAID (§3, §4) |
| h) Rename everything | Single `/data` tree (§3) |
| Todo 1–4: daily drive backups | restic + Backrest (§8) |
| Todo 5: OpenVPN tunnel | WireGuard (§5, §7) |

---

## 11. Open decisions

1. **Hardware:** reuse the current PC or buy a new box? What CPU does the current one have?
2. **Drives:** which drives and sizes do you have now, and how many TB are on Google Drive?
3. **Google Drive:** is your plan still giving you enough storage, or is that already forcing the move?
4. **Remote viewers:** who streams from outside your home? That decides whether you need Plex Pass or should push family toward Jellyfin.
5. **Family access:** public URL with Authelia, or VPN only?
