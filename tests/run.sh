#!/bin/sh
# =============================================================================
# tests/run.sh — run the appliance test suite.
# -----------------------------------------------------------------------------
# The scripts under test configure a Linux host: they load nftables rules, write
# to /etc, create users. So the suite runs inside a privileged Alpine container
# (the same distro the appliance itself is built on) where doing all of that for
# real is safe and disposable. On a Linux host with root you can also run the
# test files directly.
#
#   ./tests/run.sh              # everything, in Docker
#   ./tests/run.sh isolate      # just tests/test-isolate.sh
#   IN_CONTAINER=1 ./tests/run.sh   # already inside a suitable container
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.22}"

# Packages the suite itself needs: nftables to load the generated rulesets for
# real, xorriso to read back the cloud-init seed, python3+pyyaml to prove the
# generated user-data is valid YAML, qemu-img for the disk paths.
# i3wm/xvfb/xterm/jq/keyd are for tests/test-runtime.sh: it runs the REAL keyd
# parser and a REAL i3 against the generated configs, because text assertions
# cannot catch a chord keyd rejects or a workspace the switch key never reaches.
# KEEP THIS ON ONE LINE: it is interpolated into a `sh -c "apk add $DEPS && ..."`
# string, so an embedded newline would terminate the apk command early — the
# runtime deps silently would not install and the `adduser kiosk` after the &&
# would never run (which then fails switching.sh with exit 2).
DEPS="bash nftables xorriso qemu-img python3 py3-yaml shadow gnupg openssl coreutils util-linux i3wm xvfb xterm jq keyd"

if [ "${IN_CONTAINER:-0}" != "1" ]; then
  command -v docker >/dev/null 2>&1 || { echo "[x] Docker required (or run with IN_CONTAINER=1 on a Linux host)."; exit 1; }
  docker info >/dev/null 2>&1 || { echo "[x] Docker daemon not reachable."; exit 1; }
  echo "[*] Running the suite in a privileged Alpine ${ALPINE_BRANCH} container ..."
  exec docker run --rm --privileged --platform linux/amd64 \
    -e IN_CONTAINER=1 -e ALPINE_BRANCH="$ALPINE_BRANCH" \
    -v "$ROOT":/src -w /src \
    "alpine:${ALPINE_BRANCH#v}" \
    /bin/sh -c "apk add --no-cache $DEPS >/dev/null 2>&1 && adduser -D -s /bin/sh kiosk >/dev/null 2>&1; exec ./tests/run.sh ${*:-}"
fi

# ---- inside the container ---------------------------------------------------
[ "$(id -u)" = 0 ] || { echo "[x] The suite must run as root (it writes to /etc)."; exit 1; }

want="${1:-}"
rc=0
matched=0
for f in "$HERE"/test-*.sh; do
  name="$(basename "$f" .sh)"; name="${name#test-}"
  [ -z "$want" ] || [ "$want" = "$name" ] || continue
  matched=$((matched+1))
  echo
  echo "-------------------------------------------------------------------"
  sh "$f" || rc=1
done
# A selector that matches no file must not pass silently (a typo would look green).
if [ -n "$want" ] && [ "$matched" -eq 0 ]; then
  echo "[x] No test file matches '$want'." >&2
  exit 1
fi

echo
if [ "$rc" = 0 ]; then
  printf '\033[1;32m[+] All test files passed.\033[0m\n'
else
  printf '\033[1;31m[x] Some tests failed.\033[0m\n'
fi
exit "$rc"
