#!/bin/sh
# tests/test-runtime.sh — RUNTIME integration tests.
#
# WHY THIS FILE EXISTS: every other test file asserts that the scripts GENERATE
# the right text. That passes happily while the appliance is unusable, because
# the third-party tools reject or misinterpret what we generated. Five real bugs
# shipped that way — all invisible to a text assertion, all obvious the moment
# the actual binary runs:
#
#   1. keyd v2.5 has no `control`/`alt`/`meta` key names. It rejects them, DROPS
#      that binding (a bad line does not abort the config) and starts anyway, so
#      every VM-switch hotkey was silently dead.
#   2. A viewer sent to a NAMED workspace ("1: OFFICE") is on a DIFFERENT
#      workspace from the one `workspace number 1` reaches, though both report
#      num=1 — VMs ran, viewers had mapped windows, and the operator got a black
#      screen they could not switch away from.
#   3. vmswitch located i3 with `pgrep -u <user> -x i3`, which busybox pgrep
#      never matches, so it could not reach i3's IPC socket and every hotkey did
#      nothing even once keyd fired.
#   4. Backticks in an UNQUOTED heredoc are command substitutions: nft comments
#      like `policy drop` ran as commands during `setup.sh 2`.
#   5. keyd cannot start without /dev/uinput, which nothing loaded.
#
# So this file runs the real thing: real keyd parsing the real generated config,
# and a real i3 under Xvfb, then asserts the operator-visible outcome (does the
# window end up where the switch key takes you?). Checks whose tool is missing
# are SKIPPED, never silently dropped.
#
# NOTE: tests/harness.sh prepends tests/stubs to PATH (fake i3-msg, virsh, ...).
# Generation needs those stubs; the runtime part must NOT have them, or it tests
# the stubs. REAL_PATH is captured before harness.sh and restored after.
set -u
REAL_PATH="$PATH"
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

echo "== runtime: generated configs against the real tools =="

# --- 4. no unescaped backticks inside unquoted heredocs (pure text, always runs)
# This is bug #4 and needs no runtime at all — it just was never checked.
python3 - "$REPO_ROOT" <<'PY' > /tmp/rt-backticks.out 2>&1
import re, sys, glob, os
root = sys.argv[1]
bad = []
files = sorted(glob.glob(os.path.join(root, 'src', '*.sh')))
files += [os.path.join(root, f) for f in ('setup.sh', 'configure.sh', 'flash.sh')]
for f in files:
    if not os.path.exists(f):
        continue
    lines = open(f, encoding='utf-8').read().split('\n')
    i = 0
    while i < len(lines):
        m = re.search(r'<<-?\s*(["\']?)([A-Za-z_][A-Za-z_0-9]*)\1', lines[i])
        if m:
            quoted, tag, start = bool(m.group(1)), m.group(2), i
            j = i + 1
            while j < len(lines) and lines[j].strip() != tag:
                j += 1
            if not quoted:
                for k in range(start + 1, min(j, len(lines))):
                    if re.search(r'(?<!\\)`', lines[k]):
                        bad.append("%s:%d: %s" % (os.path.basename(f), k + 1, lines[k].strip()[:70]))
            i = j
        i += 1
print('\n'.join(bad) if bad else 'CLEAN')
PY
assert_contains "no unescaped backticks inside an unquoted heredoc (they run as commands)" \
  /tmp/rt-backticks.out '^CLEAN$'

# --- generate the real artifacts (stubs on PATH: switching calls rc-service etc.)
new_sandbox
"$SANDBOX/src/host.sh" switching > "$SANDBOX/rt-switching.out" 2>&1
sw_rc=$?
assert_eq "switching.sh succeeds (generates i3 + keyd + vmswitch)" 0 "$sw_rc"

# From here on the REAL binaries must win over tests/stubs.
PATH="$REAL_PATH"; export PATH
KU=kiosk
KH="$(getent passwd "$KU" | cut -d: -f6)"; KH="${KH:-/home/$KU}"
I3CFG="$KH/.config/i3/config"
KEYD_CFG=/etc/keyd/default.conf

# --- 5. uinput is arranged for, or keyd grabs nothing ------------------------
assert_contains "switching loads uinput (keyd cannot start without it)" \
  "$REPO_ROOT/src/host.sh" 'modprobe uinput'

