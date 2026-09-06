#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
project_root="$PWD"
source "$project_root/tools/odin_env.sh"

./build.sh debug

box3d_link_directory="$project_root/build/box3d-link"
"$odin_command" build ./tools/debug -debug \
	-custom-attribute:axiom_system \
	-custom-attribute:axiom_system_config  \
	-collection:axiom="$project_root" \
	-define:BOX3D_SHARED=true \
	"-extra-linker-flags:-L${box3d_link_directory}" \
	-out:build/axiom-debug

echo "[Axiom] Debug executable: build/axiom-debug"
