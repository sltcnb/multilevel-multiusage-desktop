#!/bin/sh
# tests/test-isolate.sh — environments/isolate.sh, the layer the whole project
# rests on. The generated ruleset is loaded into a REAL kernel nftables (the
# container runs privileged), so a rule that nft would reject cannot pass here.
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/harness.sh"

echo "== environments/isolate.sh =="
new_sandbox
NFT_OUT=/etc/nftables.d/appliance-isolation.nft

run_isolate() { "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/isolate.out" 2>&1; }

# --- happy path: all three envs reachable outward, blocked from each other ----
nft flush ruleset 2>/dev/null || true
run_isolate
rc_all_reach=$?
cp "$NFT_OUT" "$SANDBOX/ruleset.nft"

assert_ok "generated ruleset loads into a real kernel nftables" nft -f "$SANDBOX/ruleset.nft"

# Every ordered pair of the three environments, both directions, by subnet.
for pair in "10.10.1.0/24 10.10.2.0/24" "10.10.1.0/24 10.10.3.0/24" \
            "10.10.2.0/24 10.10.1.0/24" "10.10.2.0/24 10.10.3.0/24" \
            "10.10.3.0/24 10.10.1.0/24" "10.10.3.0/24 10.10.2.0/24"; do
  set -- $pair
  assert_contains "subnet DROP $1 -> $2" "$SANDBOX/ruleset.nft" "ip saddr $1 ip daddr $2 counter drop"
done
# ...and the independent bridge-name layer for the same pairs.
assert_contains "bridge DROP virbr1 -> virbr2" "$SANDBOX/ruleset.nft" 'iifname "virbr1" oifname "virbr2" counter drop'
assert_contains "bridge DROP virbr3 -> virbr1" "$SANDBOX/ruleset.nft" 'iifname "virbr3" oifname "virbr1" counter drop'

# Ordering matters: a conntrack fast-path above the drops would keep waving
# through any cross-env flow that was already established.
drop_line="$(grep -n 'ip saddr 10.10.1.0/24 ip daddr 10.10.2.0/24' "$SANDBOX/ruleset.nft" | head -1 | cut -d: -f1)"
ct_line="$(grep -n 'ct state established,related accept' "$SANDBOX/ruleset.nft" | head -1 | cut -d: -f1)"
if [ "$drop_line" -lt "$ct_line" ]; then
  _g "inter-env DROP rules precede the established/related accept"
else
  _b "inter-env DROP rules precede the established/related accept (drop@$drop_line ct@$ct_line)"
fi

# NAT and egress for enabled envs.
assert_contains "masquerade out the detected WAN iface" "$SANDBOX/ruleset.nft" 'ip saddr 10.10.1.0/24 oifname "wlan0" masquerade'
assert_contains "mode=all gives unrestricted egress" "$SANDBOX/ruleset.nft" 'ip saddr 10.10.2.0/24 oifname "wlan0" accept'
assert_eq "isolate.sh exits 0 when every check passes" 0 "$rc_all_reach"
assert_contains "reports the internet-reachability PASS" "$SANDBOX/isolate.out" 'reaches internet.*PASS'
assert_contains "reports the cross-env block PASS" "$SANDBOX/isolate.out" 'cannot reach development net.*PASS'

# --- a real breach must fail the run -----------------------------------------
# STUB_PEER_RC=0 means an in-guest ping to a PEER environment succeeded, i.e.
# the environments can reach each other. That is a breach and must produce a
# non-zero exit, not a warning that scrolls past in a first-boot log.
new_sandbox
nft flush ruleset 2>/dev/null || true
STUB_PEER_RC=0 "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/breach.out" 2>&1
breach_rc=$?
assert_contains "a reachable peer env is reported as FAIL" "$SANDBOX/breach.out" 'cannot reach .* net -> FAIL'
if [ "$breach_rc" -ne 0 ]; then
  _g "isolate.sh exits non-zero when isolation is breached"
else
  _b "isolate.sh exits non-zero when isolation is breached (got $breach_rc)"
fi

# --- guest agent not up yet: skipped, not failed -----------------------------
new_sandbox
nft flush ruleset 2>/dev/null || true
STUB_AGENT=down "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/agentdown.out" 2>&1
agent_rc=$?
assert_contains "an unreachable guest agent is SKIPPED" "$SANDBOX/agentdown.out" 'SKIPPED \(guest agent not ready\)'
assert_eq "skips alone do not fail the run" 0 "$agent_rc"

