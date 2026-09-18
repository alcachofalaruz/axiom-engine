#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

configuration="${1:-debug}"
case "$configuration" in
debug|release) ;;
*)
	echo "Axiom run: configuration must be debug or release." >&2
	exit 2
	;;
esac

./build.sh "$configuration" debug-app

executable=build/axiom-debug
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*) executable+=.exe ;;
esac

exec "$executable"
