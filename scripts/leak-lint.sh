#!/usr/bin/env bash
# Every IPv4 address written down in this repository has to come from a range
# reserved for documentation or for private networks. Nothing else may be here.
#
# An allowlist rather than a list of forbidden strings, for the reason
# sapn95/container-commander's ADR 0011 gives: a denylist is itself a list of
# the things you are hiding, it has to be updated by the person who is about to
# leak something new, and it fails open on everything nobody thought of. This
# one contains no secrets by construction and fails closed.
#
# Names are not checkable the same way — a VPN profile named after an employer
# looks like any other word — so that rule is written in the README and checked
# by reading. This catches the class a machine can catch.
set -euo pipefail

readonly ALLOWED='^(0\.0\.0\.0$|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|255\.255\.255\.255$|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|22[4-9]\.|23[0-9]\.)'

cd "$(dirname "${BASH_SOURCE[0]}")/.."

found=0
while IFS=: read -r file line address; do
  [ -n "${address:-}" ] || continue
  if ! printf '%s' "${address}" | grep -qE "${ALLOWED}"; then
    printf '%s:%s: %s is neither a documentation nor a private address\n' "${file}" "${line}" "${address}" >&2
    found=1
  fi
done < <(git ls-files -z | xargs -0 grep -HonE '[0-9]{1,3}(\.[0-9]{1,3}){3}' -- 2>/dev/null || true)

if [ "${found}" -ne 0 ]; then
  echo >&2
  echo "Use 192.0.2.x, 198.51.100.x or 203.0.113.x instead — they exist for this." >&2
  exit 1
fi
echo "every address written down here is a documentation or private one"