# --- a guest command that never finishes must not silently pass --------------
new_sandbox
nft flush ruleset 2>/dev/null || true
GUEST_EXEC_TIMEOUT=2 STUB_AGENT=slow "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/slow.out" 2>&1
assert_contains "a never-completing in-guest command times out explicitly" \
  "$SANDBOX/slow.out" 'did not finish in 2s'

# --- whitelist egress ---------------------------------------------------------
new_sandbox
cfg_set administration_EGRESS_MODE whitelist
cfg_set administration_EGRESS_ALLOW "1.1.1.1 9.9.9.9"
nft flush ruleset 2>/dev/null || true
STUB_AGENT=down "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/wl.out" 2>&1
cp "$NFT_OUT" "$SANDBOX/wl.nft"
assert_ok "whitelist ruleset loads into the kernel" nft -f "$SANDBOX/wl.nft"
assert_contains "whitelist permits the listed destinations" "$SANDBOX/wl.nft" 'ip daddr \{ 1.1.1.1,9.9.9.9 \} accept'
assert_contains "whitelist permits DNS to its own gateway" "$SANDBOX/wl.nft" 'ip saddr 10.10.3.0/24 ip daddr 10.10.3.1 udp dport 53 accept'
assert_contains "whitelist drops everything else" "$SANDBOX/wl.nft" 'ip saddr 10.10.3.0/24 counter drop'
assert_contains "whitelist still allows its own wg tunnel" "$SANDBOX/wl.nft" 'ip saddr 10.10.3.0/24 oifname "wg3" accept'
assert_not_contains "a whitelisted env gets no blanket WAN accept" "$SANDBOX/wl.nft" 'ip saddr 10.10.3.0/24 oifname "wlan0" accept'

# --- fail closed on a misleading config --------------------------------------
new_sandbox
cfg_set administration_EGRESS_ALLOW "1.1.1.1"   # allow-list set, mode left "all"
assert_fails "an allow-list with EGRESS_MODE=all is refused, not silently ignored" \
  "$SANDBOX/src/environments.sh" isolate

# --- a DISABLED env keeps its fence, but loses its internet ------------------
new_sandbox
cfg_set development_ENABLED 0
nft flush ruleset 2>/dev/null || true
STUB_AGENT=down "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/dis.out" 2>&1
cp "$NFT_OUT" "$SANDBOX/dis.nft"
assert_contains "a disabled env stays fenced off from the others" "$SANDBOX/dis.nft" 'ip saddr 10.10.1.0/24 ip daddr 10.10.2.0/24 counter drop'
assert_contains "a disabled env stays fenced in the other direction too" "$SANDBOX/dis.nft" 'ip saddr 10.10.2.0/24 ip daddr 10.10.1.0/24 counter drop'
assert_not_contains "a disabled env gets no NAT" "$SANDBOX/dis.nft" 'ip saddr 10.10.2.0/24 oifname "wlan0" masquerade'
assert_not_contains "a disabled env gets no egress accept" "$SANDBOX/dis.nft" 'ip saddr 10.10.2.0/24 oifname "wlan0" accept'
# Indices must not shift when an env is disabled.
assert_contains "administration keeps subnet .3 when env 2 is disabled" "$SANDBOX/dis.nft" 'ip saddr 10.10.3.0/24 oifname "wlan0" masquerade'

# --- a fourth environment scales without renumbering -------------------------
new_sandbox
cfg_set ENVS "office development administration research"
cfg_set research_ENABLED 1
cfg_set research_OS arch
nft flush ruleset 2>/dev/null || true
STUB_AGENT=down "$SANDBOX/src/environments.sh" isolate > "$SANDBOX/four.out" 2>&1
cp "$NFT_OUT" "$SANDBOX/four.nft"
assert_ok "four-env ruleset loads into the kernel" nft -f "$SANDBOX/four.nft"
assert_eq "all 12 ordered subnet pairs are dropped for 4 envs" \
  12 "$(grep -c 'ip saddr 10\.10\..\.0/24 ip daddr 10\.10\..\.0/24 counter drop' "$SANDBOX/four.nft")"
assert_contains "the new env gets subnet .4" "$SANDBOX/four.nft" 'ip saddr 10.10.4.0/24 oifname "wlan0" masquerade'

nft flush ruleset 2>/dev/null || true
summary
