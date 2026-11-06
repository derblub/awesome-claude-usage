#!/bin/sh
# generate.sh - regenerate the README screenshots from invented usage data.
#
#   docs/screenshots/generate.sh [--only ultra,max,warning,apikey]
#
# Starts a private Xvfb on display :97 (never the real display), runs AwesomeWM with rc.lua
# against fake data from fixtures.lua, and captures the pictures with ImageMagick's `import`.
# The widget reads only the work directory: HOME, XDG_* and every source path point there, curl is
# replaced by fake-curl.sh, and no session bus is passed on (env -i), so nothing reaches the real notification daemon.
# Needs: Xvfb, awesome, import (ImageMagick), lua5.4. Everything it starts is
# stopped again on exit.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$(dirname "$HERE")")
DOCS="$REPO/docs"
DISPLAY_NUM=97
SIZE=900x930
BAR_W=705
BAR_H=30
ONLY=${2:-ultra,max,warning,apikey}
[ "${1:-}" = "--only" ] || ONLY=ultra,max,warning,apikey

for tool in Xvfb awesome import lua5.4; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; exit 1; }
done
if [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]; then
	echo "display :$DISPLAY_NUM is already in use; stop it first" >&2
	exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-shots.XXXXXX")
XVFB_PID=
AWESOME_PID=

cleanup() {
	[ -n "$AWESOME_PID" ] && kill "$AWESOME_PID" 2>/dev/null
	[ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
	wait 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK/home" "$WORK/run" "$DOCS/variants"
chmod 700 "$WORK/run"

Xvfb ":$DISPLAY_NUM" -screen 0 "${SIZE}x24" -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
n=0
until [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]; do
	n=$((n + 1))
	[ "$n" -gt 50 ] && { echo "Xvfb did not start" >&2; exit 1; }
	sleep 0.1
done

# run_scenario <scenario> <popup 0|1>; leaves the awesome process running for the captures.
start_scenario() {
	rm -rf "$WORK/data"
	mkdir -p "$WORK/data/lua"
	# The widget loads as require("claude_usage") from the data directory.
	ln -s "$REPO" "$WORK/data/lua/claude_usage"
	lua5.4 "$HERE/fixtures.lua" "$1" "$WORK/data" || return 1
	cp "$HERE/fake-curl.sh" "$HERE/rc.lua" "$WORK/data/"
	env -i PATH="$PATH" HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/run" XDG_CACHE_HOME="$WORK/home/.cache" \
		XDG_CONFIG_HOME="$WORK/home/.config" DISPLAY=":$DISPLAY_NUM" LANG=C.UTF-8 TZ=UTC \
		CU_SHOT_DIR="$WORK/data" CU_SHOT_SCENARIO="$1" CU_SHOT_POPUP="$2" \
		awesome --no-argb -c "$WORK/data/rc.lua" >"$WORK/awesome.log" 2>&1 &
	AWESOME_PID=$!
	n=0
	until [ -e "$WORK/data/ready" ]; do
		n=$((n + 1))
		if [ "$n" -gt 400 ]; then
			echo "scenario $1: awesome never got ready" >&2
			tail -20 "$WORK/awesome.log" >&2
			return 1
		fi
		sleep 0.1
	done
}

stop_scenario() {
	kill "$AWESOME_PID" 2>/dev/null
	wait "$AWESOME_PID" 2>/dev/null
	AWESOME_PID=
}

shot() { # shot <kind> <output relative to docs/>
	name=$2
	out="$DOCS/$name"
	case "$1" in
	hero)
		# The popup, 24 px of margin above it, and the bar below it.
		set -- $(sed -n 's/^popup=//p' "$WORK/data/ready")
		top=$(($2 - 24))
		DISPLAY=":$DISPLAY_NUM" import -window root -crop "${BAR_W}x$((${SIZE#*x} - top))+0+$top" +repage "$out"
		;;
	bar) DISPLAY=":$DISPLAY_NUM" import -window root -crop "${BAR_W}x${BAR_H}+0+$((${SIZE#*x} - BAR_H))" +repage "$out" ;;
	popup)
		set -- $(sed -n 's/^popup=//p' "$WORK/data/ready")
		DISPLAY=":$DISPLAY_NUM" import -window root -crop "$3x$4+$1+$2" +repage "$out"
		;;
	esac
	echo "wrote docs/$name"
}

want() { case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }

status=0
if want ultra; then
	start_scenario ultra 1 || status=1
	if [ $status = 0 ]; then
		shot hero hero.png
		shot popup popup.png
		shot bar screenshot.png
	fi
	stop_scenario
fi
if want max; then
	start_scenario max 1 || status=1
	if [ $status = 0 ]; then
		shot bar variants/bar-max.png
		shot popup variants/popup-max.png
	fi
	stop_scenario
fi
if want warning; then
	start_scenario warning 0 || status=1
	[ $status = 0 ] && shot bar variants/bar-warning.png
	stop_scenario
fi
if want apikey; then
	start_scenario apikey 0 || status=1
	[ $status = 0 ] && shot bar variants/bar-api-key.png
	stop_scenario
fi
exit $status
