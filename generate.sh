#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
project_root="$PWD"
source "$project_root/tools/odin_env.sh"

mkdir -p build
"$odin_command" build ./tools/metagen -out:build/axiom-metagen
build/axiom-metagen src src
for generated_file in \
	src/generated_fixed_*.odin \
	src/generated_vector_*.odin \
	src/generated_component_*.odin \
	src/generated_state.odin
do
	[[ -f "$generated_file" ]] || continue
	"$odinfmt_command" "-path:$generated_file" -w
done
