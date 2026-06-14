#!/usr/bin/env bash
#
# selfcheck/lib/discover.sh
#
# Enumerate the example configuration profiles. A profile is any immediate
# subdirectory of the conf root that contains a nesetup.json. No profile list is
# hardcoded, so adding conf/<new>/nesetup.json is picked up automatically.

if [ -n "${_SC_DISCOVER_LOADED:-}" ]; then return 0 2>/dev/null || true; fi
_SC_DISCOVER_LOADED=1

# sc_discover_profiles [conf-root]  -> one profile name per line (sorted)
sc_discover_profiles() {
	local root="${1:-conf}" d
	[ -d "$root" ] || return 1
	for d in "$root"/*/; do
		[ -f "${d}nesetup.json" ] && basename "$d"
	done
}

# sc_profile_path <conf-root> <name>  -> path to that profile's nesetup.json
sc_profile_path() { printf '%s/%s/nesetup.json\n' "$1" "$2"; }
