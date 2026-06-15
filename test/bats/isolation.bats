#!/usr/bin/env bats
# isolation.bats - proves install and upgrade scenarios do not contaminate each
# other (互不串味), and pins the mechanism they would otherwise share.
#
# Production hardcodes ONE cache path (/tmp/nedge-prom-<svc>-check.last) that is
# shared across every scenario, node and run - so a value left by one bleeds
# into the next. The harness keys the cache on (scenario,node), so they cannot.

load load

@test "production checks share a single hardcoded /tmp cache across all scenarios" {
	for svc in nfs iscsi s3; do
		run grep -E "/tmp/nedge-prom-${svc}-check\.last" "$(prod_check_path "$svc")"
		[ "$status" -eq 0 ]
	done
}

@test "install n1 and upgrade n1 use different cache files; upgrade does not inherit install's value" {
	install_setup n1
	install_phase nfs ready
	run_scrape s1 nfs >/dev/null          # leaves install/n1 cache = 1
	install_last="$(last_cache_file nfs)"
	[ -s "$install_last" ]

	upgrade_setup n1                       # same node name, different scenario
	upgrade_last="$(last_cache_file nfs)"
	[ "$install_last" != "$upgrade_last" ] # distinct paths
	[ ! -e "$upgrade_last" ]               # starts empty - no bleed-through

	v="$(run_scrape s1 nfs)"               # first upgrade scrape sees no prior value
	[ "$v" = "MISSING" ]
}

@test "the same node across scenarios is fully separated for every service" {
	install_setup n1
	p_install_nfs="$(last_cache_file nfs)"
	p_install_iscsi="$(last_cache_file iscsi)"
	upgrade_setup n1
	p_upgrade_nfs="$(last_cache_file nfs)"
	p_upgrade_iscsi="$(last_cache_file iscsi)"
	[ "$p_install_nfs" != "$p_upgrade_nfs" ]
	[ "$p_install_iscsi" != "$p_upgrade_iscsi" ]
}

@test "a shared cache carries a stale value forward - the contamination isolation prevents" {
	# This is the exact mechanism that, under the shared /tmp, leaks across
	# scenarios: a value already in the cache is reported before recompute.
	sandbox_init shared n1
	seed_metric nfs 1 | seed_cache nfs     # a prior occupant left a healthy value
	plan_nfs_state -1                       # reality is now degraded
	v="$(run_scrape s1 nfs)"               # the stale value is still reported
	[ "$v" = "1" ]
}
