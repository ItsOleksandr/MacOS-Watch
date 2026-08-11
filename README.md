# MacOS-Watch

**Turn your phone into a remote control for your Mac — so you never have to get up from the couch.**

You are watching YouTube or Netflix on your laptop, or on a TV connected to it, from across the room. Then the volume is too loud, an ad starts, or the episode ends and the next one needs a click. Every time, you get up.

MacOS-Watch fixes that. It runs a tiny web server on your Mac; you open a page on your phone and get a trackpad, media keys, and a volume slider. No app to install on the phone — just a browser. Nothing leaves your network.

---

## Features

- **Trackpad** — drag to move the pointer, tap to click, two-finger scroll
- **Clicks** — left, right, double
- **Playback** — play/pause, previous/next, Esc, Enter, fullscreen, mute
- **Volume** — slider, ±5 steps, and mute
- **Pairing QR code** — open the page on the Mac, scan it with the phone, done
- **Starts automatically** at login and keeps running in the background
- **Token protected** — a device without the token cannot control your Mac; use the generated one or [set your own password](#use-your-own-password)

Built with ASP.NET Core (.NET 8). Mouse and keyboard events are posted natively through CoreGraphics `CGEvent`, so pointer movement stays smooth instead of lagging behind your finger.

---

## Requirements

- A Mac with **Apple Silicon** (the build targets `osx-arm64`)
- **.NET 8 SDK** — check with `dotnet --version`, it should print `8.x`
- A phone on the **same network** as the Mac
- Optional: [`cliclick`](https://github.com/BlueM/cliclick) (`brew install cliclick`) — used only for the media play/pause key and a few exotic keys. Everything else works without it.

---

## Install

Two commands, then one permission click.

```bash
git clone https://github.com/ItsOleksandr/MacOS-Watch.git
cd MacOS-Watch
./scripts/create-signing-cert.sh
./scripts/install.sh
```

### Step 1 — `create-signing-cert.sh` (run once)

Creates a self-signed code-signing identity named `MacControl` in your login keychain.

This matters more than it looks. macOS ties the Accessibility permission to the binary's code identity. Without a stable identity, every rebuild looks like a brand-new app, and the permission you granted resets each time you reinstall. With it, you grant the permission once and it stays.

macOS may ask for your login password here — that is expected.

### Step 2 — `install.sh`

This does everything else:

- builds a self-contained single-file binary and signs it
- installs it to `~/Applications/MacControl`
- registers a LaunchAgent so it starts automatically at login
- adds the binary to the macOS firewall allow-list, if the firewall is on
- waits until the server actually answers
- checks whether Accessibility is granted
- prints the link for your phone

When it finishes you will see something like:

```
✓ Installed and running.
  Binary:  /Users/you/Applications/MacControl/MacControl
  URL:     http://192.168.0.42:5050/?token=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6
           ^ open this on your phone. The token is remembered after the first visit.
```

### Step 3 — Grant Accessibility

macOS silently discards synthetic input events until the app is trusted. Without this, the volume slider works, but **the trackpad and keys do nothing** — every button appears to work and nothing happens.

If the permission is missing, `install.sh` opens the two windows you need:

1. **System Settings → Privacy & Security → Accessibility**
2. A Finder window with the `MacControl` binary revealed

Drag `MacControl` from Finder into the list, then switch it on. Thanks to step 1, you only ever do this once.

### Step 4 — Open it on your phone

Open `http://localhost:5050` on the Mac, expand **"Open on phone"** at the bottom of the page, and scan the QR code with your phone camera.

The QR encodes your Mac's LAN address together with the access token, so there is nothing to type and no address to guess.

You can also just open the URL that `install.sh` printed. The token is stored in the phone's browser after the first visit, so from then on the plain address (`http://192.168.0.42:5050/`) is enough.

---

## Put it on the phone's home screen

The page ships a web app manifest and icons, so the shortcut gets a proper icon and name instead of a screenshot and a URL.

- **Android (Chrome):** ⋮ → *Add to Home screen*
- **iOS (Safari):** Share → *Add to Home Screen*

Visit the `?token=…` link **once before** creating the shortcut — the shortcut itself carries no token, it relies on the one already saved in the browser.

> A standalone, app-like shortcut (a WebAPK) requires HTTPS. MacOS-Watch serves plain HTTP on your LAN, so the shortcut opens in the browser. It is still one tap with the right icon — just not a separate app window.

---

## Keeping the address stable

The shortcut keeps working only as long as the address does. Two things can change it.

**The Mac's IP changes.** DHCP can hand out a different address after a reboot. Fix it on your router: find the DHCP client list (often *Address Reservation* or *Static DHCP*) and bind the Mac's MAC address to a fixed IP.

**You switch networks.** Home Wi-Fi and a phone hotspot are different networks with different addresses. Run `./scripts/status.sh` after switching — it prints the current links.

### A `name.local` address instead

```bash
./scripts/set-hostname.sh macbook-air    # → http://macbook-air.local:5050
```

This name follows the Mac whatever its IP becomes. It resolves reliably on **iOS and iPadOS**. On **Android** it depends on the version and the router — if it does not resolve, use the IP address, or the QR code, which always carries the current one.

---

## Security

MacOS-Watch lets a browser move the mouse and press keys on your Mac. Treat it accordingly.

- **A token is required.** Every `/api/*` request needs a shared secret. It is generated on first run, stored in `~/Applications/MacControl/token`, and never committed to git. Requests without it get `401`.
- **LAN only, plain HTTP.** There is no TLS and no user accounts. Run this on networks you trust — your home Wi-Fi, not café or shared public Wi-Fi.
- **Rotate the token** by deleting `~/Applications/MacControl/token` and re-running `./scripts/install.sh`.

### Use your own password

The generated token is 32 random characters — safe, but impossible to type by hand. If you would rather have a password you can remember and type into the phone yourself:

```bash
./scripts/set-password.sh
```

It asks for the password (twice, not echoed), writes it, restarts the service, and prints the new pairing link. You can also pass it directly — `./scripts/set-password.sh my-couch-remote` — or set it during the install:

```bash
./scripts/install.sh --ask-password
./scripts/install.sh --password my-couch-remote
```

Rules: at least 8 characters, and only letters, digits and `. _ ~ -`. The password travels inside the pairing URL and the QR code, so anything needing URL-escaping is rejected rather than left to break the link later.

Two things to keep in mind:

- **Every paired device has to pair again.** The phone stores the old token; open the new `?token=…` link once on each device.
- **A password you can remember is a password someone can guess.** Anyone on your network who guesses it gets your mouse and keyboard. The server logs a warning for anything under 8 characters; it does not stop you.

`MACCONTROL_TOKEN` in the environment also works, and takes precedence over the file. Note that the LaunchAgent does not inherit your shell's environment — to use it that way, add it to the `EnvironmentVariables` dict in `scripts/com.maccontrol.plist`. Setting `MACCONTROL_TOKEN` before running `install.sh` writes it to the token file instead, which is what you usually want.

---

## Scripts

| Script | What it does |
|---|---|
| `create-signing-cert.sh` | Creates the stable code-signing identity. Run once, before the first install. |
| `install.sh` | The main one: build, install, register the LaunchAgent, allow through the firewall, verify, print the phone link. |
| `publish.sh` | Builds and signs the self-contained binary. Called by `install.sh`; you rarely run it directly. |
| `status.sh` | Diagnoses the whole chain — service, socket, firewall, which devices actually reached the server, phone links, Accessibility, recent errors. |
| `set-password.sh` | Replaces the random token with a password you choose, restarts the service, prints the new pairing link. |
| `set-hostname.sh` | Sets the Mac's Bonjour name so `http://<name>.local:5050` works. Needs `sudo`. |
| `uninstall.sh` | Stops the LaunchAgent and removes the installed files. |
| `com.maccontrol.plist` | The LaunchAgent template. `install.sh` fills in absolute paths. Sets port 5050, start-at-login, and `ProcessType=Interactive` so the scheduler does not throttle the process and make the pointer stutter. |

Logs live in `~/Applications/MacControl/maccontrol.log` and `maccontrol.err.log`.

---

## Troubleshooting

Run `./scripts/status.sh` first. It checks every layer and prints ready-to-open links. The decisive line is **"Devices that have actually reached this server"**.

**It lists your phone** → the network is fine; the problem is the URL or the token. Use the exact link the script prints, or the QR code.

**It lists nothing** → the phone's packets never arrive, and nothing on the Mac can fix that. Check in this order:

1. **On Android, prefer the IP link or the QR code** over `<name>.local` — Android does not always resolve `.local` in the browser.
2. **The address must start with `http://`.** Typing `macbook-air.local:5050` by hand lets the browser try HTTPS, which fails as "cannot connect" because there is no TLS here.
3. **Same network.** The phone must be on Wi-Fi, not mobile data, and on the same SSID — a guest network or a separate 2.4/5 GHz SSID is a different network.
4. **Router client isolation** — see below.
5. **VPN or iCloud Private Relay** on the phone — disable it, or exclude local addresses.

### Proving it is the router (AP / client isolation)

Many routers, and most guest networks, let clients reach the internet but not each other. Look up the phone's IP (Settings → Wi-Fi → the network), then from the Mac:

```bash
ping -c 3 192.168.0.105 ; arp -n 192.168.0.105
```

If the ARP entry comes back `(incomplete)` while the router's own address resolves fine, the access point is dropping client-to-client traffic. ARP is a link-layer broadcast inside one subnet — no firewall, VPN or phone setting can suppress it, so this is conclusive, and no change on the Mac will help.

The fix is in the router: look for **AP Isolation** / **Client Isolation** / **Wireless Isolation** and turn it off, checking both the 2.4 GHz and 5 GHz tabs. A phone hotspot is a quick way to confirm the diagnosis — it does not isolate clients, so MacOS-Watch works there immediately.

### The trackpad and keys do nothing, but volume works

Accessibility is not granted. See step 3 above, or run `./scripts/status.sh`, which asks the running server directly and tells you.

---

## Uninstall

```bash
./scripts/uninstall.sh
```

---

## Credits

QR code generation uses [qrcodejs](https://github.com/davidshimjs/qrcodejs) by davidshimjs (MIT) — see `wwwroot/js/qrcode.LICENSE.txt`. "QR Code" is a registered trademark of DENSO WAVE INCORPORATED.

No license file is set for this project yet, which means all rights are reserved by default. If you want others to use and contribute, add one — [MIT](https://choosealicense.com/licenses/mit/) is the usual choice.
