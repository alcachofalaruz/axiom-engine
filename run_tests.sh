#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
project_root="$PWD"
source "$project_root/tools/odin_env.sh"

configuration="debug"
if [[ $# -gt 0 && ( "$1" == "debug" || "$1" == "release" ) ]]; then
	configuration="$1"
	shift
fi

./build.sh "$configuration"

box3d_link_directory="$PWD/build/box3d-link"
if [[ ! -f "$box3d_link_directory/libbox3d.a" ]]; then
	echo "Axiom tests: Box3D library not found." >&2
	exit 1
fi

odin_options=()
if [[ "$configuration" == "debug" ]]; then
	odin_options=(-debug)
else
	odin_options=(-o:speed)
fi

"$odin_command" test ./src "${odin_options[@]}" \
	-custom-attribute:axiom_system \
	-define:BOX3D_SHARED=true \
	"-extra-linker-flags:-L${box3d_link_directory}" \
	"$@"
