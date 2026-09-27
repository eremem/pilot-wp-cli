#!/usr/bin/env bash
# pilot-wp-common.sh — shared library for the Pilot WP CLI suite.
# Sourceable; not directly executable.
#
# Unofficial port of plugin.video.pilot.wp. Pilot WP is operated by wp.pl;
# all rights to the content are reserved by wp.pl. Use the official client
# wherever it is available for your platform.

umask 077

# --- Path bootstrap -----------------------------------------------------------
# PILOT_WP_LIB is where the scripts live (pilot-wp-dashlive, .drmvenv, widevine/);
# PILOT_WP_HOME holds the runtime state (cookie jar, lock, M3U DRM cache) and
# defaults to the same directory.
PILOT_WP_LIB=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${PILOT_WP_CONFIG:=${PILOT_WP_HOME:-$PILOT_WP_LIB}/config.env}"
# Precedence: environment > config.env > the `:=` defaults below. config.env is
# sourced before the defaults so the values derived from it (PILOT_WP_COOKIES, the *_URL
# constants, PILOT_WP_PYTHON …) see it too; any exported variable it changed is
# then put back, so the environment wins (e.g. a one-off PILOT_WP_TRACE=1, or the
# values pilot-wp-stream / pilot-wp-ping hand to the child processes they spawn).
if [[ -f "$PILOT_WP_CONFIG" ]]; then
    declare -A _pwp_env=()
    for _pwp_v in $(compgen -e); do _pwp_env[$_pwp_v]=${!_pwp_v}; done
    source "$PILOT_WP_CONFIG"
    for _pwp_v in "${!_pwp_env[@]}"; do
        [[ "${!_pwp_v-}" == "${_pwp_env[$_pwp_v]}" ]] || printf -v "$_pwp_v" '%s' "${_pwp_env[$_pwp_v]}"
    done
    unset _pwp_v _pwp_env
fi
: "${PILOT_WP_HOME:=$PILOT_WP_LIB}"
# The cookie-jar path (default: cookies.txt in PILOT_WP_HOME).
: "${PILOT_WP_COOKIES:=$PILOT_WP_HOME/cookies.txt}"
# The lock held while the jar is written (pilot-wp-login, pilot-wp-ping).
: "${PILOT_WP_LOCKFILE:=$PILOT_WP_HOME/.lock}"
# The M3U output path is not a shared variable: it is a required CLI arg to
# pilot-wp-m3u, the only script that touches the file.

# --- Pilot WP API endpoints ---------------------------------------------------
# Primary API version is v3, falling back to v2 then v1 where a higher version
# exposes no equivalent endpoint. Captured request samples live in ../data/*.txt.
#
# DEVICE_TYPE is overridable. A stream slot's device label comes from the
# request's device_type (android_tv / android / web …), not from the login
# session — it is what lets the official web player coexist with the android_tv
# app on one login. The v2/v3 endpoints accept the original android_tv client
# identity (UA / X-Version below) unchanged.
: "${DEVICE_TYPE:=android_tv}"

# Single host for every Pilot WP API endpoint below (also used by fetch_channel to
# absolutise a relative widevine license path). The URL constants below are
# expanded from it and DEVICE_TYPE at source time.
: "${BASE_URL:=https://pilot.wp.pl}"


# User account + location (used by pilot-wp-account-info).
#   /api/v2/user           (data:null when unauthenticated)
#   /api/v1/user/location  (no >v1 equivalent)
USER_URL="${BASE_URL}/api/v2/user?device_type=${DEVICE_TYPE}&all=1"
USER_LOCATION_URL="${BASE_URL}/api/v1/user/location?device_type=${DEVICE_TYPE}"
# Account login sessions (one per logged-in device). GET lists them (each carries
# is_current=true for the session our cookie jar authenticates as); DELETE with
# body {"sessions":[{"session_id":…}, …]} removes one or more. Used by
# pilot-wp-sessions.
USER_SESSIONS_URL="${BASE_URL}/api/v1/user/sessions?device_type=${DEVICE_TYPE}"

# Channels + streaming. The "switch" close is a GET query param
# (?close_stream=<token>) on the channel endpoint (see switch_close_url), and the
# heartbeat URL + interval come back inside each channel response
# (.data.heartbeat.{url,interval}), so there is no heartbeat constant here.
CHANNELS_URL="${BASE_URL}/api/v3/channels/list?device_type=${DEVICE_TYPE}"
FAVOURITES_URL="${BASE_URL}/api/v3/channels/favourites?device_type=${DEVICE_TYPE}"
# Favourites edit endpoint (v1): POST adds, DELETE removes, body {"channels":[id,…]}
# → {"data":{"status":"ok"}}. Used by pilot-wp-favourites. Note: GET is the v3
# FAVOURITES_URL above, but add/remove are v1.
FAVOURITES_EDIT_URL="${BASE_URL}/api/v1/channels/favourites?device_type=${DEVICE_TYPE}"
VIDEO_URL="${BASE_URL}/api/v3/channel/"
EPG_URL="${BASE_URL}/api/v2/epg?device_type=${DEVICE_TYPE}"
# Pure stream close (releases a slot without opening a new session, unlike the
# ?close_stream= "switch" GET). POST body {"token":…}; returns
# {"data":{"status":"ok"}}. The web client's stop-playback call; used on teardown
# (see channels_close / release_stream). Accepts device_type=android_tv.
CHANNELS_CLOSE_URL="${BASE_URL}/api/v2/channels/close?device_type=${DEVICE_TYPE}"

# --- Android TV app impersonation headers (addon.py:31-36) --------------------
# Overridable per-invocation. Together with DEVICE_TYPE these form the device
# fingerprint Pilot WP counts concurrent streams against (the account allows ~3);
# the busy response lists each holder's device_type and user_agent.
: "${PILOT_WP_UA:=ExoMedia 4.3.0 (43000) / Android 8.0.0 / foster_e}"
: "${PILOT_WP_X_VERSION:=pl.videostar|3.53.0-gms|Android|26|foster_e}"

