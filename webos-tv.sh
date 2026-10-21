#!/bin/sh
# webos-tv — field tools for LG webOS TVs that are rooted but have NO Developer Mode.
#
# Everything here was learned the hard way on a 55QNED80SRA (webOS 25 / 10.3.2-33).
# See docs/PITFALLS.md before running anything: one wrong step there can delete
# /media/developer and with it every homebrew app on the TV.
#
# USAGE
#   ./webos-tv.sh doctor                 # is the TV healthy? what is installed/armed?
#   ./webos-tv.sh exec 'id'              # run a shell command on the TV as root
#   ./webos-tv.sh install ./pkg.tar.gz   # install/replace an app tree (no dev/install!)
#   ./webos-tv.sh boot                   # arm boot + home-reclaim SAM activities
#   ./webos-tv.sh boot list              # show them
#   ./webos-tv.sh boot remove            # disarm them
#   ./webos-tv.sh icons com.foo netflix  # pull real app icons off the TV into ./icons
#   ./webos-tv.sh fix                    # neutralize the unsigned boot script, restore the dev flag,
#                                        # and move inert init.d hooks out of the way
#   ./webos-tv.sh debloat                # re-apply the debloat list once, on demand
#   ./webos-tv.sh hook                   # init.d boot hook — ONLY for TVs where init.d actually runs
#
# CONFIG (all overridable by env, nothing is hardcoded)
#   TV_IP     the TV's LAN address                    (required)
#   MAC_IP    this computer's LAN address, reachable from the TV (required)
#   SLOPBRO   slopbro checkout holding <TV_IP>.key    (default /tmp/slopbro)
#   APP_ID    app id for `install`                    (default tld.my.customhome)
#   PORT      local HTTP port for the task channel    (default 8099)
#
# WHY THE ROOT CHANNEL IS SLOPBRO: this firmware has no sshd, so there is no
# ares/Dev-Mode target and no shell. slopbro's payload runs a script as root on the
# TV; we hand it work through a tiny HTTP channel. Never commit the client key.
set -eu

TV_IP=${TV_IP:-}
MAC_IP=${MAC_IP:-}
SLOPBRO=${SLOPBRO:-/tmp/slopbro}
APP_ID=${APP_ID:-tld.my.customhome}
PORT=${PORT:-8099}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
SRV_PID=

port_open () { # $1 host, $2 port -> prints open|closed
	python3 - "$1" "$2" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(2)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print("open")
except Exception:
    print("closed")
finally:
    s.close()
PY
}

say () { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn () { printf 'WARN: %s\n' "$*" >&2; }
die () { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup () { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true; [ -n "$SRV_PID" ] && wait "$SRV_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

require_tv () {
	[ -n "$TV_IP" ] || die "set TV_IP to the TV's LAN address (see ./webos-tv.sh help)"
	[ -n "$MAC_IP" ] || die "set MAC_IP to this computer's LAN address, reachable from the TV"
}

require_channel () {
	[ -d "$SLOPBRO" ] || die "slopbro not found at $SLOPBRO (git clone https://github.com/throwaway96/slopbro)"
	[ -f "$SLOPBRO/$TV_IP.key" ] || die "no client key at $SLOPBRO/$TV_IP.key — run slopbro once by hand and accept the pairing prompt on the TV"
	command -v python3 >/dev/null || die "python3 is required"
}

# Run $WORK/task.sh on the TV as root and print whatever it wrote to stdout/stderr.
run_task () {
	require_channel
	[ -f "$WORK/task.sh" ] || die "no task to run"
	[ -d "$WORK/serve" ] || server_init
	cp "$WORK/task.sh" "$WORK/serve/task.sh"
	( cd "$WORK/serve" && exec python3 "$WORK/server.py" "$PORT" ) &
	SRV_PID=$!
	sleep 1
	cat > "$SLOPBRO/wwwroot/autoroot.sh" <<PAYLOAD
#!/bin/sh
for i in 1 2 3 4 5; do
	curl -sf -o /tmp/wt-task.sh http://$MAC_IP:$PORT/task.sh && break
	sleep 2
done
sh /tmp/wt-task.sh > /tmp/wt-out 2>&1
curl -s --data-binary @/tmp/wt-out http://$MAC_IP:$PORT/result >/dev/null 2>&1
PAYLOAD
	( cd "$SLOPBRO" && python3 slopbro.py --local-ip "$MAC_IP" --webos-version 11 "$TV_IP" >/dev/null 2>&1 ) \
		|| warn "slopbro reported a problem (the task may still have run)"
	# wait for the result to land (the payload posts it when it is done)
	i=0
	while [ ! -s "$WORK/result" ] && [ $i -lt 90 ]; do sleep 1; i=$((i + 1)); done
	kill "$SRV_PID" 2>/dev/null || true
	wait "$SRV_PID" 2>/dev/null || true
	SRV_PID=
	[ -s "$WORK/result" ] && cat "$WORK/result" || warn "no output came back from the TV"
}

server_init () {
	mkdir -p "$WORK/serve"
	cp "$HERE/scripts/task-server.py" "$WORK/server.py"
}

# ---------------------------------------------------------------- doctor
cmd_doctor () {
	say "network"
	for p in 3000 3001 7000; do
		printf '   %s %s\n' "$p" "$(port_open "$TV_IP" "$p")"
	done
	ssap=$(port_open "$TV_IP" 3001)
	airplay=$(port_open "$TV_IP" 7000)
	if [ "$ssap" = closed ] && [ "$airplay" = closed ]; then
		printf '\n   TV unreachable: awake and on the same LAN?\n' >&2
		exit 1
	fi
	if [ "$ssap" = closed ] && [ "$airplay" = open ]; then
		printf '\n   AirPlay answers but SSAP does not -> SAM is wedged: UNPLUG the TV for 10s.\n' >&2
		exit 1
	fi

	say "on the TV"
	cat > "$WORK/task.sh" <<'TASK'
#!/bin/sh
echo "uptime: $(cut -d' ' -f1 /proc/uptime)s   date: $(date '+%Y-%m-%d %H:%M %Z')"
year=$(date +%Y)
[ "$year" -lt 2025 ] && echo "!! clock looks reset (no NTP client on this firmware) — fix it client-side or with: date -s '...'"
echo "devmode_enabled: $([ -d /var/luna/preferences/devmode_enabled ] && echo present || echo MISSING)"
echo "/media/developer: $([ -d /media/developer ] && echo present || echo MISSING)"
echo "apps: $(ls /media/developer/apps/usr/palm/applications 2>/dev/null | tr '\n' ' ')"
echo "services: $(ls /media/developer/apps/usr/palm/services 2>/dev/null | tr '\n' ' ')"
echo "signed start-devmode.sh present: $([ -f /media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service/start-devmode.sh ] && echo 'YES — LG will wipe /media/developer unless it verifies' || echo no)"
echo "init.d hooks: $(ls /var/lib/webosbrew/init.d 2>/dev/null | tr '\n' ' ')"
echo "-- persistent activities:"
luna-send -n 1 luna://com.webos.service.activitymanager/list '{"details":true,"subscribers":true,"current":true,"internal":true}' 2>/dev/null \
	| tr '{' '\n' | grep -o '"name":"[^"]*"' | grep -Ei 'boot|home|reclaim|custom|brew' | sort -u
TASK
	run_task
}

# ---------------------------------------------------------------- exec
cmd_exec () {
	[ $# -ge 1 ] || die "usage: $0 exec '<shell command>'"
	printf '#!/bin/sh\n%s\n' "$*" > "$WORK/task.sh"
	run_task
}

# ---------------------------------------------------------------- install
cmd_install () {
	[ $# -ge 1 ] || die "usage: $0 install <pkg.tar.gz>   (tree must contain usr/palm/applications/<APP_ID>)"
	PKG=$1
	[ -f "$PKG" ] || die "no such file: $PKG"
	cp "$PKG" "$WORK/serve/pkg.tar.gz"
	say "installing $APP_ID from $PKG"
	# NOTE: deliberately NOT luna://com.webos.appInstallService/dev/install — it hangs SAM
	# and takes SSAP down with it. This is the path that works: untar + rescan.
	cat > "$WORK/task.sh" <<TASK
#!/bin/sh
mkdir -p /media/developer/apps
cd /media/developer/apps || exit 1
curl -sf -o /tmp/wt-pkg.tar.gz http://$MAC_IP:$PORT/pkg.tar.gz || { echo "download failed"; exit 1; }
tar xz < /tmp/wt-pkg.tar.gz || { echo "untar failed"; exit 1; }
ls-control scan-volatile-dirs >/dev/null 2>&1
luna-send -n 1 luna://com.webos.applicationManager/closeByAppId '{"id":"$APP_ID"}' >/dev/null 2>&1
sleep 1
luna-send -n 1 luna://com.webos.applicationManager/launch '{"id":"$APP_ID"}' >/dev/null 2>&1
echo "installed $(ls -d /media/developer/apps/usr/palm/applications/$APP_ID 2>/dev/null || echo MISSING)"
TASK
	run_task
}

# ---------------------------------------------------------------- boot
ACT_BOOT=${APP_ID}.boot
ACT_RECLAIM=${APP_ID}.reclaim
ACT_FOCUS=${APP_ID}.closehome
LG_HOME=com.webos.app.home

cmd_boot () {
	case ${1:-install} in
	install)
		say "arming persistent SAM activities for $APP_ID"
		# WHY: init.d is unusable here (see docs/PITFALLS.md #1). A persistent activity is
		# SAM's own scheduler: it survives reboots, needs no root at boot, and is reversible.
		cat > "$WORK/task.sh" <<TASK
#!/bin/sh
luna-send -n 1 -f luna://com.webos.service.activitymanager/create '{
 "activity":{"name":"$ACT_BOOT","description":"Launch $APP_ID at boot",
  "type":{"foreground":true,"persist":true,"continuous":true},
  "trigger":{"method":"luna://com.webos.bootManager/getBootStatus","params":{"subscribe":true},
   "where":{"prop":["signals","core-boot-done"],"op":"=","val":true}},
  "callback":{"method":"luna://com.webos.applicationManager/launch","params":{"id":"$APP_ID"}}},
 "replace":true,"start":true}' >/dev/null 2>&1
luna-send -n 1 -f luna://com.webos.service.activitymanager/create '{
 "activity":{"name":"$ACT_RECLAIM","description":"Reclaim the screen when LG Home appears",
  "type":{"foreground":true,"persist":true,"continuous":true},
  "trigger":{"method":"luna://com.webos.applicationManager/getForegroundAppInfo","params":{"subscribe":true},
   "where":{"prop":["appId"],"op":"=","val":"$LG_HOME"}},
  "callback":{"method":"luna://com.webos.applicationManager/launch","params":{"id":"$APP_ID"}}},
 "replace":true,"start":true}' >/dev/null 2>&1
luna-send -n 1 -f luna://com.webos.service.activitymanager/create '{
 "activity":{"name":"$ACT_FOCUS","description":"Close the LG Home window so the remote focus returns",
  "type":{"foreground":true,"persist":true,"continuous":true},
  "trigger":{"method":"luna://com.webos.applicationManager/getForegroundAppInfo","params":{"subscribe":true},
   "where":{"prop":["appId"],"op":"=","val":"$LG_HOME"}},
  "callback":{"method":"luna://com.webos.applicationManager/closeByAppId","params":{"id":"$LG_HOME"}}},
 "replace":true,"start":true}' >/dev/null 2>&1
echo "armed: $ACT_BOOT $ACT_RECLAIM $ACT_FOCUS"
TASK
		run_task
		;;
	list)
		cmd_exec "luna-send -n 1 luna://com.webos.service.activitymanager/list '{\"details\":true,\"subscribers\":true,\"current\":true,\"internal\":true}' | tr '{' '\\n' | grep -o '\"name\":\"[^\"]*\"' | sort -u"
		;;
	remove)
		say "removing the activities"
		for a in "$ACT_BOOT" "$ACT_RECLAIM" "$ACT_FOCUS"; do
			cmd_exec "luna-send -n 1 luna://com.webos.service.activitymanager/cancel '{\"activityName\":\"$a\"}'"
		done
		;;
	*) die "usage: $0 boot [install|list|remove]" ;;
	esac
}

