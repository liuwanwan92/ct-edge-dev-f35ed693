#!/usr/bin/env bats
# cache_race.bats - the truncate-then-slow-refill race, made deterministic.
#
# The export runs as `( ...compute... ) > $cache`, which TRUNCATES the cache
# immediately and only refills it after the (slow) checks finish. A scrape that
# lands in that window reads a half-written file. We reproduce it exactly: a
# prior export leaves a valid cache; a new scrape's export is frozen at the very
# first command (mount) AFTER the truncation but BEFORE any value is written;
# while it is frozen we observe that the cache has no complete numeric metric
# line; we release it and confirm a subsequent scrape reads a valid value again.

load load

@test "nfs cache race: a scrape mid-export reads a half-written cache, then recovers" {
	sandbox_init race n1

	# a previously completed export left a valid, healthy cache
	seed_metric nfs 1 | seed_cache nfs
	lastf="$(last_cache_file nfs)"
	run grep -qE 'nedge_nfs_service_status\{[^}]*\} -?[0-9]+' "$lastf"
	[ "$status" -eq 0 ]                       # precondition: seeded value present

	# healthy plan, but make mount FREEZE on its first call (the new export) and
	# succeed on every later call (so the export can complete after release).
	plan_nfs_state 1
	fake_set_lines mount _ <<'EOF'
block=raceA cat=blob/mount_addr
cat=blob/mount_addr
EOF

	# launch the scrape in the background; its export will park inside mount with
	# the cache already truncated.
	scrape_bg trigger nfs
	run wait_for_file "$SB_FAKESTATE/entered/mount" 10
	[ "$status" -eq 0 ]                       # export is now parked mid-write

	# THE RACE: the cache exists but holds no complete numeric metric line.
	[ -f "$lastf" ]
	run grep -qE 'nedge_nfs_service_status\{[^}]*\} -?[0-9]+' "$lastf"
	[ "$status" -ne 0 ]                       # half-written: no value yet

	# release the export and let it finish writing the real value
	fake_release raceA
	scrape_join                               # MUST be a bare call (waits on a child)
	# the trigger scrape's BODY was the previous cache (the seeded healthy value)
	[ "$SCRAPE_BG_RESULT" = "1" ]

	# the cache is whole again and a fresh scrape reads a valid value
	run grep -qE 'nedge_nfs_service_status\{[^}]*\} -?[0-9]+' "$lastf"
	[ "$status" -eq 0 ]
	v="$(run_scrape recover nfs)"
	[ "$v" = "1" ]
}
