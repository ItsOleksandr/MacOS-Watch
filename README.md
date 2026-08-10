# MacControl

Turn your phone into a remote for your Mac. MacControl runs a tiny local web
server on your Mac; open its page from any phone or tablet on the **same Wi-Fi**
and you get a trackpad, media controls, a volume slider, and common keys — no app
to install on the phone, just a browser.

It's an ASP.NET Core (.NET 8) minimal-API app. Mouse and keyboard events are
posted natively through CoreGraphics `CGEvent`, so pointer movement stays smooth.
It installs as a macOS **LaunchAgent** and starts automatically at login.

## Features

- **Trackpad** — drag to move the pointer, tap to click, two-finger scroll
- **Clicks** — left / right / double
- **Playback** — play/pause, previous/next, Esc, Enter, fullscreen, mute
- **Volume** — slider plus ±5 and mute
- Works from any browser; the page is served by the Mac itself

## Requirements

- A Mac with **Apple Silicon** (the build targets `osx-arm64`)
- **.NET 8 SDK** to build (`dotnet --version` should report 8.x)
- Optional: [`cliclick`](https://github.com/BlueM/cliclick) at
  `/usr/local/bin/cliclick` — used only for the media play/pause key and a few
  exotic keys (`brew install cliclick`). Everything else uses native CGEvent.

## Install

Two commands, then one permission click.

```bash
./scripts/create-signing-cert.sh   # once — a stable code identity
./scripts/install.sh               # build, install, start, verify
```

**1. `create-signing-cert.sh` (once).** Creates a self-signed code-signing
identity. Without it every rebuild is a new code identity to macOS, which resets
the Accessibility grant each time you publish.

**2. `install.sh`.** Publishes a self-contained binary to
`~/Applications/MacControl`, installs a LaunchAgent so it starts at login, waits
until the server answers, and prints the link for your phone:

```
✓ Installed and running.
  URL:  http://192.168.0.106:5050/?token=8c393a49e6557137cca5797658121efd
```

**3. Grant Accessibility.** macOS discards synthetic input events until the binary
is trusted, so the trackpad and keys do nothing without it (volume still works —
it goes through AppleScript, not input events). `install.sh` checks this and, if
the grant is missing, opens both windows you need: the Accessibility pane and a
Finder window with the binary revealed. Drag `MacControl` into the list and switch
it on. It never asks again on later installs, because the code identity is stable.

**4. Open the link on your phone**, on the same network. The token is stored in
the browser, so afterwards `http://<ip>:5050/` is enough.

That is the whole cycle. To check it later, or after switching networks:

```bash
./scripts/status.sh
```

### Put it on the phone's home screen

The page ships a web app manifest and icons, so the shortcut gets a proper icon
and name instead of a screenshot and a URL:

- **Android (Chrome):** ⋮ → *Add to Home screen*
- **iOS (Safari):** Share → *Add to Home Screen*

> Chrome only builds a standalone, app-like shortcut (a WebAPK) over **HTTPS**.
> MacControl serves plain HTTP on the LAN, so the shortcut opens in the browser.
> That is a one-tap launch with the right icon — just not a separate app window.

Visit the `?token=…` link **once before** creating the shortcut: the token is kept
in the browser's local storage for that address, and the shortcut itself carries
no token.

### Keeping the address stable

The shortcut points at whatever address you used, so it keeps working only while
that address does. Two things can break it:

**The Mac's IP changes.** DHCP can hand out a different address after a reboot or
a lease expiry. Fix it at the router: find the DHCP client list (often *Address
Reservation* or *Static DHCP*) and bind the Mac's MAC address to a fixed IP.

**You switch networks.** Home Wi-Fi, a phone hotspot and a mobile modem are
different networks with different addresses, so each needs its own shortcut. Run
`./scripts/status.sh` after switching — it prints the current links.

#### What about a `name.local` address?

```bash
./scripts/set-hostname.sh macbook-air   # → http://macbook-air.local:5050
```

This is stable across IP changes, but **only iOS and iPadOS resolve it**.
**Android does not resolve `.local` in the browser** — there, use the IP. Some
routers also publish DHCP hostnames on their own DNS, in which case plain
`http://macbook-air:5050` (no `.local`) may work on Android too; worth a try.

## Security

MacControl lets a browser move the mouse and press keys on your Mac, so treat it
accordingly:

- **Token required.** Every `/api/*` call needs a shared secret. It is generated
  on first run, stored in `~/Applications/MacControl/token`, and never committed.
  Requests without the right token get `401`. You can override it by setting the
  `MACCONTROL_TOKEN` environment variable in the LaunchAgent plist.
- **LAN only, plain HTTP.** There is no TLS and no user accounts. Run this only on
  networks you trust — your home Wi-Fi, not a café or shared/public network.
- **Firewall.** `install.sh` adds the binary to the macOS application firewall
  allow-list (with `sudo`) if the firewall is on, so the LAN handshake isn't
  dropped.

To rotate the token: delete `~/Applications/MacControl/token` and re-run
`./scripts/install.sh` (a new one is generated), or set `MACCONTROL_TOKEN`.

## Troubleshooting: the phone can't reach the site

Run `./scripts/status.sh` — it checks the whole chain and prints ready-to-open
links. The decisive line is **"Devices that have actually reached this server"**:

- **It lists your phone's IP** → the network is fine; the problem is the URL or
  the token. Open the exact link the script prints.
- **It lists nothing** → the phone's packets never arrive, so nothing on the Mac
  can fix it. Check, in this order:
  1. **On Android, use the IP link, not `<name>.local`.** Android does not resolve
     `.local` in the browser, so the name fails while the IP works. This is by far
     the most common cause.
  2. The address really starts with **`http://`**. Typing `macbook-air.local:5050`
     into the address bar lets Safari/Chrome try **https** — there is no TLS here,
     so that fails as "cannot connect". Tap the full `http://…` link instead.
  3. The phone is on **Wi-Fi**, not mobile data, and on the **same** SSID — a
     guest network or a separate 2.4/5 GHz SSID is a different network.
  4. The router has **AP / client isolation** enabled — see below.
  5. A **VPN** or **iCloud Private Relay** is active on the phone — disable it,
     or exclude local addresses.

### Proving it is the router (AP / client isolation)

Some routers, and most guest networks, let clients talk to the internet but not
to each other. Look up the phone's own IP (Settings → Wi-Fi → the network), then
from the Mac:

```bash
ping -c 3 192.168.0.105 ; arp -n 192.168.0.105
```

If the ARP entry comes back `(incomplete)` while the router's own address
resolves fine, the access point is dropping client-to-client traffic. ARP is a
link-layer broadcast inside one subnet — no firewall, VPN or phone setting can
suppress it, so this is conclusive and no change on the Mac will help.

The fix is in the router: look for **AP Isolation** / **Client Isolation** /
**Wireless Isolation** and turn it off (check both the 2.4 GHz and 5 GHz tabs).
A phone hotspot is a quick way to confirm this — it does not isolate clients, so
MacControl works there immediately.

## Managing the service

```bash
./scripts/status.sh      # diagnose why the phone can't reach it
./scripts/uninstall.sh   # stop and remove everything
```

Logs live at `~/Applications/MacControl/maccontrol.log` and `maccontrol.err.log`.

## How it works

- `Program.cs` — minimal API: the `/api/*` endpoints plus the token middleware
  and the `0.0.0.0:5050` bind (so devices other than the Mac can reach it).
- `SystemControl.cs` / `NativeInput.cs` — volume via `osascript`; mouse and keys
  via CoreGraphics `CGEvent`.
- `Pages/Index.cshtml` — the single-page phone UI.
- `scripts/` — publish (self-contained single-file), install as a LaunchAgent,
  signing, hostname, status, uninstall.

## License

No license is set yet, so all rights are reserved by default. If you want others
to use and contribute, add one (e.g. [MIT](https://choosealicense.com/licenses/mit/))
as a `LICENSE` file before making the repo public.