# ---------------------------------------------------------------- icons
cmd_icons () {
	[ $# -ge 1 ] || die "usage: $0 icons <app-id> [app-id...]"
	IDS="$*"
	say "pulling icons for: $IDS"
	cat > "$WORK/task.sh" <<TASK
#!/bin/sh
BASES="/usr/palm/applications /media/cryptofs/apps/usr/palm/applications /mnt/otncabi/usr/palm/applications /media/developer/apps/usr/palm/applications"
for id in $IDS; do
	for b in \$BASES; do
		f="\$b/\$id/appinfo.json"
		[ -f "\$f" ] || continue
		icon=\$(sed -n 's/.*"icon"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "\$f" | head -1)
		[ -n "\$icon" ] || continue
		case "\$icon" in /*) p="\$icon";; *) p="\$b/\$id/\$icon";; esac
		[ -f "\$p" ] && base64 "\$p" | tr -d '\n' | sed "s|^|\$id |"
		break
	done
done
TASK
	run_task > "$WORK/icons.raw"
	mkdir -p "$HERE/icons"
	while read -r id b64; do
		[ -n "$id" ] || continue
		printf '%s' "$b64" | base64 -d > "$HERE/icons/$(echo "$id" | tr '.' '_').png" 2>/dev/null \
			&& printf '   %s -> icons/%s.png\n' "$id" "$(echo "$id" | tr '.' '_')"
	done < "$WORK/icons.raw"
}

# ---------------------------------------------------------------- hook
cmd_hook () {
	say "checking the init.d boot path"
	# THE TRAP: on a host named LGwebOSTV, /etc/init/devmode.conf signature-verifies
	# start-devmode.sh; an unsigned copy there makes LG delete devmode_enabled and then
	# wipe /media/developer. Refuse to create that file, and neutralize one if it exists.
	cat > "$WORK/task.sh" <<'TASK'
#!/bin/sh
D=/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service
S=$D/start-devmode.sh
if [ -f "$S" ]; then
	echo "!! $S exists. LG verifies its signature; if it fails, the next boot DELETES /media/developer."
	echo "!! moving it aside (reversible)."
	mv "$S" "$S.disabled.bak" && echo "   moved to $S.disabled.bak"
fi
[ -d /var/luna/preferences/devmode_enabled ] || { mkdir -p /var/luna/preferences/devmode_enabled && echo "devmode_enabled recreated"; }
mkdir -p /var/lib/webosbrew/init.d 2>/dev/null
if [ -d /var/lib/webosbrew/init.d ]; then
	cat > /var/lib/webosbrew/init.d/50-debloat <<'HOOK'
#!/bin/sh
# webos-debloat, corrected: ONE --id per app. Upstream's --install-boot-hook bakes them
# all after a single --id and the script dies with "unknown option" at boot.
S=/var/lib/webos-debloat/webos-debloat.sh
sleep 5
[ -x "$S" ] && "$S" --apply --only ad,sdk,demo,remote >>/var/lib/webos-debloat/boot.log 2>&1
[ -x "$S" ] && "$S" --preload-sync >>/var/lib/webos-debloat/boot.log 2>&1
exit 0
HOOK
	chmod 0755 /var/lib/webosbrew/init.d/50-debloat
	echo "wrote /var/lib/webosbrew/init.d/50-debloat (add your own --id lines there)"
else
	echo "!! IMPORTANT: init.d only runs from the SIGNATURE-VERIFIED start-devmode.sh."
	echo "!! Without Developer Mode that chain never starts, so this hook will never execute."
	echo "!! Use 'debloat' to apply the list now; use 'boot' for persistence that works."
fi
TASK
	run_task
}

# ---------------------------------------------------------------- fix
# Repairs what the pitfalls leave behind. Idempotent and reversible.
cmd_fix () {
	say "repairing the dev-mode state and clearing dead boot hooks"
	cat > "$WORK/task.sh" <<'TASK'
#!/bin/sh
D=/media/cryptofs/apps/usr/palm/services/com.palmdts.devmode.service
S=$D/start-devmode.sh
if [ -f "$S" ]; then
	echo "!! $S exists: LG signature-verifies it, and a failed check makes the NEXT boot delete /media/developer."
	echo "   moving it aside (reversible)."
	mv "$S" "$S.disabled.bak" && echo "   -> $S.disabled.bak"
fi
if [ ! -d /var/luna/preferences/devmode_enabled ]; then
	mkdir -p /var/luna/preferences/devmode_enabled && echo "   devmode_enabled recreated"
fi
# init.d is only executed from that signature-verified script, so on a TV without
# Developer Mode these hooks never run: they are inert and only mislead whoever reads them.
for h in /var/lib/webosbrew/init.d/50-debloat /var/lib/webosbrew/init.d/50-customhome; do
	if [ -e "$h" ]; then mv "$h" "$h.inert.bak" && echo "   inert hook moved aside: $h"; fi
done
echo "--- init.d now:"; ls -A /var/lib/webosbrew/init.d 2>/dev/null
TASK
	run_task
}

# ---------------------------------------------------------------- debloat
# Re-applies the debloat list ONCE. The list is a durable JSON file, but the app manager
# can drop entries on its own (we watched it lose one), so re-apply whenever it drifts —
# this does not need a boot hook, and on a TV without Developer Mode a boot hook never runs.
cmd_debloat () {
	say "re-applying the debloat list"
	cat > "$WORK/task.sh" <<'TASK'
#!/bin/sh
S=/var/lib/webos-debloat/webos-debloat.sh
[ -x "$S" ] || { echo "!! $S missing - install webos-debloat first"; exit 1; }
"$S" --apply --only ad,sdk,demo,remote
echo "--- hidden entries now: $(grep -o 'com\.[A-Za-z0-9._-]*' /var/preferences/com.webos.applicationManager/blockedSystemAppList/*.json 2>/dev/null | wc -l)"
TASK
	run_task
}

# ---------------------------------------------------------------- main
CMD=${1:-help}
[ $# -gt 0 ] && shift

case "$CMD" in
	help|-h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
require_tv

case "$CMD" in
	doctor) cmd_doctor ;;
	exec) cmd_exec "$@" ;;
	install) server_init; cmd_install "$@" ;;
	icons) cmd_icons "$@" ;;
	boot) cmd_boot "$@" ;;
	fix) cmd_fix ;;
	debloat) cmd_debloat ;;
	hook) cmd_hook ;;
	*)
		printf 'unknown command: %s\n\n' "$CMD" >&2
		sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2
		exit 2
		;;
esac
