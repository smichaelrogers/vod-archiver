# Twitch VOD Archiver

Low-resource, set-and-forget Twitch stream archiving built on
[Ganymede](https://github.com/Zibbp/ganymede) (v4.21.0). Streams are recorded
to a folder/drive of your choice, and the PC is kept awake **only while a
recording is in progress** (plus the short post-processing step, configurable).

## Requirements

- Linux with **Docker** + the **Docker Compose v2** plugin (`docker compose`), your user in the `docker` group
- `curl`, `jq`, systemd
- A **Twitch application**: <https://dev.twitch.tv/console/apps/create>
  (OAuth redirect URL `http://localhost`, category *Application Integration*) → copy the Client ID and generate a Client Secret

## Quick start

```bash
cd twitch-vod-archiver
cp config.env.example config.env
nano config.env                       # set ARCHIVE_DIR, STREAM_URLS, TWITCH_CLIENT_ID/SECRET
./scripts/setup.sh                    # starts Ganymede, creates API key, adds channels
sudo ./scripts/install-service.sh     # keep-awake service (+ optional wake timer)
./scripts/status.sh
```

`setup.sh` will ask you to replace Ganymede's default `admin` / `ganymede`
password. The web UI is at <http://127.0.0.1:4800> (log in as `admin`).

## Configuration (`config.env`)

| Setting | What it does |
|---|---|
| `ARCHIVE_DIR` | Destination folder/drive for archived VODs |
| `STREAM_URLS` | Comma-separated Twitch URLs or channel names to archive |
| `QUALITY` | `best`, `1080p`, `720p`, … `audio` |
| `ARCHIVE_LIVE` / `ARCHIVE_VODS` | Record live streams / download past broadcasts that were missed |
| `VOD_MAX_AGE_DAYS` | Ignore VODs older than this (avoids huge backfills) |
| `ARCHIVE_CHAT` / `RENDER_CHAT` | Save chat JSON / render chat video (CPU heavy, off by default) |
| `LIVE_CHECK_INTERVAL` | Seconds between live checks |
| `KEEP_AWAKE_DURING_PROCESSING` | Also stay awake for the post-stream remux |
| `WAKE_SCHEDULE` | Optional wake-from-suspend times, e.g. `Mon,Wed,Fri 19:55;Sat 13:55` |

After editing: re-run `./scripts/setup.sh` (or just `./scripts/sync-channels.sh`
for channel/quality changes). Use `./scripts/sync-channels.sh --prune` to stop
watching channels you removed from `STREAM_URLS` (existing archives are kept).
After changing `WAKE_SCHEDULE`, re-run `sudo ./scripts/install-service.sh`.

## How sleep is handled

- **`twitch-keep-awake.service`** polls Ganymede's queue every 30 s. While a live
  recording (or post-processing) is active it holds a systemd-logind
  `sleep:idle` *block* inhibitor; it releases it as soon as work finishes, so
  your normal sleep settings apply the rest of the time. Check with
  `systemd-inhibit --list`.
- **Caveat:** a sleeping PC can't see a stream start. Two safety nets:
  1. `ARCHIVE_VODS=true` downloads the Twitch VOD of anything missed, the next
     time the PC is awake (VODs must still be available on Twitch).
  2. `WAKE_SCHEDULE` uses a systemd timer with `WakeSystem=true` to wake the PC
     before known stream times and stay awake `WAKE_HOLD_MINUTES` waiting for it.
- Closing a laptop lid is governed separately by logind's lid switch settings.

## Low-resource tuning

- Pinned upstream images; one worker per task type (`MAX_*_EXECUTIONS=1`)
- Chat rendering and sprite thumbnails disabled (the two most CPU-heavy steps)
- Container CPU/RAM caps and low CPU priority (`GANYMEDE_CPUS`, `GANYMEDE_MEMORY`, …)
- Small Postgres config, DB not exposed to the network, UI bound to localhost
- Temp files live on the archive drive, so finished recordings are moved by rename instead of copied
- Log rotation (10 MB × 3) and 7-day Ganymede log retention

## Files

```
config.env.example     template → copy to config.env
docker-compose.yml     Ganymede + Postgres (based on upstream compose)
scripts/setup.sh       start + bootstrap + apply config (idempotent)
scripts/sync-channels.sh  STREAM_URLS → Ganymede watched channels
scripts/keep-awake.sh  sleep inhibitor watcher (--check for one-shot)
scripts/scheduled-wake.sh  run by the optional wake timer
scripts/install-service.sh systemd units (--uninstall to remove)
scripts/status.sh | stop.sh | compose.sh
data/                  DB, logs, Ganymede config (git-ignored)
.secrets.env           DB password + API key (git-ignored, mode 600)
```

Archived files follow Ganymede's
[file structure](https://github.com/Zibbp/ganymede/wiki/File-Structure)
(`<channel>/<date>-<id>-<type>-<uuid>/…-video.mp4`, `…-chat.json`, `…-info.json`)
and are usable without Ganymede.

## Troubleshooting

- Logs: `./scripts/compose.sh logs -f ganymede`
- API key creation failed: follow the printed manual steps, then re-run `setup.sh`
- Archive on NFS/SMB: set `SKIP_CHOWN=true`
- Update Ganymede: bump the image tag in `docker-compose.yml`, then `./scripts/compose.sh pull && ./scripts/compose.sh up -d`
