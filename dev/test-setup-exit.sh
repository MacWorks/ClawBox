#!/bin/bash
set -eu

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PATH_FOR_NO_INSTALL="/usr/bin:/bin:/usr/sbin:/sbin"
output=''
status=0

set +e
output="$(cd "$BASE_DIR" && PATH="$PATH_FOR_NO_INSTALL" make setup 2>&1)"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  printf '%s\n' "Expected make setup to exit 0, got $status" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

case "$output" in
  *'Cannot install llama.cpp'*)
    ;;
  *)
    printf '%s\n' 'Expected output to contain: Cannot install llama.cpp' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

case "$output" in
  *'Error'*)
    printf '%s\n' 'Did not expect output to contain: Error' >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

printf '%s\n' 'setup exit behavior test passed'