# --- 1. real keyd must accept EVERY generated binding -----------------------
# keyd prints "ERROR: line N: <tok> is not a valid key" and then starts anyway,
# so a text assertion on our own output can never catch a rejected chord — only
# keyd's own parser can. It parses before touching /dev/uinput, so this works
# even where keyd cannot actually start.
if command -v keyd >/dev/null 2>&1; then
  timeout 3 keyd > /tmp/rt-keyd.out 2>&1
  assert_contains "keyd parsed the generated config" /tmp/rt-keyd.out 'CONFIG: parsing'
  assert_not_contains "real keyd accepts every generated binding (no rejected chord)" \
    /tmp/rt-keyd.out 'is not a valid key'
  assert_not_contains "no keyd config ERROR at all" /tmp/rt-keyd.out 'ERROR'
  # And the modifiers must be the side-specific names keyd actually has.
  assert_contains "switch chords use keyd's real modifier names" "$KEYD_CFG" 'leftcontrol\+leftalt\+1'
else
  _skip "real keyd accepts every generated binding" "keyd not installed"
fi

# --- 2 + 3. real i3: does the switch key land on the VM? --------------------
if command -v i3 >/dev/null 2>&1 && command -v Xvfb >/dev/null 2>&1 \
   && command -v xterm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then

  # Stand in for virt-viewer with xterms carrying the same window titles, so no
  # libvirt/SPICE is needed to test PLACEMENT and SWITCHING.
  # -class virt-viewer: the generated for_window rules match on that WM_CLASS, so
  # the stand-in must present it or placement is never exercised.
  sed -i "s|exec --no-startup-id sh -c 'exec ~/vm-viewer.sh \(.*\)'|exec --no-startup-id xterm -class virt-viewer -T \1 -e sleep 900|" "$I3CFG"
  sed -i '/polybar/d' "$I3CFG"      # polybar is not part of this test
  chown -R "$KU:$KU" "$KH" 2>/dev/null || true

  Xvfb :98 -screen 0 1024x768x24 -ac > /tmp/rt-xvfb.log 2>&1 &
  RT_XVFB=$!
  sleep 2
  su "$KU" -s /bin/sh -c 'DISPLAY=:98 i3' > /tmp/rt-i3.log 2>&1 &
  sleep 5

  SOCK="$(ls -t /tmp/i3-"$KU".*/ipc-socket.* 2>/dev/null | head -1)"
  if [ -n "$SOCK" ]; then
    # every workspace's number + the window titles it holds
    tree_map() { i3-msg -s "$SOCK" -t get_tree 2>/dev/null | jq -c '[.. | objects | select(.type=="workspace") | {num, name, wins: [.. | objects | select(.window!=null) | .name]}]'; }
    focused_name() { i3-msg -s "$SOCK" -t get_workspaces 2>/dev/null | jq -r '.[]|select(.focused).name'; }

    tree_map > /tmp/rt-tree.json
    assert_contains "i3 came up and answers on its IPC socket" /tmp/rt-tree.json '"num"'

    # The regression itself: for each enabled env, `workspace number N` must land
    # on a workspace that CONTAINS that env's window. With a named workspace this
    # fails while every text assertion still passes.
    # env->workspace pairs exactly as the generated config declares them
    grep '^for_window .*move to workspace number' "$I3CFG" \
      | sed -E 's/.*title="\(\?i\)([a-z]+)".*number ([0-9]+).*/\1 \2/' > /tmp/rt-pairs
    # A vanishing assertion is as bad as a passing one: if the placement rules
    # change shape (e.g. back to a NAMED workspace) the per-env checks below would
    # silently stop running. Require one numbered rule per launched viewer.
    n_pairs="$(wc -l < /tmp/rt-pairs | tr -d ' ')"
    n_viewers="$(grep -c 'class virt-viewer -T' "$I3CFG" | tr -d ' ')"
    assert_eq "every launched viewer has a NUMBERED placement rule" "$n_viewers" "$n_pairs"
    while read -r env_name idx; do
      [ -n "${env_name:-}" ] || continue
      i3-msg -s "$SOCK" "workspace number $idx" >/dev/null 2>&1
      sleep 1
      f="$(focused_name)"
      if i3-msg -s "$SOCK" -t get_tree 2>/dev/null | jq -e --arg f "$f" --arg t "$env_name" \
           '.. | objects | select(.type=="workspace" and .name==$f) | [.. | objects | select(.window!=null) | .name] | index($t) != null' >/dev/null 2>&1; then
        _g "Ctrl+Alt+$idx target ('workspace number $idx') shows the $env_name viewer"
      else
        _b "Ctrl+Alt+$idx target ('workspace number $idx') shows the $env_name viewer"
        printf '        focused workspace: [%s]\n        tree: %s\n' "$f" "$(cat /tmp/rt-tree.json)"
      fi
    done < /tmp/rt-pairs

    # No orphan workspace that merely SHARES a number with a real one (that pair
    # — "1" empty + "1: OFFICE" holding the window — was the black screen).
    dupes="$(i3-msg -s "$SOCK" -t get_workspaces 2>/dev/null | jq -r '[.[].num] | group_by(.) | map(select(length>1)) | length')"
    assert_eq "no two workspaces share a number (named/numbered collision)" "0" "${dupes:-?}"

    # --- 3. vmswitch must find i3 and actually switch (busybox pgrep bug) ----
    # NOTE: invoked with DISPLAY/XAUTHORITY/I3SOCK UNSET, exactly as keyd invokes
    # it (as root, out of any X session). Handing it a DISPLAY would let it take a
    # shortcut the real hotkey never has, masking the discovery bug.
    if [ -x /usr/local/bin/vmswitch ]; then
      i3-msg -s "$SOCK" "workspace number 1" >/dev/null 2>&1; sleep 1
      env -u DISPLAY -u XAUTHORITY -u I3SOCK /usr/local/bin/vmswitch 2 >/dev/null 2>&1
      sleep 1
      assert_eq "vmswitch reaches the kiosk's i3 and switches (busybox pgrep regression)" \
        "2" "$(i3-msg -s "$SOCK" -t get_workspaces 2>/dev/null | jq -r '.[]|select(.focused).num')"
      # The appliance's pgrep is busybox and has been observed to match nothing for
      # `pgrep -u <user> -x i3`. vmswitch must therefore NOT depend on it: with
      # pgrep deliberately returning nothing it still has to find i3 (pidof, or
      # i3's /tmp/i3-<user>.*/ipc-socket.* glob) and switch. This is the assertion
      # that fails if someone reduces it back to pgrep-only.
      if [ -e /usr/bin/pgrep ]; then
        mv /usr/bin/pgrep /usr/bin/pgrep.rtbak
        printf '#!/bin/sh\nexit 1\n' > /usr/bin/pgrep; chmod +x /usr/bin/pgrep
        i3-msg -s "$SOCK" "workspace number 3" >/dev/null 2>&1; sleep 1
        env -u DISPLAY -u XAUTHORITY -u I3SOCK /usr/local/bin/vmswitch 1 >/dev/null 2>&1
        sleep 1
        assert_eq "vmswitch still reaches i3 when pgrep finds nothing (busybox)" \
          "1" "$(i3-msg -s "$SOCK" -t get_workspaces 2>/dev/null | jq -r '.[]|select(.focused).num')"
        mv /usr/bin/pgrep.rtbak /usr/bin/pgrep
      else
        _skip "vmswitch survives a pgrep that finds nothing" "no /usr/bin/pgrep to shadow"
      fi
      if [ -f /run/appliance/vmswitch.log ]; then
        assert_not_contains "vmswitch resolved the i3 socket (not sock=NONE)" \
          /run/appliance/vmswitch.log 'sock=NONE'
      else
        _skip "vmswitch breadcrumb" "no /run/appliance/vmswitch.log"
      fi
    else
      _skip "vmswitch switches workspaces" "/usr/local/bin/vmswitch missing"
    fi
  else
    _skip "i3 runtime placement + switching" "i3 IPC socket never appeared (see /tmp/rt-i3.log)"
  fi

  # tidy up so the rest of the suite is unaffected
  su "$KU" -s /bin/sh -c "DISPLAY=:98 i3-msg -s '$SOCK' exit" >/dev/null 2>&1 || true
  pkill -x i3 2>/dev/null || true
  pkill -f 'xterm -T' 2>/dev/null || true
  kill "$RT_XVFB" 2>/dev/null || true
else
  _skip "i3 runtime placement + switching" "need i3, Xvfb, xterm and jq"
fi

summary
