#!/usr/bin/env bats
# install_scenario.bats - the POST-INSTALL false positive.
# On a freshly installed node the cache file does not exist yet, so the FIRST
# /metrics scrape emits no value (MISSING) even though the service is healthy,
# and only the SECOND scrape "recovers" the real value. This is the
# "1st fails, 2nd recovers" symptom, reproduced deterministically.

load load

@test "nfs post-install: first scrape MISSING though service is up; second recovers to 1" {
	install_setup n1
	install_phase nfs ready
	v1="$(run_scrape s1 nfs)"
	v2="$(run_scrape s2 nfs)"
	[ "$v1" = "MISSING" ]
	[ "$v2" = "1" ]
}

@test "iscsi post-install: first scrape MISSING; second recovers to 1" {
	install_setup n1
	install_phase iscsi ready
	v1="$(run_scrape s1 iscsi)"
	v2="$(run_scrape s2 iscsi)"
	[ "$v1" = "MISSING" ]
	[ "$v2" = "1" ]
}

@test "s3 post-install: first scrape MISSING; second recovers to 1" {
	install_setup n1
	install_phase s3 ready
	v1="$(run_scrape s1 s3)"
	v2="$(run_scrape s2 s3)"
	[ "$v1" = "MISSING" ]
	[ "$v2" = "1" ]
}

@test "post-install cold->ready: a cold first scrape settles to healthy by the third" {
	install_setup n1
	install_phase nfs cold
	v1="$(run_scrape cold nfs)"      # cache empty -> MISSING (and exports the cold -3)
	v2="$(run_scrape cold2 nfs)"     # reads the cold value
	install_phase nfs ready          # service finished coming up
	v3="$(run_scrape ready nfs)"     # still reads the prior (cold) export...
	v4="$(run_scrape ready2 nfs)"    # ...and only now reflects healthy
	[ "$v1" = "MISSING" ]
	[ "$v2" = "-3" ]
	[ "$v3" = "-3" ]
	[ "$v4" = "1" ]
}

@test "post-install evidence is ordered and attributable (run increments, node/svc tagged)" {
	install_setup n1
	install_phase iscsi ready
	run_scrape s1 iscsi >/dev/null
	run_scrape s2 iscsi >/dev/null
	f="$SB_EVID/events.ndjson"
	[ "$(wc -l < "$f")" -eq 2 ]
	grep -q '"run":1,"step":"s1","svc":"iscsi"' "$f"
	grep -q '"run":2,"step":"s2","svc":"iscsi"' "$f"
	grep -q '"node":"n1"' "$f"
}
