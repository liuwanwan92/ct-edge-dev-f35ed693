#!/usr/bin/env bash
# upgrade.bash - the POST-UPGRADE scenario.
#
# After an in-place upgrade the OLD version has already written a cache file
# with a (then-correct) healthy value, but the service is now restarting, so
# reality is degraded. Because the check emits the cached value first and only
# recomputes in the background, the FIRST scrape reports the stale healthy "1"
# (a false positive: it says OK while the service is actually down) and the
# value only catches up to reality on the SECOND scrape (one-scrape lag).
#
# This fixture seeds that stale cache and provides the per-phase plans for the
# real (current) service state; the bats test drives the order and asserts.
# Phases:
#   degraded   - the service is mid-restart / not yet serving
#   recovered  - the service is back to fully available
#
# Requires harness.bash + states.bash already sourced.

upgrade_setup() {        # <node>
	sandbox_init upgrade "${1:?upgrade_setup needs a node name}"
}

upgrade_seed_stale() {   # <svc> [value=1]   (stand-in for the previous version's .last)
	local svc="$1" val="${2:-1}"
	seed_metric "$svc" "$val" | seed_cache "$svc"
}

upgrade_phase() {        # <svc> <degraded|recovered>
	local svc="$1" phase="$2"
	case "$svc:$phase" in
		nfs:degraded)    plan_nfs_state -1 ;;   # mounted but server not answering
		nfs:recovered)   plan_nfs_state 1 ;;
		iscsi:degraded)  plan_iscsi_state -1 ;;
		iscsi:recovered) plan_iscsi_state 1 ;;
		s3:degraded)     plan_s3_state -1 ;;
		s3:recovered)    plan_s3_state 1 ;;
		*) echo "upgrade_phase: bad svc/phase '$svc:$phase'" >&2; return 2 ;;
	esac
}