# --- Behavior knobs (overridable via config.env or environment) ---------------
: "${PILOT_WP_RETRIES:=3}"
# PILOT_WP_HLS_FFMPEG_FLAGS: input flags for the HLS path (the FTA fallback when DASH
# is unavailable; the DASH pipeline uses PILOT_WP_DASH_FFMPEG_FLAGS below). SDT
# metadata (service_provider / service_name) is set per-tune in pilot-wp-stream,
# so don't add -metadata here.
#
# Analysis window. With `-c copy`, the set of output streams (and the MPEG-TS
# PMT tvheadend/Kodi parse) is fixed by what ffmpeg discovers during
# avformat_find_stream_info. Pilot WP's HLS delivers audio as separate renditions
# — a main "Polski" track plus a "Polski z audiodeskrypcją" (audio-description)
# track that arrives ~4s out of sync. With too short a window ffmpeg finalizes the
# program before that rendition's first packet and the 2nd audio track is missing;
# 15MB/6s spans the offset. These are caps, not targets: ffmpeg stops once all
# streams have parameters, so channels without an offset track tune quickly.
# (The AD track stays ~4s out of sync when selected — a source quirk `-c copy`
# can't fix.)
#
# `-live_start_index -1` starts at the live edge instead of the HLS default of 3
# segments back, so ffmpeg doesn't chew through ~18s of older segments before
# emitting (faster, steadier tune). Trade-off: less cushion ahead of the live
# edge; drop the flag in config.env if a flaky channel stalls.
: "${PILOT_WP_HLS_FFMPEG_FLAGS:=-loglevel fatal -probesize 15M -analyzeduration 6000000 -live_start_index -1 -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5}"

# --- call_api METHOD URL [JSON_BODY] ------------------------------------------
# Wraps curl with all required headers, reading the cookie jar. Emits the raw
# response body on stdout. Returns 0 on transport success regardless of HTTP
# status; the caller inspects the JSON for _meta.error.
#
# The jar is opened read-only (-b, no -c): writing it back on every call races
# when several pilot-wp-stream processes tune concurrently (each curl
# truncates+rewrites the shared jar) and corrupts it. Callers that must persist
# new cookies (pilot-wp-ping) set CALL_API_SAVE_JAR=1 under the lock.
call_api() {
    local method=$1 url=$2 body=${3:-}
    local args=(
        -sS -k
        -b "$PILOT_WP_COOKIES"
        -X "$method"
        -H "User-Agent: $PILOT_WP_UA"
        -H "X-Version: $PILOT_WP_X_VERSION"
        -H "Accept: application/json"
        -H "Content-Type: application/json; charset=UTF-8"
    )
    [[ "${CALL_API_SAVE_JAR:-0}" == "1" ]] && args+=(-c "$PILOT_WP_COOKIES")
    [[ -n "$body" ]] && args+=(--data "$body")
    curl "${args[@]}" "$url"
}

# --- cookies_authorize --------------------------------------------------------
# Probes /api/v2/user to decide whether the saved cookies still authorize the
# API. An unauthenticated session returns {"data":null,"_meta":null} — HTTP 200
# with no _meta.error.name — so a numeric .data.id, not an error object, is the
# authorization signal. Exit codes separate auth rejection from a transient
# transport failure:
#   0 = authorized        (got a user object with .data.id)
#   1 = rejected          (jar empty, or server replied with data:null / no id)
#   2 = inconclusive      (transport-level failure: DNS, connect, TLS, timeout)
# resolve_auth only branches on 0 vs non-zero; pilot-wp-stream's retry loop logs
# which of the three it got, and pilot-wp-ping mirrors them as its exit codes.
cookies_authorize() {
    [[ -s "$PILOT_WP_COOKIES" ]] || return 1
    local resp
    resp=$(call_api GET "$USER_URL") || return 2
    jq -e '.data.id // empty | type == "number"' <<<"$resp" >/dev/null 2>&1 && return 0
    return 1
}

# --- write_session_cookies ID VAL ---------------------------------------------
# Overwrites the cookie jar with the two Pilot WP session cookies, in the
# Netscape format curl understands via -b/-c.
write_session_cookies() {
    local id=$1 val=$2
    local expiry=$(( $(date +%s) + 60*60*24*365 ))
    {
        printf '# Netscape HTTP Cookie File\n'
        printf '.wp.pl\tTRUE\t/\tTRUE\t%s\tnetviapisessid\t%s\n'  "$expiry" "$id"
        printf '.wp.pl\tTRUE\t/\tTRUE\t%s\tnetviapisessval\t%s\n' "$expiry" "$val"
    } > "$PILOT_WP_COOKIES"
    chmod 600 "$PILOT_WP_COOKIES"
}

