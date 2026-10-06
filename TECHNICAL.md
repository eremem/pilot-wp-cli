# pilot-wp-cli — technical reference

This is the detailed reference: every tool and setting, how the pieces fit together, and how to diagnose problems. For a step-by-step setup guide, start with the README ([Polski](README.md) · [English](README.en.md)).

A small bash CLI that lets you watch [Pilot WP](https://pilot.wp.pl) — a Polish IPTV service — outside its official app. It is designed to plug into [tvheadend](https://tvheadend.org/) on a Linux media box: tvheadend imports the channel list as an IPTV network and re-serves the streams to any local client (Kodi via the tvh-htsp addon, VLC, Jellyfin, etc.).

The CLI handles authentication, channel discovery, per-tune stream resolution, the v3 heartbeat, and releasing the stream slot on teardown. Free-to-air channels are read from their DASH manifest by `pilot-wp-dashlive` and stream-copied by ffmpeg to MPEG-TS on stdout (HLS straight into ffmpeg is the fallback); nothing is transcoded. Channels that can't be streamed (the account's concurrent-stream limit, or DRM channels when DRM playback is off) show an on-screen slate instead of failing the tune. Widevine-DRM channels can optionally be decrypted — see [DRM playback](#drm-playback-optional).

It targets Pilot WP's `/api/v3` endpoints, falling back to `/api/v2` / `/api/v1` where v3 has no equivalent.

---

## Status

Personal, unofficial project, provided as-is and not affiliated with wp.pl. Use the official Pilot WP client wherever it is available for your platform. All rights to the content are reserved by wp.pl; this project only re-implements the client-side protocol so streams you are already entitled to as a paying user can be consumed by software you already run. See [`DISCLAIMER.md`](DISCLAIMER.md) — this repository contains no DRM keys or CDM files.

The CLI impersonates the official Android TV client (User-Agent and `X-Version` header copied verbatim) and will stop working if Pilot WP stops accepting them — see [How it works](#how-it-works).

---

## Requirements

Tested on Debian-based Linux (xbian on ARM specifically). Should work on any Linux distribution that can install the binaries below.

| Binary | Where it comes from on Debian/Ubuntu/xbian | Notes |
|---|---|---|
| `bash` (>= 4) | preinstalled | `[[ ]]`, arrays, `mapfile`, `printf` builtin |
| `curl` | `apt install curl` | all HTTP calls, cookie jar I/O |
| `jq` | `apt install jq` | JSON parsing |
| `ffmpeg` | `apt install ffmpeg` | stream-copy to MPEG-TS, DRM decrypt, and the slate (needs `libx264`, `drawtext`/`libfreetype`, `aac`); `ffprobe` from the same package is handy for testing |
| `python3` | `apt install python3` | runs `pilot-wp-dashlive` (stdlib only) for DASH playback; without it free-to-air falls back to HLS. DRM playback additionally needs `pywidevine` |
| `flock` | `util-linux` (preinstalled) | serializes cookie-jar writes (login, `pilot-wp-ping`) |
| `awk`, `coreutils` | preinstalled | cookie-jar parsing; `paste`, `date`, `mktemp`, `mkdir`, `mv`, `readlink`, `dirname` |
| a TTF font | `fonts-dejavu-core` (usually preinstalled) | drawn on the slate |

One-shot install of the things that aren't preinstalled on a minimal system:

```bash
sudo apt install curl jq ffmpeg python3 fonts-dejavu-core
```

Or use `pilot-wp-deps`, an idempotent checker/installer covering the above plus the optional DRM stack (Python venv, `pywidevine`, ffmpeg's `-decryption_key`, the `.wvd`). With no arguments it prints a status report (no root, no changes); `install` fetches what's missing behind one sudo prompt:

```bash
./pilot-wp-deps            # report status only (CORE + DRM), exit 0 if FTA is ready
./pilot-wp-deps install    # install everything missing (one sudo prompt)
./pilot-wp-deps --no-drm   # restrict to the free-to-air core
```

It is apt-only (Debian/xbian); on other distros it reports status and prints manual hints. `python3` is a core dependency (free-to-air plays DASH through `pilot-wp-dashlive`; without it FTA falls back to HLS). It also checks that the scripts are executable and `install` restores the bit — copying or editing them from another OS can drop it, and tvheadend runs `pilot-wp-stream` directly.

You also need:

- A Pilot WP subscription for the channels you want (free channels work without one).
- A browser login at https://pilot.wp.pl to extract session cookies (see [Authentication](#authentication)).
- For the tvheadend integration: tvheadend installed and reachable, or a shared path for the M3U file.

---

## Installation

```bash
chmod +x pilot-wp-*              # make all the tools executable
./pilot-wp-deps install          # check + install any missing dependencies (one sudo prompt)
cp config.env.example config.env # optional — every setting has a working default
chmod 600 config.env
./pilot-wp-login --web           # create the cookie jar from a login page (or: ./pilot-wp-login in the terminal)
./pilot-wp-status                # confirm the setup is ready to stream
```

Every path derives from `PILOT_WP_HOME`, which defaults to the directory the scripts live in, so the tree can be copied anywhere or its executables symlinked into `$PATH`. A common install location on a tvheadend host is `~/.hts/tvheadend/scripts/pilot-wp-cli/`, owned by the user that runs tvheadend (so tvheadend can read the cookie jar).

---

## Configuration

`config.env` is a bash file sourced by every tool. Precedence is environment > `config.env` > built-in defaults, so a variable exported for one run (e.g. `PILOT_WP_TRACE=1 ./pilot-wp-stream …`) overrides the file. Everything is optional. Keep it `chmod 600`.

### Authentication

Authentication uses the two Pilot WP session cookies, `netviapisessid` and `netviapisessval`, stored in the cookie jar (`cookies.txt`). The jar is the only auth artifact — there are no cookie settings in `config.env`. Email/password login does not work headlessly: Pilot WP's login endpoint is gated by Cloudflare Turnstile.

**Recommended: the temporary login page (`./pilot-wp-login --web`).** You hand over the cookies from a browser on any PC in your local network — nothing to paste into the box's terminal:

1. On the box, run `sudo -u xbian ./pilot-wp-login --web` (as the tvheadend user, so the jar stays readable by tvheadend). It starts a temporary login page and prints its address and a one-time code, e.g. `http://192.168.1.20:8199/` and `482913`.
2. Open the address in a browser on any PC in your local network and follow the steps on the page (in Polish and English, for Chrome and Firefox): log into https://pilot.wp.pl, copy a request with *Copy as cURL*, paste it on the page, and enter the code.
3. The box checks the session against Pilot WP before it replaces the jar, so a wrong paste never logs it out.

The page stops after a successful login, 5 wrong codes, or 15 minutes (`--timeout MIN`); `--port N` and `--bind ADDR` change where it listens. Only clients on private network addresses are served, over plain HTTP, so use it on your home network.

**Alternative: paste in the terminal (`./pilot-wp-login`).** You can also paste a logged-in browser session straight into the box's terminal:

1. Log into https://pilot.wp.pl in a browser.
2. Open DevTools (F12) → *Network*, then click a channel so a request to `pilot.wp.pl/api/...` appears.
3. Right-click that request → *Copy* → *Copy as cURL*.
4. Run `./pilot-wp-login`, choose `[c]` (the default), paste, and press Enter on an empty line. The two cookies are written to `cookies.txt`.

The pasted command is only parsed for the two cookies, never executed. `[v]` lets you type the two values by hand instead.

When the session goes stale, log in again (`./pilot-wp-login --web` or `./pilot-wp-login`). Streaming only reads the jar, never rewrites it, so concurrent tunes or an API error can't corrupt it. tvheadend runs `pilot-wp-stream` without a TTY: once the jar exists it is reused, and if it expires the stream shows an "authentication failed" slate until you re-run `./pilot-wp-login`. To provision a box without an interactive session, copy a known-good `cookies.txt` onto it (`chmod 600`, owned by the tvheadend user).

### Variables

| Variable | Default | Purpose |
|---|---|---|
| `PILOT_WP_CONFIG` | `$PILOT_WP_HOME/config.env` if `PILOT_WP_HOME` is set in the environment, else `config.env` next to the scripts | The config file to load. Set it in the environment (it can't be set inside `config.env`), e.g. `PILOT_WP_CONFIG=/etc/pilot-wp.env`. |
| `PILOT_WP_HOME` | dir of `pilot-wp-common.sh` | Where the cookie jar, lock and caches live. The scripts, `.drmvenv` and `widevine/` stay next to `pilot-wp-common.sh`. |
| `PILOT_WP_COOKIES` | `$PILOT_WP_HOME/cookies.txt` | Path to the Netscape cookie jar. |
| `PILOT_WP_LOCKFILE` | `$PILOT_WP_HOME/.lock` | Lock file held while the jar is written (`pilot-wp-login`, `pilot-wp-ping`). Keep it on local disk next to the jar. |
| `DEVICE_TYPE` | `android_tv` | `device_type` query parameter sent on every API call. |
| `PILOT_WP_UA` | `ExoMedia 4.3.0 (43000) / Android 8.0.0 / foster_e` | Advanced: User-Agent sent to the API and CDN, impersonating the Android TV app. Change only if Pilot WP starts rejecting this identity; a wrong value breaks auth and streaming. |
| `PILOT_WP_X_VERSION` | `pl.videostar\|3.53.0-gms\|Android\|26\|foster_e` | Advanced: the `X-Version` header, the other half of the Android TV app identity. Same caveat as `PILOT_WP_UA`. |
| `PILOT_WP_RETRIES` | `3` | Per-tune attempts in `pilot-wp-stream` before giving up (exit 5, or the connection slate when Pilot WP was unreachable). |
| `PILOT_WP_LIMIT_RETRIES` | `3` | Open attempts on the concurrent-stream (multiroom) limit before showing the limit slate. |
| `PILOT_WP_LIMIT_DELAY` | `2` | Seconds between those attempts. |
| `PILOT_WP_M3U_DRM_SCAN` | `1` | `pilot-wp-m3u` probes channels (releasing each session) to add a `DRM` tvh-tag — the channel list has no DRM flag. Results are cached and only unknown/expired channels are probed. `0` = no probing, no cache, no DRM tag. |
| `PILOT_WP_M3U_CACHE_TTL_DAYS` | `7` | Re-probe a cached channel once its entry is older than this (max 7). |
| `PILOT_WP_M3U_CACHE` | `$PILOT_WP_HOME/.m3u-drm-cache.tsv` | DRM-status cache (pruned to currently subscribed channels on each scan). |
| `PILOT_WP_DRM_VERIFY_TIMEOUT` | `8` | When a channel advertises a `drms` block, its DASH manifest is checked; if it has no `ContentProtection` and an HLS URL exists, it plays as free-to-air (some channels, e.g. ViDocTV, advertise `drms` but are clear). This is the timeout in seconds for that fetch; a failed fetch keeps the channel as DRM. |
| `PILOT_WP_DRM_ENABLE` | `0` | `1` = decrypt and play Widevine DRM channels (see [DRM playback](#drm-playback-optional)); `0` = show the DRM slate. |
| `PILOT_WP_WVD` | first `*.wvd` in `widevine/` next to the scripts | Widevine L3 device file (`chmod 600`). Required for DRM playback. |
| `PILOT_WP_PYTHON` | `.drmvenv/bin/python` in the scripts dir if present, else `python3` | Runs `pilot-wp-dashlive` (stdlib only) and, for DRM, `pilot-wp-getkeys` (needs `pywidevine`). |
| `PILOT_WP_DRM_KEY_LOG` | empty | File to append `pilot-wp-getkeys` diagnostics to. |
| `PILOT_WP_FTA_DASH` | `1` | Play free-to-air channels from their DASH manifest via `pilot-wp-dashlive` (no key). Some channels' HLS stamps audio on a different timeline than video, which leaves ffmpeg's HLS demuxer without sound. `0` = HLS; HLS is also used when a channel has no DASH URL or `PILOT_WP_PYTHON` is missing. |
| `PILOT_WP_FTA_DASH_CODEC` | `avc1` | Preferred video codec for free-to-air DASH (some MPDs list HEVC before H.264). Empty = the first video set. |
| `PILOT_WP_DASHLIVE_ARGS` | empty | Extra `pilot-wp-dashlive` args, for every DASH tune (FTA and DRM): `--parallel N` (connections per video track, default 3; `1` = serial; no extra session slots), `--prebuffer N` (start this many segments back and deliver them up front as a cushion, default 20; lower = closer to live; never further back than the manifest's `timeShiftBufferDepth`), `--behind N` (segments kept behind the live edge, default 2), `--max-video-bw BITS` (cap the video rendition, e.g. `4000000`; default highest), `--node-ttl SECS` (refresh the manifest straight from the CDN node the redirector sent it to, asking the redirector again only every this many seconds or when the node fails; default 300, `0` = always through the redirector), `--verbose`. |
| `PILOT_WP_DASH_FFMPEG_FLAGS` | `-loglevel fatal -copyts` | ffmpeg flags for every DASH tune (it reads the dashlive FIFOs, decrypting when there is a key). Keep `-copyts`: without it audio desyncs on `$Number$`-based channels. Don't add HLS/network flags (`-live_start_index`, `-reconnect_at_eof`, a large `-probesize`) — they break FIFO input. |
| `PILOT_WP_REFRESH_INTERVAL` | `100` | Seconds between session refreshes on token-gated DASH URLs (`t2`/`t3`/`ts` query tokens, e.g. TV Puls, Puls 2), whose segment access is revoked a few minutes into play. The session is switched in place and the new URL handed to the running `pilot-wp-dashlive`; sustained 403s trigger an immediate refresh. |
| `PILOT_WP_HLS_FFMPEG_FLAGS` | `-loglevel fatal -probesize 15M -analyzeduration 6000000 -live_start_index -1 -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5` | ffmpeg input flags for the HLS fallback. The analysis window must cover the audio-description rendition, which arrives ~4 s after the main audio, or the tune misses that track. `-live_start_index -1` starts at the live edge; drop it if a channel underruns. |
| `PILOT_WP_SLATE_LOGO` | empty | Local image used as the logo on every slate (DRM, stream limit, auth failure, no connection) instead of the channel logo; the message is still drawn. |
| `PILOT_WP_SLATE_FONT` | `/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf` | Slate font. |
| `PILOT_WP_SLATE_BG` / `_SIZE` / `_FONTSIZE` / `_TITLE_FONTSIZE` / `_TOP` / `_GAP` | `0x101820` / `1280x720` / `32` / `56` / `60` / `90` | Slate colour, resolution, text sizes, layout. |
| `PILOT_WP_SLATE_TEXT_DRM` / `_LIMIT` / `_AUTH` / `_NET` | bilingual (Polish + English) | Slate messages (`\n` for line breaks). `_NET` is shown when Pilot WP or its CDN can't be reached. |
| `PILOT_WP_TRACE` | `0` | `1` = per-step trace lines on stderr (see [Tracing](#tracing)). |
| `PILOT_WP_RELEASE_LOG` | empty | File the detached slot releaser appends to (see [Tracing](#tracing)). |
| `PILOT_WP_PING_TIMEOUT` | `15` | `pilot-wp-ping`: seconds for its probe request. |
| `PILOT_WP_PING_LOG` | empty | `pilot-wp-ping`: file to append one outcome line per run to. |

`config.env` is sourced before any default is applied, so every variable — including `PILOT_WP_HOME`, `PILOT_WP_COOKIES` and `DEVICE_TYPE`, which other values are derived from — can be set there; an exported environment variable still takes precedence over it.

### DRM playback (optional)

Premium channels (e.g. TVN) are Widevine-protected and show a slate by default. With a Widevine L3 device file you can decrypt and play them — the same decryption Kodi's `inputstream.adaptive` performs. Free-to-air channels are unaffected, and if a key can't be fetched the slate is shown.

1. **Get a `.wvd`** — extract an Android L3 CDM from a device or emulator you control, typically an Android Studio emulator (a *Google APIs* system image, which can be rooted) and a Frida-based extractor such as [KeyDive](https://github.com/hyugogirubato/KeyDive), which writes a ready `.wvd`. If a tool gives you `client_id.bin` + `private_key.pem` instead, pack them with `pywidevine create-device -t ANDROID -l 3 -k private_key.pem -c client_id.bin -o .`. A license challenge captured from the web player is not enough: it lacks the device's private key. This is your own responsibility; never commit the `.wvd`. The README has a step-by-step outline.
2. **Install pywidevine** for `PILOT_WP_PYTHON`, e.g. in a venv inside the scripts dir (the default location): `python3 -m venv .drmvenv && .drmvenv/bin/pip install pywidevine`. `pilot-wp-deps install` does this for you.
3. **Enable it** in `config.env`: `PILOT_WP_DRM_ENABLE=1`. Drop the `.wvd` into `widevine/` next to the scripts (`chmod 600`) or set `PILOT_WP_WVD`.

The DASH is used because Pilot WP only offers Widevine there; the HLS of a DRM channel is a FairPlay variant. `pilot-wp-getkeys` runs the license exchange for the content key, `pilot-wp-dashlive` fetches the CENC segments in timeline order (ffmpeg's own live-DASH demuxer scrambles segment order on these manifests), and ffmpeg decrypts each track from its FIFO with `-decryption_key` — the same pipeline, heartbeat and releaser as free-to-air DASH. Every audio track is restreamed and language-tagged; audio-only (radio) channels are supported.

---

## Usage

The tools:

| Script | When to run | What it does |
|---|---|---|
| `pilot-wp-login [--web]` | Once on first install; when you refresh browser cookies | `--web` (recommended): temporary login page on the local network; the jar is only replaced once the new session works. Without `--web`: wipes the jar and asks for a *Copy as cURL* in the terminal. |
| `pilot-wp-status [--no-color]` | After install, or when something's not working | Health check: config, core dependencies, session validity, DRM readiness. Read-only (never logs in or opens a slot). Exit 0 = ready for free-to-air. |
| `pilot-wp-account-info [--json]` | Anytime | Prints the account's identity, subscription and location; confirms the cookies work. |
| `pilot-wp-ping [-v]` | Periodically (cron) on a box that may sit idle | Non-interactive keepalive; see [Keeping the session warm](#keeping-the-session-warm-cron). |
| `pilot-wp-sessions [list\|remove …]` | Anytime | Lists and removes the account's login sessions; see [Managing sessions](#managing-sessions). |
| `pilot-wp-favourites [list\|add\|remove …]` | Anytime | Lists and edits favourite channels; see [Managing favourites](#managing-favourites). |
| `pilot-wp-m3u [--rescan] OUTPUT_PATH` | After login, and again when the channel lineup changes (cron optional — see [Daily channel-list refresh](#daily-channel-list-refresh-cron)) | Writes a tvheadend M3U whose entries are `pipe://` invocations of `pilot-wp-stream`; `--rescan` re-probes every channel's DRM status, ignoring the cache. No stream URLs are embedded, so it doesn't go stale when tokens expire. |
| `pilot-wp-stream CHANNEL_ID ['NAME'] ['THUMB_URL'] [AUDIO_ONLY]` | Invoked by tvheadend per tune | Opens the channel, heartbeats it, and writes MPEG-TS to stdout; DRM (when not enabled) and over-limit channels get a slate, and so does a tune that can't reach Pilot WP. |
| `diagnostics/pilot-wp-cdn-probe [--dash\|--hls] [--wait SECS] [--live SECS] CHANNEL_ID [N_SEGS]` | When a channel stutters or stops | Measures whether this box can fetch the channel's segments fast enough, and whether the link stays up; see [Diagnosing a stutter](#diagnosing-a-stutter). Not used during playback. |
| `pilot-wp-common.sh` | Sourced by the others | Library; not directly runnable. |

### Generating the M3U

```bash
./pilot-wp-m3u /path/to/channels.m3u
```

One `#EXTINF`/`pipe://` pair per free or subscribed channel (`unsubscribed` channels are skipped). Each `#EXTINF` carries `tvg-id`/`tvg-chno`/`tvg-logo`/`tvg-name`, `group-title` (Polish category), `tvh-tags` (`HD`/`SD`/`Radio` + categories, plus `DRM` — see `PILOT_WP_M3U_DRM_SCAN`), `tvh-bouquet="Pilot WP"`, and `tvh-epg="0"`. The `pipe://` line passes the channel id, the name (→ MPEG-TS SDT `service_name`), the thumbnail (→ slate logo), and an audio-only flag. The file is written atomically (`mktemp` + `mv`).

> **Radio channels.** tvheadend decides radio vs. TV from the stream's SDT `service_type`, not from the M3U (its IPTV parser ignores `radio="true"`), so `pilot-wp-stream` marks audio-only channels `digital_radio`. tvheadend only sees this once it has read the SDT: after (re)generating the M3U, force-scan the IPTV muxes (or play each radio channel once), or set *Service Type = Radio* per service in the Services UI.

### Testing a single stream

The M3U `pipe://` lines aren't HTTP URLs. To verify a channel:

```bash
# Smoke-test the pipeline (a growing capture = healthy):
timeout 10 ./pilot-wp-stream <CHANNEL_ID> > /tmp/test.ts ; ffprobe -hide_banner /tmp/test.ts

# Inspect the live MPEG-TS directly:
./pilot-wp-stream <CHANNEL_ID> 2>/dev/null \
  | timeout 5 ffprobe -hide_banner -show_streams -of compact -i pipe:0
```

> When fetching a stream URL yourself (e.g. with `ffplay`/`streamlink`), send only the `User-Agent`, not the session cookie: the URL's own `t2`/`t3`/`ts` tokens authenticate it, and the CDN returns HTTP 400 when the cookie is present.

### Managing sessions

`pilot-wp-sessions` lists the account's active login sessions and lets you remove them — handy when another device is holding a slot.

```bash
./pilot-wp-sessions                 # list; ★ marks this session (the one our cookies use)
./pilot-wp-sessions --json          # raw session JSON
./pilot-wp-sessions remove 2        # remove session #2 from the list (prompts first)
./pilot-wp-sessions remove --others # remove every session except this one
./pilot-wp-sessions remove 2 -f     # skip the confirmation prompt (required non-interactively)
```

Sessions are addressed by list number, not `session_id`, because the API returns a fresh
`session_id` on every request. The list is sorted by creation time; `remove <N>` re-fetches it and
prints what #N resolved to before deleting. The current (`★`) session — the one this cookie jar
authenticates as — can't be removed. Removing a session logs that device out and frees its stream
slot.

### Managing favourites

`pilot-wp-favourites` lists and edits the account's favourite channels.

```bash
./pilot-wp-favourites                 # list current favourites ([id] name quality category)
./pilot-wp-favourites --json          # raw favourites JSON
./pilot-wp-favourites add 14 312      # add channel(s) by id
./pilot-wp-favourites remove 14 312   # remove channel(s) by id
```

`add`/`remove` take one or more channel ids (from `pilot-wp-favourites list` or the `pipe://`
lines of the generated M3U). They don't prompt and are idempotent server-side.

### tvheadend integration

1. tvheadend web UI → *Configuration* → *DVB Inputs* → *Networks* → *Add* → *IPTV Automatic Network*.
2. *URL* = `file:///absolute/path/to/channels.m3u`. Turn *Scan after creation* / *Idle scan muxes* off (idle scans launch tunes nobody is watching and use up stream slots).
3. Force-scan once; map services → channels.
4. Open a channel from any client — tvheadend runs the `pipe://` child and reads MPEG-TS from its stdout.

### Daily channel-list refresh (cron)

> **Optional, with a risk.** Each `pipe://` line embeds the channel's name and logo URL, and tvheadend's IPTV Automatic Network identifies a mux by its URL. When Pilot WP renames a channel, changes its logo, or drops it, the regenerated M3U makes tvheadend delete the old mux together with its service, so that channel loses its mapping (and any per-channel settings) until you map the new service again. Regenerating by hand when the lineup changes, then checking the mapping, avoids surprises.

```cron
0 4 * * * /home/USER/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp-m3u /home/USER/.hts/tvheadend/scripts/pilot-wp-cli/channels.m3u >> /home/USER/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp.log 2>&1
```

### Keeping the session warm (cron)

The Pilot WP session is sliding: it is keyed on the long-lived `netviapisessid` cookie, and authenticated requests periodically make the server reissue it (rotating the short-lived `netviapisessval` and pushing the cookie expiry ahead). A box that streams or regenerates the M3U regularly needs nothing extra; one that can sit idle for long stretches can let the session go cold. `pilot-wp-ping` covers that: one `GET /api/v2/user` (no stream slot), writing any refreshed cookie back into the jar under the login lock.

It is quiet on success and reports via [exit code](#exit-codes) (`0` alive, `1` re-login needed, `2` transient/unreachable), so a plain cron entry only mails you when something is wrong:

```cron
# every 8h: keep the Pilot WP session warm; mails only on a non-zero exit
0 */8 * * * /home/USER/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp-ping || echo "pilot-wp-ping exit $?: session may need ./pilot-wp-login"
```

Every 6–12 h is plenty. Run the cron as the user that owns `cookies.txt` (the tvheadend user) so the rewritten jar keeps its ownership. `-v` shows what it did; `PILOT_WP_PING_LOG` keeps one line per run. It never prompts and never wipes the jar — a dead session is reported (exit 1) for you to fix with `pilot-wp-login`.

---

## How it works

```
┌─────────────────┐                       ┌──────────────────┐
│ pilot-wp-login  │  (interactive, rare)  │ pilot-wp-m3u     │  (on lineup changes)
│ → cookies.txt   │ ──── share jar ────►  │ → channels.m3u   │
└─────────────────┘                       └──────────────────┘
                                                   │ tvheadend imports as IPTV network
                                                   ▼
┌───────────────────────────────────────────────┐  ┌──────────────────┐
│ pilot-wp-stream <id> ['name'] ['thumb']       │ ◄│ tvheadend        │
│  resolve_auth (cookie jar)                    │  │ pipe:// child    │
│  fetch_channel → ok | drm | limit | error     │  │                  │
│   ok    → heartbeat + dashlive/HLS → ffmpeg ──┼─►│ stdout = MPEG-TS │ ──► clients
│   drm   → key + dashlive → ffmpeg, else slate │  │                  │
│   limit → retry, then emit_slate              │  │ reaps child w/   │
│  spawn_releaser (setsid, detached) ───────────┼──│ group SIGKILL    │
│   on main death → release_stream (close slot) │  └──────────────────┘
└───────────────────────────────────────────────┘
```

**Auth** (`resolve_auth`): probe `/api/v2/user` — a numeric `.data.id` means the jar still authorizes (an unauthenticated session returns `{"data":null}`). Otherwise — on a TTY — an interactive *Copy as cURL* paste writes the jar (there is no email/password login: the endpoint is Cloudflare-Turnstile-gated). No TTY ⇒ fail (run `pilot-wp-login`).

**Per tune** (`pilot-wp-stream`): `fetch_channel` does `GET /api/v3/channel/{id}` and returns one of:

- **ok** — start the heartbeat (`POST .data.heartbeat.url` every `.data.heartbeat.interval` s; without it the session is reaped within ~20–40 s), then stream the clear DASH through `pilot-wp-dashlive` → ffmpeg (HLS straight into ffmpeg as the fallback — see `PILOT_WP_FTA_DASH`). All audio tracks are mapped so Kodi can switch between them.
- **drm** — `.data.stream_channel.drms` is set and the manifest really is encrypted (it is checked; see `PILOT_WP_DRM_VERIFY_TIMEOUT`). With DRM playback enabled, the same DASH pipeline runs with a Widevine key from `pilot-wp-getkeys`; otherwise, or if the key fetch fails, the session is released and a slate shown — the connection slate when the manifest or license server couldn't be reached (the manifest is retried for ~20 s, and the whole key fetch once more), else the DRM slate. A manifest that can't be fetched or isn't an MPD counts as unreachable, never as a DRM problem. See [DRM playback](#drm-playback-optional).
- **limit** — `multiroom_limit_exceeded`: the concurrent-stream cap is hit. Retried `PILOT_WP_LIMIT_RETRIES` times (a just-ended tune may still be clearing), then a slate.
- **error** — retried. The cookie jar is never wiped (it is the only credential and is shared by every tune). If the API was unreachable on the last attempt, the tune ends on the connection slate; an unreachable API is never taken for a stale jar (no auth slate).

On DASH tunes whose URL carries `t2`/`t3`/`ts` tokens, the heartbeat loop also refreshes the session every `PILOT_WP_REFRESH_INTERVAL` s and hands the new URL to the running `pilot-wp-dashlive`.

**Teardown**: tvheadend stops a tune by sending SIGKILL to the pipe child's whole process group, so no cleanup trap can run. At tune start `spawn_releaser` therefore launches a small releaser in its own session (`setsid`); it waits for the main process to die by any means and then releases the slot with `release_stream` (`GET …?close_stream=<token>`, then `POST /api/v2/channels/close` on the token that returns — a lone POST close doesn't reliably free the slot). `PILOT_WP_RELEASE_LOG` shows what it does.

Endpoints and headers are constants at the top of `pilot-wp-common.sh`; if Pilot WP changes the client it expects, start there.

---

## Troubleshooting

### Exit codes

| Exit | From | Meaning |
|---|---|---|
| `0` | any | Success / clean ffmpeg or slate exit. |
| `2` | `resolve_auth` | Jar invalid/expired and no TTY to refresh it (and no working creds). Usually: tvheadend invoked the script and `cookies.txt` is missing/stale/unreadable — run `pilot-wp-login`. |
| `3` | `resolve_auth` | Supplied credentials/cookies rejected by the API. Re-run `pilot-wp-login` with fresh cookies. |
| `4` | `pilot-wp-account-info` / `pilot-wp-m3u` | Not authenticated / channel list not an array — cookies bad or expired. |
| `5` | `pilot-wp-stream` | All `PILOT_WP_RETRIES` attempts failed with Pilot WP reachable (an unreachable one gets the connection slate instead). Check stderr. |
| `1` | `pilot-wp-status` | At least one FAIL item needs attention before streaming. |
| `1` | `pilot-wp-ping` | Session dead: jar missing/empty, or the API rejected it. Run `pilot-wp-login`. |
| `2` | `pilot-wp-ping` | Transport failure: API unreachable / timed out / jar lock busy. The next run retries. |

### Common issues

- **An "authentication failed" slate appears** — `pilot-wp-stream` couldn't use the cookie jar: it's missing or expired, or (the usual tvheadend case) `cookies.txt` is owned by another user and tvheadend's user can't read it. Make the jar and `config.env` readable by the tvheadend user — ideally run `pilot-wp-login` as that user. Running `./pilot-wp-stream <id> </dev/null` as that user prints the `resolve_auth:` reason on stderr.
- **`exit 3` right after login** — the pasted cookies are wrong or expired. Log in again in the browser, re-paste, and confirm with `./pilot-wp-account-info`.
- **A channel plays briefly, stutters, stops, then shows the connection slate** ("Brak połączenia z Pilot WP") — the internet link dropped: playback ran on its buffer, and the re-tune couldn't reach Pilot WP. Check the modem/line; `diagnostics/pilot-wp-cdn-probe` with a longer `--live` catches a link that drops out now and then (see [Diagnosing a stutter](#diagnosing-a-stutter)).
- **A channel shows the DRM slate** — the channel is Widevine-encrypted and DRM playback is off; see [DRM playback](#drm-playback-optional). If it's enabled and you still get the slate, set `PILOT_WP_DRM_KEY_LOG` and `PILOT_WP_TRACE=1` and check the `pilot-wp-getkeys` output (expired `.wvd`, license rejected, or `PILOT_WP_PYTHON` can't import pywidevine). `./pilot-wp-status` checks the DRM prerequisites.
- **A channel shows the stream-limit slate** — the account's concurrent-stream cap is reached. Stop another stream or device; a stopped tune frees its slot within seconds, an abandoned one within ~20–40 s.
- **tvheadend says "no available adapters" / sessions pile up while zapping** — slots aren't being released on teardown (see [How it works](#how-it-works)). Check that `setsid` exists (`command -v setsid`; without it slots only self-expire after ~20–40 s), set `PILOT_WP_RELEASE_LOG` and look for `release: ok` after each stop, and remember that a browser session on the same account also holds a slot. To clear leftover processes: `pkill -9 -f pilot-wp-stream; pkill -9 -f pilot-wp-dashlive; pkill -9 -f 'pilot-wp-drm-|videostar|color=c='`, and restart tvheadend if its subscription count stays stale.
- **ffmpeg reports HTTP 400 on the stream** — the session cookie was sent to the CDN; stream URLs must be fetched with only the `User-Agent`.
- **A channel stalls or re-buffers (DASH)** — give `pilot-wp-dashlive` more headroom via `PILOT_WP_DASHLIVE_ARGS`: a larger `--prebuffer`, `--parallel` ≥ 2, or `--max-video-bw` to pick a lighter rendition on a slow link. `--verbose` logs per-segment timing. To find out whether the link is the limit, see [Diagnosing a stutter](#diagnosing-a-stutter).
- **HLS fallback only:**
  - *Wrong number of audio tracks (a re-tune fixes it)* — ffmpeg fixed the MPEG-TS program before it found the audio-description rendition, which starts ~4 s late. Raise `-analyzeduration`/`-probesize` in `PILOT_WP_HLS_FFMPEG_FLAGS`.
  - *Audio-description track out of sync* — that rendition is ~4 s offset at the source and `-c copy` can't re-time it; the main track is in sync. A VLC recording may mute because of it; live Kodi playback is unaffected.
  - *Stalls* — drop `-live_start_index -1` from `PILOT_WP_HLS_FFMPEG_FLAGS`; ffmpeg then starts 3 segments behind the live edge, trading a slightly slower tune for more buffer.

### Diagnosing a stutter

A channel whose segments can't be fetched in real time stutters. On the DASH path it does so in a typical pattern: about once a minute tvheadend logs `tsfix: transport stream H264, DTS discontinuity` (and the same for AAC) with a constant forward jump of roughly the manifest's window (~34 s on TVN), and in between `AAC … DTS and PCR diff is very big` with a growing value. `pilot-wp-dashlive` has fallen off the back of the short live window and resynced to the live edge. On the HLS fallback, ffmpeg stalls instead.

`diagnostics/pilot-wp-cdn-probe` tells you whether this box can keep up. Run it on the box, as the tvheadend user, while the channel is stuttering:

```bash
sudo -u xbian ./diagnostics/pilot-wp-cdn-probe 14      # 14 = TVN; optional 2nd arg = segments per track
```

It opens the channel once and probes the path `pilot-wp-stream` plays that channel through: DASH for DRM channels and, by default, for free-to-air ones; HLS for a free-to-air channel on the fallback (no DASH URL, `PILOT_WP_FTA_DASH=0`, or no `pilot-wp-dashlive`/python3). The header shows the path and why it was chosen. `--dash` or `--hls` forces a path on a free-to-air channel, for example to compare the two before changing `PILOT_WP_FTA_DASH`; DRM channels play only through DASH. The slot is released at once, unless the URL is token-gated (videostar channels, whose URL stops working once the session closes); then it is kept alive with heartbeats until the probe exits.

It then times recent segments of the top video rendition and the audio two ways, and ends with a `VERDICT`:

- **WARM** — one reused keep-alive connection, as `pilot-wp-dashlive` (DASH) or ffmpeg (HLS) fetches. It must stay under the segment duration (`seg_dur`, ~2 s) for smooth playback.
- **COLD** — a fresh connection per segment, which isolates connection setup (TCP/TLS handshake).

The two modes fetch different, alternate segments, interleaved in time, so neither is helped by the CDN caching a segment the other just fetched. Some manifests list only a few recent segments (videostar channels use 5 s segments). When fewer than `N_SEGS` per mode are listed, the probe keeps re-reading the manifest and times each segment as it is published, video and audio together, until it has enough or `--wait SECS` runs out (default 90; `--wait 0` uses only what is already listed). Each track's header shows how many were sampled and how many of those were awaited live. How to read the result:

- **COLD slow, WARM fast** — new connections are the problem (connection tracking or socket buildup on the box; a reboot clears it).
- **WARM slow, COLD fast** — bandwidth is fine, but long-lived connections are held up or dropped on the way (router, NAT, Wi-Fi, or the CDN node). Compare from another machine on the same network, and re-run to see whether it follows the node the probe names.
- **Both slow** — the link or path to the CDN is the limit. Check the modem; if the transfer time dominates, cap the video with `--max-video-bw` in `PILOT_WP_DASHLIVE_ARGS` (the probe prints the next lower rung of the channel's quality ladder). The HLS fallback can't cap the bitrate; re-run with `--dash` to see whether the channel's DASH path would keep up.

A keep-alive `RECONNECT` during the run means the connection was dropped mid-stream, which alone causes stalls. Failed fetches (HTTP errors) are counted and reported separately.

Those timings come from a burst of a few seconds. They measure throughput, but a link that drops out now and then — a modem resyncing, say — passes them while playback stalls and stops. So the probe then watches the link for `--live SECS` (default 60; `--live 0` skips it), polling the way `pilot-wp-dashlive` does in steady state: the manifest once per segment duration, every newly published segment on the keep-alive connection, and the Pilot WP API every 10 s (heartbeats and a re-tune's key fetch depend on it). Failures, fetches slower than a segment duration, and gaps between segments are printed as they happen, then summed up. The `LIVE` line of the verdict says **UNSTABLE** when anything failed or a track went longer than three segment durations without a new segment, even when the throughput above was fine. If playback stops only every few minutes, raise `--live` to cover a few of those intervals. On a token-gated (videostar) channel the live run is shortened to stay within the session's few minutes.

The DASH manifest URL is the CDN's redirector (`r.dcs.redcdn.pl`), which answers with a redirect to a node (the `node:` the probe prints). The redirector can fail on its own, with some of its addresses timing out, while the nodes and the link are fine. `pilot-wp-dashlive` therefore refreshes the manifest straight from that node, going back to the redirector only when the node fails and every `--node-ttl` seconds, so running playback rides a redirector outage out. A tune still starts through it, and so does the DRM key fetch. The probe's `manifest` line is the node path, as in `pilot-wp-dashlive`; the `redirector` line polls the redirector separately. When the redirector fails or is slow, the probe tries each of its addresses in turn (`REDIRECTOR`), and when the playback path held up, the verdict blames the **REDIRECTOR** and names the failing addresses: it is on the CDN's side, nothing to fix on the modem or line, and it shows up as slow tunes or the connection slate rather than stalls. The same address check runs when the probe can't fetch the manifest at all.

### Tracing

Set `PILOT_WP_TRACE=1` (in `config.env` or the environment) and `pilot-wp-stream` logs each step of a tune to stderr, which tvheadend captures into its log (prefixed `spawn:`, with its own timestamp). Lines are tagged `[PID ch=ID]` so concurrent tunes can be told apart. A free-to-air DASH tune:

```
spawn: pilot-wp-stream[2451 ch=11]: start: name='TV 4 HD' parent_pid=2390 retries=3
spawn: pilot-wp-stream[2451 ch=11]: optimistic open (attempt 1): jar present, skipping pre-flight auth probe
spawn: pilot-wp-stream[2451 ch=11]: fetch: status=ok token=yes hb_interval=20 name='TV 4 HD'
spawn: pilot-wp-stream[2451 ch=11]: FTA channel; using DASH (dashlive, no key)
spawn: pilot-wp-stream[2451 ch=11]: stream fta: token-less -> heartbeat every 20s (hb_pid=2455); slot release detached via setsid
spawn: pilot-wp-stream[2451 ch=11]: fta ffmpeg started (ff_pid=2460) dashlive FIFOs -c copy -> stdout
spawn: pilot-wp-dashlive: tracks: video=1/5 audio=1/1
spawn: pilot-wp-stream[2451 ch=11]: heartbeat -> HTTP 204
```

Reading it:
- `fetch: status=…` — `ok` (streaming), `drm`/`limit`/`error` (decrypt, slate or retry).
- `stream fta|drm: token-less` / `token-gated -> session_refresh_loop` — whether the DASH URL needs periodic session refreshes; the refresh loop logs `session_refresh[ID]: proactive switch ok …` each time.
- `tracks: video=<sent>/<avail> audio=<sent>/<avail>` — one video of N ABR renditions, all M audio tracks (`video=0/0` for radio). Logged by `pilot-wp-dashlive` from the manifest; on the HLS fallback `pilot-wp-stream` parses the HLS master instead (a 10 s fetch; ffprobe if unparseable).
- `teardown (TERM)` — a graceful stop. No `teardown` line at all is normal: tvheadend SIGKILLed the process group and the detached releaser freed the slot.

Watch it live (tvheadend logs to syslog on non-systemd xbian):

```bash
tail -f /var/log/syslog | grep pilot-wp     # or /var/log/messages
```

If the lines don't appear, enable tvheadend's `spawn` debug subsystem (Configuration → Debugging, or start tvheadend with `--trace spawn`).

**Seeing the slot release.** The releaser outlives tvheadend's SIGKILL, so it can't write to the tvheadend log. Point `PILOT_WP_RELEASE_LOG` at a writable file and it appends what it does (unset = no file):

```bash
tail -f "$PILOT_WP_RELEASE_LOG"
# 2026-06-01 03:49:18 pilot-wp-release[2470 ch=11] watching main pid=2451 (token f63405a1...)
# 2026-06-01 03:49:27 pilot-wp-release[2470 ch=11] main gone; releasing slot
# 2026-06-01 03:49:27 pilot-wp-release[2470 ch=11] release: ok
```

For ffmpeg-level detail, raise its log level — `PILOT_WP_DASH_FFMPEG_FLAGS` for DASH tunes (keep `-copyts`), `PILOT_WP_HLS_FFMPEG_FLAGS` for the HLS fallback:

```bash
PILOT_WP_DASH_FFMPEG_FLAGS='-loglevel info -copyts' ./pilot-wp-stream <id> > /dev/null
```

---

## Repository layout

```
pilot-wp-cli/
├── pilot-wp-common.sh    library — endpoints, auth, fetch_channel, slot release, DASH pipeline, emit_slate
├── pilot-wp-deps         dependency checker/installer (FTA + optional DRM; single sudo prompt)
├── pilot-wp-login        first-time / re-auth entry point (terminal, or --web)
├── pilot-wp-weblogin     the temporary login page behind pilot-wp-login --web (python3 stdlib)
├── pilot-wp-status       one-shot setup health check (config, deps, session, DRM readiness)
├── pilot-wp-account-info account/subscription/location report
├── pilot-wp-ping         non-interactive cron keepalive (keeps an idle session warm)
├── pilot-wp-sessions     list/remove account login sessions (★ = ours, never removable)
├── pilot-wp-favourites   list/add/remove favourite channels
├── pilot-wp-m3u          M3U generator (v3 channels/list)
├── pilot-wp-stream       per-tune script invoked by tvheadend
├── pilot-wp-getkeys      Widevine license helper (optional DRM playback)
├── pilot-wp-dashlive     in-order live-DASH segment fetcher (FTA and DRM playback)
├── diagnostics/
│   └── pilot-wp-cdn-probe  CDN throughput probe for a stuttering channel (not used in playback)
├── config.env.example    template for config.env (all settings optional)
├── widevine/             drop your own L3 .wvd here (optional DRM playback)
├── README.md             setup guide (Polish)
├── README.en.md          setup guide (English)
├── TECHNICAL.md          this file
├── DISCLAIMER.md         scope and legal notes
└── LICENSE
```

Created at runtime next to the scripts (by default): `config.env` (your settings), `cookies.txt` (the session), `.lock`, `.m3u-drm-cache.tsv`, and `.drmvenv/` (the Python environment `pilot-wp-deps install` builds for DRM). `cookies.txt`, `config.env` and the `.wvd` are private — keep them `chmod 600` and never share them.

---

## Disclaimer

This is not an official Pilot WP client. If the official application is available for your platform, use it instead. All rights to the streamed content are reserved by wp.pl. You are responsible for ensuring your use complies with Pilot WP's Terms of Service and applicable law. The author provides no warranty and accepts no liability for misuse.
