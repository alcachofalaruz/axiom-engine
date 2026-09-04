odin_command="${ODIN_COMMAND:-}"
if [[ -z "$odin_command" ]]; then
	odin_command="$(command -v odin || true)"
fi
if [[ -z "$odin_command" && -n "${HOME:-}" && -x "$HOME/.local/bin/odin" ]]; then
	odin_command="$HOME/.local/bin/odin"
fi
if [[ -z "$odin_command" ]]; then
	echo "Axiom: Odin compiler not found. Set ODIN_COMMAND to its executable path." >&2
	exit 127
fi

odinfmt_command="${ODINFMT_COMMAND:-}"
if [[ -z "$odinfmt_command" ]]; then
	odinfmt_command="$(command -v odinfmt || true)"
fi
if [[ -z "$odinfmt_command" && -n "${HOME:-}" && -x "$HOME/.local/bin/odinfmt" ]]; then
	odinfmt_command="$HOME/.local/bin/odinfmt"
fi
if [[ -z "$odinfmt_command" ]]; then
	echo "Axiom: odinfmt not found. Set ODINFMT_COMMAND to its executable path." >&2
	exit 127
fi
