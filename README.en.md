[Polski](README.md) · **English**

# pilot-wp-cli

A set of scripts that let you watch [Pilot WP](https://pilot.wp.pl) channels on your TV through a home server running [tvheadend](https://tvheadend.org/) — in Kodi, for example — instead of the official app. The scripts run on Linux, e.g. on a Raspberry Pi with xbian.

What you get:

- **A channel list for tvheadend** — with logos, grouped by category. It includes the free channels and the ones your subscription covers.
- **Picture and sound in their original quality** — streams are never re-encoded, and every audio track is kept.
- **A clear message instead of an error** — when a channel can't be played (e.g. your account's limit of simultaneous streams is reached), an information screen explains why.
- **Optionally: DRM-protected channels** (e.g. TVN) — if you provide your own Widevine device file (see [DRM channels](#optional-drm-channels)).

> This is an unofficial project, not affiliated with wp.pl. It only lets you watch what your own account gives you access to. If the official Pilot WP app works on your device, use it. See the [disclaimer](DISCLAIMER.md).

## Contents

- [What you need](#what-you-need)
- [Step 1. Copy the scripts to the server](#step-1-copy-the-scripts-to-the-server)
- [Step 2. Install the missing programs](#step-2-install-the-missing-programs)
- [Step 3. Connect your Pilot WP account](#step-3-connect-your-pilot-wp-account)
- [Step 4. Check that everything works](#step-4-check-that-everything-works)
- [Step 5. Create the channel list](#step-5-create-the-channel-list)
- [Step 6. Add the channels to tvheadend](#step-6-add-the-channels-to-tvheadend)
- [Step 7. Keep the session from expiring](#step-7-keep-the-session-from-expiring)
- [Optional: DRM channels](#optional-drm-channels)
- [Optional: refreshing the channel list automatically](#optional-refreshing-the-channel-list-automatically)
- [Common problems](#common-problems)
- [More information](#more-information)

## What you need

- **A Pilot WP account.** Free channels work without a subscription; the others work if your package includes them.
- **A Linux server with tvheadend up and running** — e.g. a Raspberry Pi with xbian, Raspberry Pi OS or Ubuntu. You need access to the server's terminal (e.g. over SSH) and `sudo` rights.
- **A computer on the same home network** with Chrome or Firefox — to connect your account.
- **A player** that connects to tvheadend — e.g. Kodi with the *Tvheadend HTSP Client* add-on.

**Paths in the examples.** The commands below assume that tvheadend runs as the user `xbian` and that the scripts live in `/home/xbian/.hts/tvheadend/scripts/pilot-wp-cli`. On a different system, substitute your own values. To find out which user tvheadend runs as:

```bash
ps -o user= -C tvheadend
```

(on Debian, Ubuntu and Raspberry Pi OS it is usually `hts`, and tvheadend's home directory is `/home/hts/.hts/tvheadend`).

## Step 1. Copy the scripts to the server

The scripts are on GitHub: https://github.com/eremem/pilot-wp-cli. The simplest way is to download them straight onto the server.

### Recommended: with git

**On the server (in the terminal):**

```bash
sudo apt install git
sudo git clone https://github.com/eremem/pilot-wp-cli.git /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
cd /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
sudo chmod +x pilot-wp-*
```

Later, you can update the scripts with a single command (your settings and saved session are left untouched):

```bash
sudo -u xbian git -C /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli pull
```

### Alternative: a ZIP archive

1. **On your computer:** on the project page, click **Code** → **Download ZIP**, and unpack the downloaded archive.
2. Copy the unpacked folder to your home directory on the server — e.g. with `scp`, WinSCP or a network share. It is usually called `pilot-wp-cli-main`; if yours is named differently, change the name in the command below.
3. **On the server (in the terminal):** move the files into place, change to the directory, and make the scripts executable:

   ```bash
   sudo mkdir -p /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
   sudo cp -r ~/pilot-wp-cli-main/. /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/
   cd /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
   sudo chmod +x pilot-wp-*
   ```

Whichever way you choose, run all the following commands in `/home/xbian/.hts/tvheadend/scripts/pilot-wp-cli`.

## Step 2. Install the missing programs

The scripts need a few common programs (including `ffmpeg`, `curl`, `jq` and `python3`). `pilot-wp-deps` checks for them and installs whatever is missing.

**On the server:**

```bash
./pilot-wp-deps                # report only: what's there and what's missing (changes nothing)
sudo ./pilot-wp-deps install   # install the missing programs
```

If you don't plan to watch DRM channels, add `--no-drm` to skip everything that only they need:

```bash
sudo ./pilot-wp-deps install --no-drm
```

Finally, hand the directory over to the tvheadend user, so that tvheadend can run the scripts and read their files:

```bash
sudo chown -R xbian:xbian /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
```

> Automatic installation works on Debian-based systems (xbian, Raspberry Pi OS, Ubuntu). On other distributions, `pilot-wp-deps` only lists what's missing, and you install those programs yourself.

## Step 3. Connect your Pilot WP account

The scripts don't know your password and don't log in by themselves — Pilot WP's login page is protected against automated logins. So you log in as usual in your browser and then hand the browser's session over to the server. The easiest way is a temporary page that the server starts for you.

### Recommended: the page in your browser

1. **On the server:** run this (it must be run as the tvheadend user):

   ```bash
   sudo -u xbian ./pilot-wp-login --web
   ```

   It prints the page's address, e.g. `http://192.168.1.20:8199/`, and a six-digit code.
2. **On your computer:** open that address in a browser. The page walks you through it step by step: log in at pilot.wp.pl, copy one request from the browser's developer tools, paste it into the page, and enter the code from the terminal.
3. The server checks with Pilot WP that the session works before it saves it, so a failed attempt can't break anything. Once connected, the page confirms it and the command on the server finishes.

The page only works on your home network. It stops by itself after a successful connection, after 15 minutes, or after 5 wrong codes — in that case, just run the command again.

After connecting, you can close the Pilot WP tab, but **don't log out** there — logging out will also end the session you handed to the server.

### Other ways

**Pasting in the server's terminal.** If you'd rather not start the page, you can paste the copied request straight into the terminal:

1. **On your computer, in the Pilot WP tab:** log in at https://pilot.wp.pl, press <kbd>F12</kbd>, and switch to the **Network** tab of the tools panel.
2. **In the same tab:** click any channel on the page, then type `api` into the panel's **Filter** box.
3. **In the Network tab:** right-click any row and choose:
   - Chrome: **Copy** → **Copy as cURL (bash)** (**Copy as cURL (cmd)** works too),
   - Firefox: **Copy Value** → **Copy as cURL (POSIX)**.
4. **On the server:** run `sudo -u xbian ./pilot-wp-login`, choose `c`, paste the copied text, and finish by pressing <kbd>Enter</kbd> on an empty line.

Instead of pasting the whole request, you can also choose `v` and type in the two cookie values by hand: `netviapisessid` and `netviapisessval`. You'll find them in the browser's tools panel: Chrome — **Application** tab → **Cookies** → **https://pilot.wp.pl**; Firefox — **Storage** tab → **Cookies** → **https://pilot.wp.pl**.

**Copying the session from another server.** If the scripts already run on another server, you can bring its `cookies.txt` file over:

```bash
sudo install -m 600 -o xbian -g xbian cookies.txt /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/cookies.txt
```

## Step 4. Check that everything works

**On the server:**

```bash
sudo -u xbian ./pilot-wp-status
```

This checks the installed programs, the connection to your account, and whether DRM channels are ready to play. It changes nothing. If the **Summary** section at the end says `ready for free-to-air streaming`, you can watch the channels without DRM. Warnings in the **DRM playback** section are normal at this point.

To see your account details — your packages with their validity dates, and the country Pilot WP thinks the server is connecting from — run:

```bash
sudo -u xbian ./pilot-wp-account-info
```

## Step 5. Create the channel list

**On the server:**

```bash
sudo -u xbian ./pilot-wp-m3u channels.m3u
```

This creates the file `channels.m3u`, which tvheadend will read in the next step. The first run takes a few minutes: the script briefly opens each channel in turn to check whether it is DRM-protected (such channels get a `DRM` tag in tvheadend). So it's best not to watch Pilot WP on other devices meanwhile. Later runs are quick, because the result is remembered.

You only need to create the list again when the channel lineup changes (e.g. a new channel appears or you change your package).

## Step 6. Add the channels to tvheadend

Open the tvheadend web interface in a browser (usually `http://SERVER-ADDRESS:9981`), then:

1. Go to **Configuration** → **DVB Inputs** → **Networks** and click **Add**. Choose **IPTV Automatic Network** as the type.
2. Fill in the form:
   - **Network name:** e.g. `Pilot WP`,
   - **URL:** `file:///home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/channels.m3u` (with three slashes at the start),
   - untick **Scan after creation** and **Idle scan muxes** — background scans would start channels nobody is watching and use up your account's limit of simultaneous streams.

   Click **Create**.
3. In the list of networks, select `Pilot WP` and click **Force Scan**. The scan takes a while, because each channel is started briefly.
4. Go to **Configuration** → **DVB Inputs** → **Services**, click **Map services** → **Map all services**, and confirm with **Map services**.

The channels appear under **Configuration** → **Channel / EPG** → **Channels**, and in every player connected to tvheadend, such as Kodi.

> **Radio channels.** tvheadend only recognises a radio station once it has been played. If a radio channel ends up among the TV channels, play it once, or set its **Service type** to **Radio** by hand under **Services**.

## Step 7. Keep the session from expiring

The Pilot WP session extends itself as long as it's being used. But if the server doesn't play anything for a long time, it can expire — you'll then see an authentication-error screen instead of the picture and have to repeat [step 3](#step-3-connect-your-pilot-wp-account). To prevent this, add `pilot-wp-ping` to the tvheadend user's schedule (cron); it "refreshes" the session every few hours.

**On the server:**

```bash
sudo crontab -u xbian -e
```

and add this line at the end:

```cron
0 */8 * * * /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp-ping
```

`pilot-wp-ping` doesn't count towards your stream limit and prints nothing when all is well. If the session expires anyway, simply connect your account again.

## Optional: DRM channels

Some channels (e.g. TVN) are protected with Widevine DRM. By default, an information screen is shown in their place. To watch them, you need your own **Widevine L3 device file** (`.wvd`). The project doesn't include one — you create it yourself from an Android emulator running on your own computer, and you alone are responsible for using it lawfully (see the [disclaimer](DISCLAIMER.md)).

**Getting a `.wvd` file (in short):**

1. **On your computer:** install [Android Studio](https://developer.android.com/studio) and, in **Device Manager**, create a virtual device with a **Google APIs** system image — not "Google Play", because that image can't be run with root rights, which you need.
2. Start the emulator and extract the device file with a Frida-based tool such as [KeyDive](https://github.com/hyugogirubato/KeyDive) — follow its instructions. The result is a file with the `.wvd` extension.

**Enabling DRM on the server:**

1. Copy the `.wvd` file into the `widevine/` subdirectory of the scripts directory, and protect it:

   ```bash
   sudo chown xbian:xbian widevine/*.wvd
   sudo chmod 600 widevine/*.wvd
   ```

2. Install the components DRM needs (if you used `--no-drm` in step 2), and hand the directory over to the tvheadend user again:

   ```bash
   sudo ./pilot-wp-deps install
   sudo chown -R xbian:xbian /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli
   ```

3. Turn on DRM playback in the settings file. If you don't have a `config.env` file yet, create it from the example:

   ```bash
   sudo -u xbian cp config.env.example config.env
   sudo -u xbian chmod 600 config.env
   ```

   Open `config.env` in an editor (e.g. `sudo -u xbian nano config.env`) and replace the line `#PILOT_WP_DRM_ENABLE=0` with:

   ```bash
   PILOT_WP_DRM_ENABLE=1
   ```

4. Check the result with `sudo -u xbian ./pilot-wp-status` — the **DRM playback** section should show `DRM ready  : yes`.

There's no need to create the channel list again — the DRM channels are already on it.

## Optional: refreshing the channel list automatically

You can refresh the channel list automatically, e.g. once a day with cron. **But you do so at your own risk:** when Pilot WP renames a channel, changes its logo, or removes it, tvheadend will treat it as a new service after reading the new list and delete the old one — together with its channel mapping and settings (e.g. the channel number). You'll then have to map the services again (step 6, item 4) and fix some channel settings by hand.

That's why we recommend creating the list by hand ([step 5](#step-5-create-the-channel-list)) when you notice a change in the lineup, and then checking the channels in tvheadend. If you still prefer automatic refreshes, add this to the tvheadend user's cron (`sudo crontab -u xbian -e`):

```cron
0 4 * * * /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/pilot-wp-m3u /home/xbian/.hts/tvheadend/scripts/pilot-wp-cli/channels.m3u
```

## Common problems

- **An authentication-error screen ("Authentication failed")** — the session has expired, or tvheadend can't read the `cookies.txt` file because it belongs to a different user. Connect your account again ([step 3](#step-3-connect-your-pilot-wp-account)), making sure to use `sudo -u xbian`, and check the result with `sudo -u xbian ./pilot-wp-status`.
- **A "stream limit has been reached" screen** — your account is already playing as many channels at once as Pilot WP allows (other devices and open browser tabs count too). Stop watching elsewhere. `sudo -u xbian ./pilot-wp-sessions` lists the devices logged in to your account, and `sudo -u xbian ./pilot-wp-sessions remove NUMBER` removes a session you don't need.
- **A "protected by DRM" screen** — DRM playback is turned off or isn't working. See [DRM channels](#optional-drm-channels), and check the **DRM playback** section of the `pilot-wp-status` output. If it used to work and has stopped, Google may have blocked the `.wvd` file — you'll need a new one.
- **No channels in tvheadend** — check that the list's address has three slashes (`file:///…`) and that `channels.m3u` exists and belongs to the tvheadend user, then run **Force Scan** and **Map services** again (step 6).
- **The picture stutters** — increase the amount of data the scripts fetch ahead. In `config.env` (create it as in the DRM section, item 3), replace the line `#PILOT_WP_DASHLIVE_ARGS=` with `PILOT_WP_DASHLIVE_ARGS="--prebuffer 30"`. On a slow connection, you can also lower the picture quality: `PILOT_WP_DASHLIVE_ARGS="--prebuffer 30 --max-video-bw 4000000"`.
- **A radio channel is listed among the TV channels** — see the note on radio channels in [step 6](#step-6-add-the-channels-to-tvheadend).
- **No TV guide (EPG)** — the scripts don't provide a programme guide. You can connect an external EPG source (XMLTV) in tvheadend.
- **The login page won't open** — your computer must be on the same home network as the server. Make sure you're using the address printed in the terminal, and that the server's firewall allows port `8199` (you can choose a different port with `--port`).
- **"Permission denied" when running the scripts** — the scripts have lost their executable flag, e.g. when copied from Windows. Run `sudo chmod +x pilot-wp-*` again.

## More information

- [config.env.example](config.env.example) — every setting, with its default value.
- [DISCLAIMER.md](DISCLAIMER.md) — legal notes.
- [LICENSE](LICENSE) — the licence.
