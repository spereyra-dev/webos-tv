# Findings worth sending upstream

Concrete behaviour observed on real hardware, not opinions.

## throwaway96/slopbro — the ACL wall is app-specific

> Ran slopbro against an LG 55QNED80SRA (webOS 25 / `10.3.2-33`, firmware `33.31.75`).
>
> - `com.webos.app.adoverlayex` (default), `adoverlay`, `dangbei-overlay`: the launch returns true
>   but the WebView never requests the page.
> - `com.webos.app.tinybrowser`: loads `index.html`, then the payload dies with
>   `Denied method call "download" for category "/"`. `--fake-service-path` and
>   `--no-fake-service-path` make no difference — the denial is per-app ACL, not about the fake path.
> - **`com.webos.app.voiceweb` works** (the vector this repo forces for webOS 11, via
>   `--webos-version 11`): all four tracked files are served and root is obtained.
>
> So on this firmware the useful signal is "which app context has `download`", and `voiceweb` has it.
> Suggest allowing `voiceweb` for major 10 too, or noting in the README that forcing the version is
> the workaround.

## webosbrew/webos-homebrew-channel — the copy path in `startup.sh` does not apply

`services/startup.sh` tells you to copy it "over to suitable path (eg. `start-devmode.sh`)". On a
host named `LGwebOSTV` that file is signature-checked, so the instruction only holds on emulators:

`/etc/init/devmode.conf` runs `openssl dgst -sha512 -verify` on it against
`/usr/palm/services/com.palm.service.devmode/pub.pem`. No `.sig` ships with a hand-made copy, so the
check fails, `devmode_enabled` is removed, and the later branch of the same script runs
`rm -rf /media/developer` for "non developer mode". The unverified `elif` branch that would run the
script without a signature applies only to non-`LGwebOSTV` hosts.

Boot persistence on these TVs is the persistent SAM activity (`./webos-tv.sh boot`); `init.d` is
never reached without that signed script.

## gprot42/webos-launch-home — an alternative that needs no HBC

> Your watcher/boot hooks need HBC elevated. On a TV with no Developer Mode and no HBC we got the
> same result with SAM's own scheduler — a persistent activity, no root at boot:
>
> ```
> trigger: luna://com.webos.bootManager/getBootStatus, subscribe,
>          where {prop:["signals","core-boot-done"], op:"=", val:true}
> callback: luna://com.webos.applicationManager/launch {id: <app>}
> ```
> Plus two more triggered by `getForegroundAppInfo == com.webos.app.home`: one relaunching the app
> and one calling `closeByAppId` on LG's Home — without the close, the remote focus stays on LG's
> invisible Home window and the user has to press HOME by hand.
>
> Implementation: https://github.com/<you>/webos-tv (`webos-tv.sh boot`).

## webos-debloat gist — `--install-boot-hook` bakes invalid arguments

> `--install-boot-hook` writes `webos-debloat.sh --apply --only a,b,c --id X Y Z`, but the script
> takes one id per `--id` (`EXTRA_IDS="$EXTRA_IDS ${1:-}"`), so at boot it dies with
> `ERROR: unknown option: Y` and the list is never re-applied. Fix: emit one `--id` per app:
> `--id X --id Y --id Z`.
