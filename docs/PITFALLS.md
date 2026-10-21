# Three traps in this firmware

Observed on a 55QNED80SRA (webOS 25 / `10.3.2-33`, firmware `33.31.75`). None of them appear in the usual tutorials.
Each one leaves the TV in a state that looks fine until the next boot.

## 1. An unsigned `start-devmode.sh` deletes `/media/developer`

**The rule: don't put that file there.** On these TVs boot persistence comes from a persistent
SAM activity (`./webos-tv.sh boot`), never from `init.d` — `init.d` is only executed by the
signature-verified script below, which cannot be forged. If you inherited a TV with that file
already in place, `./webos-tv.sh fix` moves it aside and restores the dev-mode flag.

The whole `init.d`-based approach to homebrew persistence depends on this file:

```
/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh
```

On a host named `LGwebOSTV`, `/etc/init/devmode.conf` **verifies it with openssl** against
`/usr/palm/services/com.palm.service.devmode/pub.pem`:

```sh
if [ -f ${DEVSHFILE} ] ; then
    if [ -f ${KEYFILE} ] && [ -f ${DEVSIGFILE} ] \
        && [ "$(openssl dgst -sha512 -verify ${KEYFILE} -signature ${DEVSIGFILE} ${DEVSHFILE})" == "Verified OK" ] ; then
        chmod -f 700 ${DEVSHFILE} ; ${DEVSHFILE}
    else
        # verification failed -> disable developer mode
        rm -rf /var/luna/preferences/devmode_enabled
        rm -rf /var/luna/preferences/dc*
        rm -rf .../devSessionTime
        jailer -D -i "com.palm.devmode.openssh"
    fi
fi
...
# Non developer mode, remove developer apps
if [ ! -e /var/luna/preferences/devmode_enabled ] ; then
    rm -rf /media/developer
fi
```

There is no `start-devmode.sig` unless LG signed it, so **any copy you place there fails
verification**: the flag disappears, and the next boot wipes `/media/developer` — every
homebrew app, including Homebrew Channel itself. `/var` and `/media/cryptofs` survive, which
makes it look like nothing happened until you notice the app is gone.

Notes:
- `devmode_enabled` is a **directory**, not a file.
- The `elif` branch that runs the script *without* verification only exists for hosts that are
  not `LGwebOSTV` (emulators).
- If you already created the file: move it away (`webos-tv.sh hook` does this), then
  `mkdir -p /var/luna/preferences/devmode_enabled`.

## 2. `dev/install` hangs SAM and kills SSAP

```sh
# DON'T
luna-send -i -f luna://com.webos.appInstallService/dev/install '{"id":"…","ipkUrl":"…"}'
```

On this firmware it never returns. Afterwards:

```
3001 TLS  → connection reset
3000 HTTP → no response
7000 AirPlay → still answers 403 with /info     ← the TV is alive, its app manager is not
```

Only a **power unplug** clears it. A menu reboot and even the power button (standby) do not.

What works instead — install is just unpacking into the app tree plus a rescan:

```sh
cd /media/developer/apps && tar xz < pkg.tar.gz   # tree must contain usr/palm/applications/<appId>
ls-control scan-volatile-dirs                     # "telling hub to scan manifests from volatile directories"
luna-send -n 1 luna://com.webos.applicationManager/launch '{"id":"<appId>"}'
```

`tar` of a built app is the `data.tar` of the `.ipk`: `usr/palm/applications/<appId>/…`
(and `usr/palm/services/<appId>.service/…` for the service half).

## 3. A hand-installed app has no LS2 role, so privileged calls fail silently

`ares-install` does more than copy files: it creates the app's jail and role under
`/var/palm/ls2-dev`, which is what grants `listLaunchPoints` / `launch` / `tvpower`. Since the
whole point of this repo is skipping `ares`, that directory is often **missing**, and every
privileged call from the app is denied. Worse, the usual pattern hides it:

```js
listLaunchPoints().then(…).catch(() => { /* catalog-only is fine */ });   // swallows the denial
```

Creating the role by hand (`/var/palm/ls2-dev/roles/pub/<appId>.json` with `outbound` to
`com.webos.applicationManager`) was **not** enough in our tests. Working alternative: read the
launch points once as root (`luna-send … listLaunchPoints`), bake a static catalog into the app,
and get the icons with `webos-tv.sh icons`. Deploy takes a minute, so this is fine.

Two symptoms to recognise it: the app shows only the hardcoded entries, and **the first tile
press after boot does nothing** (the second works). The second one is fixable in the app with a
delayed retry:

```js
launch(id);                       // the first one can be swallowed while WebAppMgr settles
setTimeout(() => launch(id), 700); // relaunching an app that is already foreground is a no-op
```

## Bonus: the debloat boot hook bakes bad arguments

`webos-debloat.sh --install-boot-hook` writes `--apply … --id A B C`, but the script only accepts
**one id per `--id`**, so at boot it dies with `unknown option: B` and the list is never
re-applied. Write the hook with one `--id` per app (`webos-tv.sh hook` does).
