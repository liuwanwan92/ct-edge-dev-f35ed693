#!/usr/bin/env bats
# upgrade_scenario.bats - the POST-UPGRADE false positive.
# The old version left a healthy cached value; the service is now degraded.
# Because the check emits the cached value first, the FIRST scrape reports the
# stale "healthy" value (a false positive that hides the outage) and the value
# only catches up to reality on the SECOND scrape (one-scrape lag).

load load

@test "nfs post-upgrade: stale cache reports 1 while reality is -1; lags one scrape" {
	upgrade_setup n1
	upgrade_seed_stale nfs 1
	upgrade_phase nfs degraded
	v1="$(run_scrape s1 nfs)"      # stale healthy value (false positive)
	v2="$(run_scrape s2 nfs)"      # reality, one scrape late
	[ "$v1" = "1" ]
	[ "$v2" = "-1" ]
}

@test "iscsi post-upgrade: stale 1 then real -1" {
	upgrade_setup n1
	upgrade_seed_stale iscsi 1
	upgrade_phase iscsi degraded
	v1="$(run_scrape s1 iscsi)"
	v2="$(run_scrape s2 iscsi)"
	[ "$v1" = "1" ]
	[ "$v2" = "-1" ]
}

@test "s3 post-upgrade: stale 1 then real -1" {
	upgrade_setup n1
	upgrade_seed_stale s3 1
	upgrade_phase s3 degraded
	v1="$(run_scrape s1 s3)"
	v2="$(run_scrape s2 s3)"
	[ "$v1" = "1" ]
	[ "$v2" = "-1" ]
}

@test "post-upgrade recovery is also lagged: real recovery shows one scrape late" {
	upgrade_setup n1
	upgrade_seed_stale nfs 1
	upgrade_phase nfs degraded
	a="$(run_scrape s1 nfs)"       # stale 1
	b="$(run_scrape s2 nfs)"       # real -1
	upgrade_phase nfs recovered    # service comes back
	c="$(run_scrape s3 nfs)"       # still shows the prior -1...
	d="$(run_scrape s4 nfs)"       # ...recovery visible only now
	[ "$a" = "1" ]
	[ "$b" = "-1" ]
	[ "$c" = "-1" ]
	[ "$d" = "1" ]
}
