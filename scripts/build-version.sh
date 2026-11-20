#!/usr/bin/env bash
# Print the version stamp for a build: the short sha of HEAD, with "-dirty"
# appended only when the build input differs from it.
#
# `git describe --dirty` is not used: it compares against a stale index, so a
# file that was merely touched (a formatter, a checkout, a rebase) reads as
# modified and stamped a clean tree "-dirty" — the live build said
# "cd86289-dirty" for that reason. Refresh the index first, and count what the
# compiler can see: tracked changes and untracked Go files. Untracked scratch
# files (logs, build output) do not change the binary.

set -uo pipefail

sha=$(git rev-parse --short HEAD 2>/dev/null) || { echo dev; exit 0; }

git update-index -q --refresh >/dev/null 2>&1 || true
if ! git diff-index --quiet HEAD -- 2>/dev/null \
  || [[ -n $(git ls-files --others --exclude-standard -- '*.go' 2>/dev/null) ]]; then
  sha="$sha-dirty"
fi

echo "$sha"
