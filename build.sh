#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
project_root="$PWD"
source "$project_root/tools/odin_env.sh"

configuration="${1:-debug}"
case "$configuration" in
debug)
	box3d_configuration=Debug
	odin_options=(-debug)
	;;
release)
	box3d_configuration=Release
	odin_options=(-o:speed)
	;;
*)
	echo "Axiom build: configuration must be debug or release." >&2
	exit 2
	;;
esac

box3d_library=""
if [[ "$configuration" == "debug" ]]; then
	box3d_candidates=(
		"$project_root/lib/box3d/build/src/libbox3dd.a"
		"$project_root/build/box3d/src/libbox3dd.a"
	)
else
	box3d_candidates=(
		"$project_root/lib/box3d/build/src/libbox3d.a"
		"$project_root/build/box3d/src/libbox3d.a"
	)
fi

for candidate in "${box3d_candidates[@]}"
do
	if [[ -f "$candidate" ]]; then
		box3d_library="$candidate"
		break
	fi
done

if [[ -z "$box3d_library" ]]; then
	echo "[Axiom] Box3D library not found; building Box3D."
	cmake -S "$project_root/lib/box3d" -B "$project_root/build/box3d" \
		-DCMAKE_BUILD_TYPE="$box3d_configuration" \
		-DBUILD_SHARED_LIBS=OFF \
		-DBOX3D_SAMPLES=OFF \
		-DBOX3D_UNIT_TESTS=OFF \
		-DBOX3D_BENCHMARKS=OFF \
		-DBOX3D_DOCS=OFF \
		-DBOX3D_PROFILE=OFF
	cmake --build "$project_root/build/box3d" --target box3d --parallel
	if [[ "$configuration" == "debug" ]]; then
		box3d_library="$project_root/build/box3d/src/libbox3dd.a"
	else
		box3d_library="$project_root/build/box3d/src/libbox3d.a"
	fi
fi

mkdir -p build
box3d_link_directory="$project_root/build/box3d-link"
mkdir -p "$box3d_link_directory"
ln -sf "$box3d_library" "$box3d_link_directory/libbox3d.a"

echo "[Axiom] Generating Odin declarations."
"$odin_command" build ./tools/metagen "${odin_options[@]}" -out:build/axiom-metagen
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

echo "[Axiom] Building Odin static library."
"$odin_command" build ./src "${odin_options[@]}" \
	-build-mode:static \
	-no-entry-point \
	-custom-attribute:axiom_system \
	-define:BOX3D_SHARED=true \
	"-extra-linker-flags:-L${box3d_link_directory}" \
	-out:build/axiom.a

echo "[Axiom] Building Odin shared library."
"$odin_command" build ./src "${odin_options[@]}" \
	-build-mode:shared \
	-no-entry-point \
	-custom-attribute:axiom_system \
	-define:BOX3D_SHARED=true \
	"-extra-linker-flags:-L${box3d_link_directory}" \
	-out:build/axiom.so

echo "[Axiom] Build complete: build/axiom.a, build/axiom.so"
