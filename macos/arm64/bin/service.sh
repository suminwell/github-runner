#!/bin/sh
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python=$(cat "$root/.state/python")
exec "$python" "$root/bin/manager.py" "${1:-serve}" --root "$root"