# --- parse_curl_cookies -------------------------------------------------------
# Extract netviapisessid / netviapisessval from a browser "Copy as cURL"
# command supplied on stdin. The blob is inert text and must never be executed
# (that would replay a device_type=web request and is a code-injection risk);
# it is only scanned for the Cookie header.
#
#   * Handles the bash (single-quote) and cmd (double-quote) exports from
#     Firefox and Chrome; the header match is case-insensitive (Firefox emits
#     "Cookie:", Chrome "cookie:").
#   * The cookie string can contain double quotes mid-value
#     (e.g. g_state={"i_l":0,...}), so we can't stop at the first quote — we
#     take everything after "Cookie:" on that line and split on ';'.
#   * The two values have well-defined charsets (hex id, base64url-JWT val), so
#     `tr -cd` drops the trailing wrapping quote / line-continuation backslash.
# Prints "<id>\t<val>" on success; returns 1 if either cookie is missing.
parse_curl_cookies() {
    local blob cookie id val
    blob=$(cat)
    blob=${blob//$'\r'/}
    cookie=$(printf '%s\n' "$blob" \
        | grep -i 'cookie:' | head -1 \
        | sed -E 's/.*[Cc][Oo][Oo][Kk][Ii][Ee]:[[:space:]]*//')
    if [[ -z "$cookie" ]]; then
        echo "parse_curl_cookies: no Cookie header found in the pasted command" >&2
        return 1
    fi
    id=$( printf '%s' "$cookie" | tr ';' '\n' | sed -E 's/^[[:space:]]+//' \
        | grep -E '^netviapisessid='  | head -1 | cut -d= -f2- | tr -cd 'A-Za-z0-9._:-')
    val=$(printf '%s' "$cookie" | tr ';' '\n' | sed -E 's/^[[:space:]]+//' \
        | grep -E '^netviapisessval=' | head -1 | cut -d= -f2- | tr -cd 'A-Za-z0-9._-')
    if [[ -z "$id" || -z "$val" ]]; then
        echo "parse_curl_cookies: netviapisessid/netviapisessval not present in the pasted cookies" >&2
        return 1
    fi
    printf '%s\t%s\n' "$id" "$val"
}

# --- install_session_cookies ID VAL -------------------------------------------
# Validate a candidate session before it replaces the jar: write it to a temp
# jar next to the real one, check it authorizes the API, then move it into place
# under the jar lock. The working jar is never touched by a bad submission.
# Returns 0 = installed, 1 = rejected by the API, 2 = API unreachable.
install_session_cookies() {
    local id=$1 val=$2 jar=$PILOT_WP_COOKIES tmp rc=0
    mkdir -p "$(dirname "$jar")"
    tmp=$(mktemp "$jar.new.XXXXXX") || return 1
    PILOT_WP_COOKIES=$tmp write_session_cookies "$id" "$val"
    PILOT_WP_COOKIES=$tmp cookies_authorize || rc=$?
    if (( rc != 0 )); then
        rm -f "$tmp"
        return "$rc"
    fi
    mkdir -p "$(dirname "$PILOT_WP_LOCKFILE")"
    ( flock 9; mv -f "$tmp" "$jar" ) 9>"$PILOT_WP_LOCKFILE"
}

# --- read_pasted_curl ---------------------------------------------------------
# Collect a multi-line "Copy as cURL" paste from an interactive TTY. Lines are
# read until a blank one (or EOF); a cURL command never contains a blank line,
# so the sentinel is unambiguous. Echoes the collected blob on stdout; returns 1
# if nothing was entered.
read_pasted_curl() {
    local line acc=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        acc+=$line$'\n'
    done
    [[ -n "$acc" ]] || return 1
    printf '%s' "$acc"
}

# --- prompt_cookies -----------------------------------------------------------
# Interactive cookie hand-off: a logged-in browser session either as a
# "Copy as cURL" paste (default) or by typing the two cookie values. Writes the
# jar on success; returns 1 on empty/unparseable input.
prompt_cookies() {
    local method id val parsed
    cat >&2 <<'EOF'

Log in with a browser session (Pilot WP's login endpoint is Cloudflare-
Turnstile-gated, so there is no email/password login).

  [c] Paste a browser "Copy as cURL"  (recommended)
       Log in at https://pilot.wp.pl, open DevTools (F12) -> Network, click a
       channel so a pilot.wp.pl/api/... request appears, then right-click it ->
       Copy -> "Copy as cURL".
  [v] Type the two cookie values by hand
       DevTools -> Application/Storage -> Cookies -> https://pilot.wp.pl.

EOF
    read -r -p "Method [C/v]: " method || return 1
    case "${method,,}" in
        v)
            read -r -p "netviapisessid: "  id  || return 1
            read -r -p "netviapisessval: " val || return 1
            ;;
        *)
            echo "Paste the cURL command, then press Enter on an empty line (or Ctrl-D) to finish:" >&2
            parsed=$(read_pasted_curl | parse_curl_cookies) || return 1
            id=${parsed%%$'\t'*}
            val=${parsed#*$'\t'}
            ;;
    esac
    if [[ -z "$id" || -z "$val" ]]; then
        echo "prompt_cookies: empty values; aborting" >&2
        return 1
    fi
    write_session_cookies "$id" "$val"
}

# --- resolve_auth -------------------------------------------------------------
# The cookie jar (cookies.txt) is the auth artifact:
#   1. Existing jar still authorizes the API -> done.
#   2. On a TTY, an interactive cookie hand-off (prompt_cookies). The login
#      endpoint is Cloudflare-Turnstile-gated, so there is no email/password login.
# There is deliberately no way to inject cookies via config/env: a config copy
# would go stale exactly when the jar does. Refreshing stale cookies needs a
# human with a browser -> run pilot-wp-login.
# Fatal exits: 2 = jar invalid and no TTY to refresh it; 3 = the supplied cookies
# were empty/unparseable or rejected by the API.
resolve_auth() {
    cookies_authorize && return 0

    if [[ ! -t 0 ]]; then
        echo "resolve_auth: cookie jar ($PILOT_WP_COOKIES) is invalid/expired and there is no TTY to refresh it. Run ./pilot-wp-login interactively." >&2
        exit 2
    fi

    mkdir -p "$(dirname "$PILOT_WP_LOCKFILE")"
    exec 9>"$PILOT_WP_LOCKFILE"
    flock 9
    # Another process may have refreshed while we were waiting.
    if cookies_authorize; then
        exec 9>&-
        return 0
    fi

    if ! prompt_cookies; then
        exec 9>&-
        exit 3
    fi

    if ! cookies_authorize; then
        echo "resolve_auth: provided cookies did not authorize the API" >&2
        exec 9>&-
        exit 3
    fi
    exec 9>&-
}

