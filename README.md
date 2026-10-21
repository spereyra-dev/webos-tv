# webos-tv

Field tools for **LG webOS TVs that are rooted but have no Developer Mode**.

If you have Dev Mode or Homebrew Channel, you probably want [`ares`](https://www.npmjs.com/package/@webos-tools/cli) and `webosbrew` instead. This repo exists for the other case: a TV where the only way in is an exploit payload, there is no `sshd`, `init.d` never runs, and the stock home screen is a wall of ads.

Everything here was verified on a **LG 55QNED80SRA** (webOS 25 / `10.3.2-33`, firmware `33.31.75`).

```sh
TV_IP=192.168.1.50 MAC_IP=192.168.1.10 ./webos-tv.sh doctor
```

---

## What it does

| Command | What it is for |
|---|---|
| `doctor` | Is the TV reachable, is SAM wedged, is the dev-mode flag present, is `/media/developer` intact, which boot activities are armed, is the clock reset? |
| `exec '<cmd>'` | Run one shell command on the TV as root, print its output. |
| `install <pkg.tar.gz>` | Install or replace an app tree — **without** the app-install service, which hangs the TV (see below). |
| `boot` | Arm the persistent SAM activities that launch your launcher at boot, reclaim the screen when LG's Home appears, and close LG's Home so the remote keeps working. |
| `icons <app-id…>` | Pull the real icons declared by the TV's own apps into `./icons/`. |
| `fix` | Move an unsigned `start-devmode.sh` aside, restore `devmode_enabled`, and clear inert `init.d` hooks that never run. |
| `debloat` | Re-apply the debloat list once, on demand — the list drifts, the app manager can drop entries. |
| `hook` | Install the corrected `init.d` debloat hook. Only useful on a TV where `init.d` actually runs (signed Dev Mode); it is inert otherwise. |

## Requirements

- A rooted webOS TV reachable on your LAN. The root channel used here is [`slopbro`](https://github.com/throwaway96/slopbro) — clone it, run it once by hand and accept the pairing prompt; it saves a client key next to the checkout (`<TV_IP>.key`). **Never commit that key.**
- Python 3 on the computer (it is the only dependency: the tool uses it for the local task channel and for slopbro).

## How it works

There is no shell on the TV, so `webos-tv.sh` borrows slopbro's:

```
webos-tv.sh ──► writes a task script ──► serves it over tiny local HTTP
                                        └─► slopbro launches its payload page
                                              └─► /bin/sh <task>  (as root on the TV)
                                                    └─► POSTs the output back
```

Nothing is hardcoded: `TV_IP`, `MAC_IP`, `SLOPBRO`, `APP_ID` and `PORT` all come from the environment.

---

## The three traps

Read [`docs/PITFALLS.md`](docs/PITFALLS.md) before touching a TV. Short version:

1. **An unsigned `start-devmode.sh` deletes `/media/developer`.** On hosts named `LGwebOSTV`, `/etc/init/devmode.conf` verifies that file with openssl; if verification fails it removes `devmode_enabled`, and the next boot runs `rm -rf /media/developer` — taking every homebrew app with it. `fix` moves that file aside and restores the flag.
2. **`luna://com.webos.appInstallService/dev/install` hangs SAM** and takes SSAP down with it (ports 3000/3001 reset the TLS handshake while AirPlay's 7000 still answers). Recovery is a **power unplug**, not a menu reboot. `install` here uses `tar` + `ls-control scan-volatile-dirs` instead.
3. **Copying files in by hand gives the app no LS2 role**, so privileged calls (`listLaunchPoints`, `launch`) fail *silently*. The workaround used in practice: read the TV's launch points once as root and bake a catalog into your launcher.

## Boot without Developer Mode

`init.d` is dead weight on these TVs: it is only executed from the signature-verified `start-devmode.sh`, which you cannot forge. What does work is SAM's own scheduler — a **persistent activity**:

```
core-boot-done ──► launch <your app>          (activity 1: boot)
LG Home appears ──► launch <your app>          (activity 2: reclaim after standby/wake)
LG Home appears ──► closeByAppId LG Home       (activity 3: hand the remote focus back)
```

`./webos-tv.sh boot` creates all three, `boot list` shows them and `boot remove` disarms them. They survive reboots, need no root at boot, and are reversible.

## Clock

This firmware has **no NTP client at all**, and the RTC drops back to 2022 after a power loss. `docs/TIME.md` explains the sources that do work from a web app (`snippets/clock-sync.js` is the drop-in).

## Safety

Everything is reversible except the pitfalls above — avoid them. `boot remove` deletes the activities, `hook` moves the dangerous file aside instead of deleting it, and `install` only ever writes inside `/media/developer/apps`.

## License

MIT. Not affiliated with LG. Use at your own risk: this talks to system services as root.
