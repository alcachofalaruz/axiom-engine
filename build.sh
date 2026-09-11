#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
project_root="$PWD"
source "$project_root/tools/odin_env.sh"

configuration="${1:-debug}"
target="${2:-libraries}"
case "$target" in
libraries|debug-app|all) ;;
*)
	echo "Axiom build: target must be libraries, debug-app, or all." >&2
	exit 2
	;;
esac
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

windows=false
executable_suffix=""
static_output=build/axiom.a
shared_output=build/axiom.so
shared_entry_options=(-no-entry-point)
collection_root="$project_root"
case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	windows=true
	executable_suffix=.exe
	# Keep the static library separate from the DLL's generated import library.
	static_output=build/axiom-static.lib
	shared_output=build/axiom.dll
	# A Windows DLL needs DllMain to initialize Odin and the C runtime.
	shared_entry_options=()
	collection_root="$(cygpath -m "$project_root")"
	;;
esac

# Shared by every engine target, including Neovim's RAD debug executable.
odin_options+=(-custom-attribute:axiom_system -custom-attribute:axiom_system_config "-collection:axiom=$collection_root")

# Odin includes the Windows Box3D .lib in its vendor package. The Linux
# bindings use the project's archive through the system-library search path.
if [[ "$windows" == false ]]; then
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
	odin_options+=(-define:BOX3D_SHARED=true "-extra-linker-flags:-L${box3d_link_directory}")
fi

mkdir -p build
source "$project_root/tools/build_cache.sh"
odin_root="$("$odin_command" root)"
odin_root="${odin_root//$'\r'/}"
if [[ "$windows" == true ]]; then
	odin_root="$(cygpath -u "$odin_root")"
fi
compiler_inputs="$(hash_paths "$(command -v "$odin_command")" "$odin_root/base" "$odin_root/core")"
build_inputs="$(hash_paths build.sh tools/odin_env.sh tools/build_cache.sh)"
metagen_inputs="$compiler_inputs $build_inputs $(hash_paths tools/metagen)"
metagen_output="build/axiom-metagen${executable_suffix}"

compile_target() {
	local stage="$1" label="$2" inputs="$3" output="$4"
	shift 4
	local outputs=("$output")
	if [[ "$windows" == true && "$configuration" == debug \
		&& ( "$output" == *.exe || "$output" == *.dll ) ]]; then
		outputs+=("${output%.*}.pdb")
	fi
	run_cached_stage "$stage" "$label" "$inputs" "${outputs[@]}" -- \
		"$odin_command" build "$@" "${odin_options[@]}" "-out:$output"
}

compile_target metagen "metagen" "$metagen_inputs" "$metagen_output" ./tools/metagen

generate_declarations() {
	"$metagen_output" src src engine
	if [[ -n "$odinfmt_command" ]]; then
		for generated_file in \
			src/generated_fixed_*.odin \
			src/generated_vector_*.odin \
			src/generated_component_*.odin \
			src/generated_state.odin
		do
			[[ -f "$generated_file" ]] || continue
			"$odinfmt_command" "-path:$generated_file" -w
		done
	fi
}

# Generated files are outputs, never generator inputs. Including them here
# would cause generation to invalidate itself on every invocation.
source_inputs="$(find src -type f \
	! -path 'src/generated.odin' ! -path 'src/generated_state.odin' \
	! -path 'src/generated_fixed_*.odin' ! -path 'src/generated_vector_*.odin' \
	! -path 'src/generated_component_*.odin' -print0 | hash_file_list)"
formatter_inputs="$odinfmt_command"
if [[ -n "$odinfmt_command" ]]; then
	formatter_inputs+=" $(hash_paths "$(command -v "$odinfmt_command")")"
fi
generation_inputs="$build_inputs $source_inputs $formatter_inputs $(hash_paths "$metagen_output")"
run_cached_stage generate "generated declarations" "$generation_inputs" src -- generate_declarations

engine_inputs="$compiler_inputs $build_inputs $(hash_paths src "$odin_root/vendor/box3d")"
if [[ "$windows" == false ]]; then
	engine_inputs+=" $(hash_paths "$box3d_library")"
fi

if [[ "$target" == libraries || "$target" == all ]]; then
	compile_target static "Odin static library" "$engine_inputs" "$static_output" \
		./src -build-mode:static -no-entry-point
	compile_target shared "Odin shared library" "$engine_inputs" "$shared_output" \
		./src -build-mode:shared "${shared_entry_options[@]}"

	echo "[Axiom] Build complete: $static_output, $shared_output"
fi

if [[ "$target" == debug-app || "$target" == all ]]; then
	debug_output="build/axiom-debug${executable_suffix}"
	debug_linker=()
	if [[ "$windows" == true ]]; then
		debug_linker=(-linker:radlink)
	fi
	debug_inputs="$engine_inputs $(hash_paths tools/debug)"
	compile_target debug-app "Odin debug executable" "$debug_inputs" "$debug_output" \
		./tools/debug "${debug_linker[@]}"
	echo "[Axiom] Debug executable: $debug_output"
fi