# --- cookies_as_header --------------------------------------------------------
# Emit the value for an HTTP "Cookie:" header by parsing the Netscape jar.
# curl writes HttpOnly cookies with a "#HttpOnly_" prefix on the line
# (netviapisessid/netviapisessval are HttpOnly); a naive `!/^#/` filter would
# drop exactly those, so strip the prefix before skipping comments.
cookies_as_header() {
    awk '
        { line = $0; sub(/^#HttpOnly_/, "", line) }
        line ~ /^#/ { next }
        { n = split(line, f, "\t"); if (n == 7) print f[6] "=" f[7] }
    ' "$PILOT_WP_COOKIES" | paste -sd';' -
}

# --- jqr — jq -r with CRLF stripped -------------------------------------------
# Some jq builds (notably the Windows binary used on the dev MSYS host) emit
# CRLF; a trailing \r breaks downstream matching/arithmetic. No-op on Linux.
jqr() { jq -r "$@" | tr -d '\r'; }

# --- switch_close_url CHANNEL_ID TOKEN ----------------------------------------
# The Pilot WP "switch" GET: closes the session identified by TOKEN and, as a
# side effect, opens a fresh one (returning its .data.token). Used by
# release_stream (teardown) and switch_session (token-gated refresh).
switch_close_url() {
    printf '%s%s?close_stream=%s&device_type=%s' "$VIDEO_URL" "$1" "$2" "$DEVICE_TYPE"
}

# --- trace_line MSG -----------------------------------------------------------
# Echo MSG to stderr iff PILOT_WP_TRACE=1 (else a no-op). Callers prepend their
# own context prefix (pilot-wp-stream's trace(), session_refresh_loop's slog()).
# tvheadend captures a pipe child's stderr into its log. The detached releaser
# (spawn_releaser's rlog) logs to a file instead, since it outlives the pipe.
trace_line() { [[ "${PILOT_WP_TRACE:-0}" == 1 ]] && printf '%s\n' "$*" >&2 || true; }

# --- heartbeat_once URL -------------------------------------------------------
# POST the v3 heartbeat once; echo the HTTP status ("ERR" on transport failure).
# Sends the cookie jar read-only (-b, no -c; see call_api). Caller guards an
# empty URL. Used by pilot-wp-stream's heartbeat_loop and session_refresh_loop.
heartbeat_once() {
    curl -sS -k -m 10 -o /dev/null -w '%{http_code}' -X POST \
        -H "User-Agent: $PILOT_WP_UA" -H "X-Version: $PILOT_WP_X_VERSION" \
        -H "Accept: application/json" -H "Content-Type: application/json; charset=UTF-8" \
        -b "$PILOT_WP_COOKIES" --data '{}' "$1" 2>/dev/null || echo "ERR"
}

# --- channels_close TOKEN ------------------------------------------------------
# Pure close: releases the stream-session slot identified by TOKEN without
# opening a new one (POST CHANNELS_CLOSE_URL {"token":TOKEN}). Idempotent
# (re-closing returns status ok). Returns 0 on {"data":{"status":"ok"}},
# non-zero otherwise; no-op (0) when TOKEN is empty.
channels_close() {
    local token=${1:-} resp
    [[ -z "$token" ]] && return 0
    resp=$(call_api POST "$CHANNELS_CLOSE_URL" "$(jq -n --arg t "$token" '{token:$t}')") || return 1
    [[ "$(jqr '.data.status // empty' <<<"$resp")" == "ok" ]]
}

# --- release_stream CHANNEL_ID TOKEN ------------------------------------------
# Releases a stream slot the way the web client does. A POST close of the active
# TOKEN alone does not reliably free the slot (it lingers, and a few zaps later
# you hit multiroom_limit_exceeded), so:
#   1. switch GET ${VIDEO_URL}{id}?close_stream=TOKEN — closes TOKEN but opens a
#      fresh session and returns its .data.token.
#   2. channels_close <that new token> — closes the fresh session too.
# No-op (returns 0) when TOKEN is empty.
release_stream() {
    local id=$1 token=${2:-} resp new
    [[ -z "$token" ]] && return 0
    resp=$(call_api GET "$(switch_close_url "$id" "$token")") || return 1
    new=$(jqr '.data.token // empty' <<<"$resp")
    [[ -n "$new" ]] && channels_close "$new"
}

# --- fetch_channel CHANNEL_ID -------------------------------------------------
# v3 channel open. Emits a newline record (consume with `mapfile -t`):
#   [0] status            ok | drm | limit | error
#   [1] hls_url           preferred hls@live:abr, else any hls; "" otherwise
#   [2] heartbeat_url     full /api/v1/heartbeat URL from the response
#   [3] heartbeat_interval seconds
#   [4] token             .data.token (stream session id; heartbeat t3; close token)
#   [5] channel_name      .data.stream_channel.channel_name
#   [6] dash_url          the DASH (.mpd) stream URL; "" if none
#   [7] widevine_url      absolute Widevine license URL (BASE_URL + the relative
#                         .data.stream_channel.drms.widevine path); "" if FTA
# "ok" requires an HLS URL. pilot-wp-stream plays an FTA channel from the clear
# DASH ([6]) when fta_dash_available, else from the HLS ABR ([1]). For DRM channels
# (drms != null → status drm) the HLS is a DAI/FairPlay variant and the DASH is
# CENC — neither is `-c copy`-able as-is; the DASH is decrypted with a Widevine
# key fetched from [7] when DRM playback is enabled, else a slate is shown.
# On a transport failure the record is "error" + empty fields and it returns 1.
#
# The `drms` block only advertises license endpoints — some channels (e.g.
# ViDocTV id 273) carry it yet serve a fully clear manifest. So when `drms` is
# present and both DASH and HLS exist, we check the real DASH manifest: no
# ContentProtection → status "ok". One manifest GET (URL-token-authed; the cookie
# is never sent to the CDN), bounded by PILOT_WP_DRM_VERIFY_TIMEOUT.
fetch_channel() {
    local id=$1
    local url="${VIDEO_URL}${id}?device_type=${DEVICE_TYPE}"
    local resp
    resp=$(call_api GET "$url") || { printf 'error\n\n\n\n\n\n\n\n'; return 1; }

    # status_override stays "" unless the manifest proves the stream is clear.
    local status_override=""
    if [[ "$(jqr '(.data.stream_channel.drms // null) != null' <<<"$resp")" == "true" ]]; then
        local dash hls mpd
        dash=$(jqr '([.data.stream_channel.streams[]? | select(.type|tostring|test("dash"))][0].url[0]) // ""' <<<"$resp")
        hls=$(jqr  '([.data.stream_channel.streams[]? | select(.type|tostring|test("hls"))][0].url[0]) // ""'  <<<"$resp")
        if [[ -n "$dash" && -n "$hls" ]]; then
            # No -b/cookie here: only the URL's t2/t3/ts tokens authenticate the CDN.
            mpd=$(curl -sS -k -L -m "${PILOT_WP_DRM_VERIFY_TIMEOUT:-8}" -A "$PILOT_WP_UA" "$dash" 2>/dev/null)
            # Downgrade only on a fetched manifest with no CENC lock; a failed/empty
            # fetch leaves it DRM (fail safe).
            if [[ -n "$mpd" && "$mpd" == *"<MPD"* ]] \
               && ! grep -qiE 'ContentProtection|cenc:default_KID' <<<"$mpd"; then
                status_override="ok"
            fi
        fi
    fi

    jqr --arg so "$status_override" --arg base "$BASE_URL" '
        ( if   $so != ""                                                      then $so
          elif (._meta.error.name // "") == "multiroom_limit_exceeded"        then "limit"
          elif (.data.stream_channel.drms // null) != null                    then "drm"
          elif (([.data.stream_channel.streams[]? | select(.type|tostring|test("hls"))][0].url[0]) // "") != "" then "ok"
          else "error" end ),
        ( ([.data.stream_channel.streams[]? | select(.type|tostring|test("hls@live:abr"))][0].url[0])
          // ([.data.stream_channel.streams[]? | select(.type|tostring|test("hls"))][0].url[0]) // "" ),
        ( .data.heartbeat.url // "" ),
        ( .data.heartbeat.interval // "" ),
        ( .data.token // "" ),
        ( .data.stream_channel.channel_name // "" ),
        ( ([.data.stream_channel.streams[]? | select(.type|tostring|test("dash"))][0].url[0]) // "" ),
        ( (.data.stream_channel.drms.widevine // "")
          | if   . == ""                 then ""
            elif test("^https?://")      then .
            else $base + . end )
    ' <<<"$resp"
    # On limit, log the open-session list (the v3 busy response carries no token
    # to close, so this is informational for the operator).
    if [[ "$(jqr '._meta.error.name // empty' <<<"$resp")" == "multiroom_limit_exceeded" ]]; then
        jqr '._meta.error.info.streams[]? | "  busy: ch \(.channel_id) \(.channel_name) [\(.device_description // .device_type) @ \(.user_ip // "?")]"' \
            <<<"$resp" >&2
    fi
}

# --- is_token_gated DASH_URL --------------------------------------------------
# True (0) when the DASH URL carries time-limited query tokens (videostar: t2/t3/ts).
# Such streams lose segment access after a few minutes of continuous play and need
# session_refresh_loop. Token-less manifests (redcdn's public wp_dai.mpd has no
# query) never expire. Keyed on the URL, not a channel list, so it adapts per tune.
is_token_gated() {
    local url=${1:-}
    [[ "$url" == *'?'* ]] || return 1
    [[ "$url" == *'t3='* || "$url" == *'ts='* || "$url" == *'t2='* ]]
}

# --- switch_session CHANNEL_ID TOKEN ------------------------------------------
# Refreshes a token-gated session without releasing the slot: the switch GET
# (switch_close_url) atomically closes the old session and opens a fresh one (new
# token + fresh CDN tokens), so the slot count is unchanged. The content KID
# is unchanged across the switch, so a Widevine key stays valid. Emits a 5-line
# record (consume with mapfile -t) — note the order differs from fetch_channel:
#   [0] status ok|limit|error  [1] token  [2] heartbeat_url
#   [3] heartbeat_interval     [4] dash_url
switch_session() {
    local id=$1 token=${2:-} resp
    [[ -z "$token" ]] && { printf 'error\n\n\n\n\n'; return 1; }
    resp=$(call_api GET "$(switch_close_url "$id" "$token")") \
        || { printf 'error\n\n\n\n\n'; return 1; }
    jqr '
        ( if   (._meta.error.name // "") == "multiroom_limit_exceeded" then "limit"
          elif (.data.token // "") != ""                              then "ok"
          else "error" end ),
        ( .data.token // "" ),
        ( .data.heartbeat.url // "" ),
        ( .data.heartbeat.interval // "" ),
        ( ([.data.stream_channel.streams[]? | select(.type|tostring|test("dash"))][0].url[0]) // "" )
    ' <<<"$resp"
}

# --- drm_control_fifo_path PID ------------------------------------------------
# Path of the control FIFO that carries fresh session URLs from
# session_refresh_loop to pilot-wp-dashlive. Prefers /dev/shm (RAM) so the
# periodic URL writes never touch the SD card; falls back to TMPDIR (also tmpfs on
# xbian). Named by the pilot-wp-stream PID so concurrent tunes don't collide.
drm_control_fifo_path() {
    local dir=/dev/shm
    [[ -d "$dir" && -w "$dir" ]] || dir=${TMPDIR:-/tmp}
    echo "$dir/pilot-wp-drm-$1-ctrl.fifo"
}

# --- session_refresh_loop ID TOKEN HB_URL HB_INTERVAL DASH_URL CTRL_FIFO [REFRESH_S]
# For token-gated (videostar) DASH tunes, FTA or DRM: one backgrounded loop that
# heartbeats the session and proactively re-issues it (switch_session) every
# REFRESH_S seconds (default PILOT_WP_REFRESH_INTERVAL, 100 — before the ~136s
# token death), so the stream never 403s. It keeps token / hb_url / dash_url in
# process memory (no state file → no SD wear) and pushes each fresh dash_url to
# dashlive through CTRL_FIFO, which swaps the URL in place (the KID is stable, so
# a DRM key stays valid). Reactive fallback: SIGUSR1 (sent by dashlive on sustained
# 403s) forces an immediate switch, for a token that dies sooner than REFRESH_S.
# A catchable teardown closes the latest session; a hard SIGKILL skips that and
# the session self-expires once heartbeats stop.
session_refresh_loop() {
    local id=$1 cur_tok=$2 cur_hb=$3 hb_interval=$4 cur_dash=$5 ctrl=$6
    local refresh=${7:-${PILOT_WP_REFRESH_INTERVAL:-100}}
    [[ "$hb_interval" =~ ^[0-9]+$ ]] || hb_interval=20
    local force=0 released=0 elapsed=0 spid="" S=()
    slog() { trace_line "session_refresh[$id]: $*"; }
    slog "started (refresh=${refresh}s, hb=${hb_interval}s, ctrl=$ctrl)"
    # SIGUSR1 from dashlive (sustained 403s) -> switch now.
    trap 'force=1' USR1
    # Close the latest session on a catchable teardown (idempotent guard).
    trap 'if (( ! released )); then released=1; [[ -n "$cur_tok" ]] && release_stream "$id" "$cur_tok" >/dev/null 2>&1; fi; exit 0' TERM INT
    trap 'if (( ! released )); then released=1; [[ -n "$cur_tok" ]] && release_stream "$id" "$cur_tok" >/dev/null 2>&1; fi' EXIT
    # Open the control FIFO read-write so neither end blocks on the other; dashlive's
    # reader then sees one continuous stream (we write one line per refresh).
    # Braces scope the 2>/dev/null to the open: a bare `exec`'s redirections are
    # permanent and would silence slog.
    { exec 9<>"$ctrl"; } 2>/dev/null || true

    while :; do
        sleep "$hb_interval" & spid=$!        # interruptible sleep (USR1 wakes the wait)
        wait "$spid" 2>/dev/null || true; kill "$spid" 2>/dev/null || true   # set -e safe
        elapsed=$((elapsed + hb_interval))
        [[ -n "$cur_hb" ]] && heartbeat_once "$cur_hb" >/dev/null 2>&1 || true
        # proactive (timer) or reactive (USR1) refresh
        if (( force )) || (( elapsed >= refresh )); then
            local why; (( force )) && why=reactive || why=proactive
            mapfile -t S < <(switch_session "$id" "$cur_tok")
            if [[ "${S[0]:-}" == ok && -n "${S[4]:-}" && -n "${S[1]:-}" ]]; then
                cur_tok=${S[1]}; cur_hb=${S[2]}; cur_dash=${S[4]}
                [[ "${S[3]:-}" =~ ^[0-9]+$ ]] && hb_interval=${S[3]}
                printf '%s\n' "$cur_dash" >&9 2>/dev/null || true   # -> dashlive control FIFO
                slog "$why switch ok (elapsed=${elapsed}s) -> token ${cur_tok:0:8}..., pushed fresh URL"
                elapsed=0; force=0
            else
                slog "$why switch FAILED (status=${S[0]:-?}); retry next tick"
                force=0    # switch failed; retry next tick (reactive fallback covers a 403)
            fi
        fi
    done
}

# --- emit_slate MESSAGE [LOGO_URL] [TITLE] ------------------------------------
# Streams a looping MPEG-TS "slate" to stdout for a tune that can't play (DRM
# without decryption, slot limit, auth failure), so tvheadend shows a steady
# picture+message instead of a tune failure. Colored background, the optional
# logo in a top band, and MESSAGE below it. TITLE (the channel name) takes the
# logo's place only when no logo can be rendered. PILOT_WP_SLATE_LOGO (a local
# image) overrides the downloaded LOGO_URL. Runs until the consumer closes the pipe.
emit_slate() {
    local msg=$1 logo_url=${2:-} title=${3:-}
    local bg=${PILOT_WP_SLATE_BG:-0x101820}
    local font=${PILOT_WP_SLATE_FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}
    local size=${PILOT_WP_SLATE_SIZE:-1280x720}
    local logo="" tmplogo=""

    if [[ -n "${PILOT_WP_SLATE_LOGO:-}" && -f "${PILOT_WP_SLATE_LOGO}" ]]; then
        logo=$PILOT_WP_SLATE_LOGO
    elif [[ -n "$logo_url" ]]; then
        tmplogo=$(mktemp 2>/dev/null) || tmplogo=""
        if [[ -n "$tmplogo" ]] \
           && curl -sS -k -m 10 -H "User-Agent: $PILOT_WP_UA" -o "$tmplogo" "$logo_url" 2>/dev/null \
           && [[ -s "$tmplogo" ]]; then
            logo=$tmplogo
        else
            [[ -n "$tmplogo" ]] && rm -f "$tmplogo"
            tmplogo=""
        fi
    fi

    # Layout: a top band (height $logo_band, below a $top margin) holds the logo
    # or the title; the message is drawn $gap below that band.
    local fontsize=${PILOT_WP_SLATE_FONTSIZE:-32}
    local title_fontsize=${PILOT_WP_SLATE_TITLE_FONTSIZE:-56}
    local top=${PILOT_WP_SLATE_TOP:-60}   # top margin above the logo/title
    local logo_band=240                   # reserved logo/title height
    local gap=${PILOT_WP_SLATE_GAP:-90}   # vertical space below the band
    local body_y=$(( top + logo_band + gap ))

    # drawtext only when the font exists; otherwise the slate is image/color only
    # (no hard dependency on libfreetype/fontconfig).
    local body_draw="" title_draw=""
    if [[ -f "$font" ]]; then
        local eb=$msg; eb=${eb//\\/\\\\}; eb=${eb//:/\\:}; eb=${eb//\'/}
        body_draw="drawtext=fontfile='${font}':text='${eb}':fontcolor=white:fontsize=${fontsize}:line_spacing=10:x=(w-text_w)/2:y=${body_y}"
        if [[ -n "$title" ]]; then
            local et=$title; et=${et//\\/\\\\}; et=${et//:/\\:}; et=${et//\'/}
            # channel name, vertically centered within the band
            title_draw="drawtext=fontfile='${font}':text='${et}':fontcolor=white:fontsize=${title_fontsize}:x=(w-text_w)/2:y=${top}+(${logo_band}-text_h)/2"
        fi
    fi

    local inputs=(-f lavfi -i "color=c=${bg}:s=${size}:r=25" -f lavfi -i "anullsrc=r=48000:cl=stereo")
    local fc
    if [[ -n "$logo" ]]; then
        inputs+=(-i "$logo")
        fc="[2:v]scale=w=480:h=${logo_band}:force_original_aspect_ratio=decrease[lg]"
        fc="${fc};[0:v][lg]overlay=(W-w)/2:${top}+(${logo_band}-h)/2[b]"
        if [[ -n "$body_draw" ]]; then fc="${fc};[b]${body_draw}[v]"; else fc="${fc};[b]copy[v]"; fi
    else
        local chain=()
        [[ -n "$title_draw" ]] && chain+=("$title_draw")
        [[ -n "$body_draw" ]] && chain+=("$body_draw")
        if [[ ${#chain[@]} -gt 0 ]]; then
            local joined; joined=$(IFS=','; printf '%s' "${chain[*]}")
            fc="[0:v]${joined}[v]"
        else
            fc="[0:v]copy[v]"
        fi
    fi

    ffmpeg -hide_banner -loglevel error \
        "${inputs[@]}" \
        -filter_complex "$fc" \
        -map "[v]" -map 1:a \
        -c:v libx264 -preset veryfast -tune stillimage -pix_fmt yuv420p -g 50 \
        -c:a aac -b:a 64k \
        -f mpegts -mpegts_flags +initial_discontinuity -
    local rc=$?
    [[ -n "$tmplogo" ]] && rm -f "$tmplogo"
    return $rc
}

# --- DASH pipeline + DRM (Widevine) -------------------------------------------
# FTA channels play their clear DASH through pilot-wp-dashlive + ffmpeg (HLS is
# the fallback). Premium channels (drms != null) carry a CENC-protected DASH
# stream; when DRM playback is enabled, pilot-wp-getkeys fetches the Widevine
# content key (pywidevine) and the same pipeline decrypts with it (see
# run_dash_pipeline).
#
# PILOT_WP_PYTHON: the interpreter that runs pilot-wp-dashlive (stdlib only) and,
# for DRM, must be able to `import pywidevine`. Defaults to the venv ".drmvenv"
# inside the scripts dir (so it travels with the deployable unit), falling back to
# the system python3.
: "${PILOT_WP_PYTHON:=$([[ -x "$PILOT_WP_LIB/.drmvenv/bin/python" ]] && echo "$PILOT_WP_LIB/.drmvenv/bin/python" || echo python3)}"
# PILOT_WP_WVD: a Widevine L3 device file (.wvd). Defaults to the first *.wvd
# dropped into a "widevine/" subdir of the scripts dir (so it travels with the
# deployable unit and needs no config); empty if none, in which case DRM channels
# fall back to the slate. Any L3 .wvd works — keep its device-specific name.
# It is a device secret: chmod 600 it and never commit it (.gitignore covers
# widevine/ and *.wvd).
: "${PILOT_WP_WVD:=$(ls -1 "$PILOT_WP_LIB"/widevine/*.wvd 2>/dev/null | head -n1)}"
# ffmpeg flags for the DASH pipeline (FTA and DRM). ffmpeg is fed already-in-order
# fragmented-MP4 FIFOs (video + one per audio track) by pilot-wp-dashlive, so it
# just decrypts (DRM) and stream-copies.
#  - -copyts is required. With separate inputs ffmpeg otherwise zero-shifts each
#    one independently, erasing the true video/audio offset. Harmless when the
#    tracks are co-temporal ($Time$-addressed, e.g. TVN/Puls 2) but on
#    number-addressed channels (Zoom) video-N and audio-N are ~0.7 s apart, so
#    audio would be permanently out of sync. Values stay far below the 33-bit
#    90 kHz PTS wrap (~26.5 h).
#  - No HLS flags: no -live_start_index / -reconnect* (the inputs are local FIFOs
#    that legitimately EOF on teardown) and no big -probesize/-analyzeduration
#    (each FIFO declares one track in its init).
: "${PILOT_WP_DASH_FFMPEG_FLAGS:=-loglevel fatal -copyts}"

# drm_playback_available — succeeds (0) only when PILOT_WP_DRM_ENABLE=1, a
# readable .wvd is configured, ffmpeg is present and PILOT_WP_PYTHON can import
# pywidevine. Otherwise the caller shows the slate for DRM channels.
drm_playback_available() {
    [[ "${PILOT_WP_DRM_ENABLE:-0}" == 1 ]]            || return 1
    [[ -n "${PILOT_WP_WVD:-}" && -r "${PILOT_WP_WVD}" ]] || return 1
    command -v ffmpeg >/dev/null 2>&1                 || return 1
    "$PILOT_WP_PYTHON" -c 'import pywidevine' >/dev/null 2>&1 || return 1
    return 0
}

# fta_dash_available — true when clear (FTA) channels should play DASH via
# pilot-wp-dashlive: PILOT_WP_FTA_DASH (default 1), the dashlive script present,
# and PILOT_WP_PYTHON to run it (pywidevine is not needed without a key).
fta_dash_available() {
    [[ "${PILOT_WP_FTA_DASH:-1}" == 1 ]]           || return 1
    [[ -r "$PILOT_WP_LIB/pilot-wp-dashlive" ]]     || return 1
    command -v "$PILOT_WP_PYTHON" >/dev/null 2>&1   || return 1
    return 0
}

# run_dash_pipeline DASH_URL KEY [SERVICE_NAME] [AUDIO_ONLY] [CTRL_FIFO] [REFRESH_PID]
# — restream the live DASH as MPEG-TS on stdout, CENC-decrypting with KEY. An
# empty KEY streams a clear (FTA) DASH as-is. CTRL_FIFO / REFRESH_PID wire dashlive
# to session_refresh_loop for token-gated channels (both empty/0 otherwise).
#
# ffmpeg's -i is not pointed at the live MPD: its DASH live demuxer scrambles
# segment order on this manifest (type=dynamic, $Time$ SegmentTimeline, 2s
# minimumUpdatePeriod) while draining the 32s timeShiftBuffer, producing a
# non-monotonic TS with an ~8s audio-after-video offset and heavy frame loss that
# tvheadend's tsfix rejects (no sound, stalls, client reconnects).
#
# Instead, pilot-wp-dashlive fetches the segments strictly in order (no decrypt,
# no cookie — the DASH URL carries its own auth tokens, if any) and writes each
# track as a continuous fragmented-MP4 stream to its own FIFO. ffmpeg reads the
# FIFOs, decrypts each with the mov-demuxer -decryption_key (not the dash-demuxer
# -cenc_decryption_key, which only applies when feeding the live MPD), and muxes
# to MPEG-TS. One content key decrypts everything (single KID across video and
# every audio track, ads are inband SCTE-35, no key rotation). One FIFO per track,
# not one interleaved stream, so ffmpeg drains the large video and small audio
# streams independently.
run_dash_pipeline() {
    local dash_url=$1 key=$2 svc=${3:-} audio_only=${4:-0} ctrl_fifo=${5:-} refresh_pid=${6:-0}
    # Audio-only (radio) channels declare service_type=digital_radio in the SDT so
    # tvheadend classifies the service as radio. With audio_only=1 there is no
    # video FIFO or video map — dashlive streams only the audio AdaptationSet(s).
    local svc_type="" has_video=1
    if [[ "$audio_only" == 1 ]]; then svc_type="-mpegts_service_type digital_radio"; has_video=0; fi

    # Discover the audio track plan up front (one cookie-free MPD GET): one BCP-47
    # lang per audio AdaptationSet, document order. Some channels carry multiple
    # audio tracks (e.g. Stopklatka: pol + original); all are restreamed. If the
    # plan query fails, fall back to a single audio track so a transient hiccup
    # doesn't kill the tune.
    local langs=()
    mapfile -t langs < <("$PILOT_WP_PYTHON" "$PILOT_WP_LIB/pilot-wp-dashlive" \
        --audio-plan --mpd "$dash_url" --ua "$PILOT_WP_UA" 2>/dev/null)
    local naud=${#langs[@]}
    if (( naud < 1 )); then langs=("und"); naud=1; fi

    # Reap any stale FIFOs left by a prior hard SIGKILL (>60 min old), in both the
    # data-FIFO dir and /dev/shm (the control FIFO).
    find "${TMPDIR:-/tmp}" /dev/shm -maxdepth 1 -name 'pilot-wp-drm-*.fifo' -mmin +60 -delete 2>/dev/null || true

    # FIFOs: one per audio track, plus a video FIFO unless audio-only. dashlive
    # feeds audio set i → afs[i] (and video → vf when present).
    local fifos=() dlargs=(--mpd "$dash_url" --ua "$PILOT_WP_UA")
    local vf="" i
    if (( has_video )); then
        vf=$(drm_fifo_path v); fifos+=("$vf"); dlargs+=(--video-fifo "$vf")
    fi
    local afs=() af
    for (( i = 0; i < naud; i++ )); do
        af=$(drm_fifo_path "a$i")
        afs+=("$af"); fifos+=("$af"); dlargs+=(--audio-fifo "$af")
    done
    rm -f "${fifos[@]}"
    mkfifo "${fifos[@]}" || { echo "pilot-wp: mkfifo failed" >&2; return 1; }

    # In-order live fetcher feeds the FIFOs (backgrounded; self-exits on EOF). When
    # tracing, it logs a one-line track summary (video=<v>/<reps> audio=<sent>/<sets>),
    # the DASH counterpart of pilot-wp-stream's HLS trace_tracks.
    [[ "${PILOT_WP_TRACE:-0}" == 1 ]] && dlargs+=(--log-tracks)
    # Token-gated channels only: dashlive reads fresh URLs from the control FIFO
    # and SIGUSR1s the refresh loop on sustained 403s (see session_refresh_loop).
    [[ -n "$ctrl_fifo" ]] && dlargs+=(--control-fifo "$ctrl_fifo" --refresh-signal-pid "$refresh_pid")
    # FTA: some MPDs list an HEVC AdaptationSet before the H.264 one, while the HLS
    # fallback is H.264-only — prefer avc1 so the codec doesn't depend on the path.
    [[ -z "$key" && -n "${PILOT_WP_FTA_DASH_CODEC-avc1}" ]] \
        && dlargs+=(--video-codec "${PILOT_WP_FTA_DASH_CODEC-avc1}")
    # shellcheck disable=SC2086
    "$PILOT_WP_PYTHON" "$PILOT_WP_LIB/pilot-wp-dashlive" \
        "${dlargs[@]}" ${PILOT_WP_DASHLIVE_ARGS:-} &

    # ffmpeg inputs: video (when present) is input 0, then one per audio FIFO. With
    # a KEY, every input is decrypted with it (single shared KID).
    local inputs=() maps=() metas=() idx=0 dec=()
    [[ -n "$key" ]] && dec=(-decryption_key "$key")
    if (( has_video )); then
        inputs+=(${dec[@]+"${dec[@]}"} -i "$vf")
        maps+=(-map 0:v:0)
        idx=1
    fi
    for (( i = 0; i < naud; i++ )); do
        inputs+=(${dec[@]+"${dec[@]}"} -i "${afs[i]}")
        maps+=(-map "${idx}:a:0")
        metas+=(-metadata:s:a:"$i" "language=${langs[i]}")
        idx=$((idx + 1))
    done
    # `exec` so that, when backgrounded, $! is ffmpeg itself (the caller's cleanup
    # kills it directly). The fetcher exits on broken pipe once ffmpeg is gone; the
    # caller's cleanup removes the FIFOs.
    # shellcheck disable=SC2086
    exec ffmpeg \
        -hide_banner \
        $PILOT_WP_DASH_FFMPEG_FLAGS \
        "${inputs[@]}" \
        "${maps[@]}" \
        -c copy \
        -metadata "service_provider=Pilot WP" \
        -metadata "service_name=${svc}" \
        "${metas[@]}" \
        -f mpegts -mpegts_flags +initial_discontinuity $svc_type -
}

# drm_fifo_path SUFFIX — the per-process FIFO path for a DASH track feed (v, a0,
# a1, …; FTA or DRM). Named by the pilot-wp-stream PID ($$, shared by the
# run_dash_pipeline subshell) so concurrent tunes don't collide and the parent's
# cleanup glob (pilot-wp-drm-$$-*.fifo) finds every track FIFO.
drm_fifo_path() {
    echo "${TMPDIR:-/tmp}/pilot-wp-drm-$$-$1.fifo"
}
