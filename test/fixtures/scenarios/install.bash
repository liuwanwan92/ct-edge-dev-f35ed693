#!/usr/bin/env bash
# install.bash - the POST-INSTALL scenario.
#
# On a freshly installed node the cache file /tmp/nedge-prom-<svc>-check.last
# does not exist yet, so the FIRST /metrics scrape emits no metric value and
# only the SECOND scrape "recovers" - even though the service itself is healthy.
# That empty-first-scrape is the headline post-install false positive.
#
# This fixture only sets up the SANDBOX (empty cache) and the per-phase plans;
# the bats test drives the scrape order and makes the assertions. Phases:
#   cold   - the service has not finished coming up yet
#   ready  - the service is fully available
#
# Requires harness.bash + states.bash already sourced.

install_setup() {    # <node>
	# sandbox_init wipes and recreates an EMPTY state dir, which is exactly the
	# clean-machine condition: no prior .last for any service.
	sandbox_init install "${1:?install_setup needs a node name}"
}

install_phase() {    # <svc> <cold|ready>
	local svc="$1" phase="$2"
	case "$svc:$phase" in
		nfs:cold)    plan_nfs_state -3 ;;   # not mounted yet
		nfs:ready)   plan_nfs_state 1 ;;
		iscsi:cold)  plan_iscsi_state -1 ;; # target not discoverable yet
		iscsi:ready) plan_iscsi_state 1 ;;
		s3:cold)     plan_s3_state -2 ;;    # endpoint not reachable yet
		s3:ready)    plan_s3_state 1 ;;
		*) echo "install_phase: bad svc/phase '$svc:$phase'" >&2; return 2 ;;
	esac
}
