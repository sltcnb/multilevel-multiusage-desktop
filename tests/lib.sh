#!/bin/sh
# tests/lib.sh — minimal assertion helpers shared by the test files.
# POSIX sh: the same shell Alpine's /bin/sh gives us, so the tests run in the
# image's own environment rather than a friendlier one.

PASS=0; FAIL=0
_g() { printf '\033[1;32m  ok  \033[0m %s\n' "$1"; PASS=$((PASS+1)); }
_b() { printf '\033[1;31m FAIL \033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# assert_contains <label> <haystack-file> <needle-regex>
assert_contains() {
  if grep -Eq -- "$3" "$2" 2>/dev/null; then _g "$1"; else
    _b "$1"; printf '        expected to match: %s\n        in: %s\n' "$3" "$2"; fi
}
# assert_not_contains <label> <haystack-file> <needle-regex>
assert_not_contains() {
  if grep -Eq -- "$3" "$2" 2>/dev/null; then
    _b "$1"; printf '        did NOT expect: %s\n        in: %s\n' "$3" "$2"
  else _g "$1"; fi
}
# assert_contains_fixed <label> <haystack-file> <literal>
# For needles that contain regex metacharacters (base64 secrets are full of + /).
assert_contains_fixed() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then _g "$1"; else
    _b "$1"; printf '        expected literal: %s\n        in: %s\n' "$3" "$2"; fi
}
# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _g "$1"; else
    _b "$1"; printf '        expected: [%s]\n        actual:   [%s]\n' "$2" "$3"; fi
}
# assert_ok <label> <command...>   — command must exit 0
assert_ok() {
  _l="$1"; shift
  if "$@" >/tmp/_ao.log 2>&1; then _g "$_l"; else
    _b "$_l"; sed 's/^/        /' /tmp/_ao.log; fi
}
# assert_fails <label> <command...> — command must exit non-zero
assert_fails() {
  _l="$1"; shift
  if "$@" >/tmp/_af.log 2>&1; then
    _b "$_l"; printf '        expected non-zero exit, got 0\n'; sed 's/^/        /' /tmp/_af.log
  else _g "$_l"; fi
}
# assert_mode <label> <expected-octal> <path>
assert_mode() {
  _m="$(stat -c '%a' "$3" 2>/dev/null || echo '?')"
  assert_eq "$1" "$2" "$_m"
}

summary() {
  printf '\n  %s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
