# Incremental build stages. Fingerprint file names and contents so added,
# removed, or edited inputs invalidate a stage, even with preserved mtimes.
build_cache_directory="$project_root/build/.axiom-cache"
mkdir -p "$build_cache_directory"

hash_stream() {
	sha256sum | cut -d ' ' -f 1
}

hash_file_list() {
	LC_ALL=C sort -z | xargs -0 -r sha256sum -- | hash_stream
}

hash_paths() {
	local path
	for path in "$@"; do
		if [[ -d "$path" ]]; then
			find "$path" -type f -print0
		else
			printf '%s\0' "$path"
		fi
	done | hash_file_list
}

run_cached_stage() {
	local stage="$1" label="$2" inputs="$3"
	shift 3
	local outputs=()
	while [[ "$1" != -- ]]; do
		outputs+=("$1")
		shift
	done
	shift
	local stamp="$build_cache_directory/$stage" key previous="" output present=true
	key="$(printf '%s\0' "$inputs" "$@" | hash_stream)"
	for output in "${outputs[@]}"; do
		[[ -e "$output" ]] || present=false
	done
	if [[ -f "$stamp" ]]; then
		previous="$(cat "$stamp")"
	fi
	if [[ "${AXIOM_REBUILD:-0}" != 1 && "$present" == true \
		&& "$previous" == "$key $(hash_paths "${outputs[@]}")" ]]; then
		echo "[Axiom] $label is up to date."
		return
	fi
	echo "[Axiom] Building $label."
	"$@"
	# A failed command exits before the cache can claim its outputs succeeded.
	printf '%s %s\n' "$key" "$(hash_paths "${outputs[@]}")" > "$stamp.tmp"
	mv -f -- "$stamp.tmp" "$stamp"
}
