#!/usr/bin/env bats
# evidence.bats - the evidence ledger must be machine-readable and attributable:
# one JSON object per scrape, tagging scenario/node/run/step/svc so any flap can
# be traced to exactly which step, which node, which run produced it.

load load

@test "each scrape appends one well-formed, fully-attributed JSON event" {
	sandbox_init ev n1
	plan_iscsi_state 1
	run_scrape first iscsi >/dev/null
	run_scrape second iscsi >/dev/null

	f="$SB_EVID/events.ndjson"
	[ -s "$f" ]
	[ "$(wc -l < "$f")" -eq 2 ]

	n=0
	while IFS= read -r ln; do
		n=$((n + 1))
		[[ "$ln" == "{"*"}" ]]                         # object-shaped
		[[ "$ln" == *"\"scenario\":\"ev\""* ]]
		[[ "$ln" == *"\"node\":\"n1\""* ]]
		[[ "$ln" == *"\"svc\":\"iscsi\""* ]]
		[[ "$ln" == *"\"run\":$n,"* ]]                 # run increments 1,2,...
		[[ "$ln" == *"\"step\":"* ]]
		[[ "$ln" == *"\"verdict\":"* ]]
		[[ "$ln" == *"\"metric_value\":"* ]]
	done < "$f"
	[ "$n" -eq 2 ]
}

@test "events distinguish step labels and the empty-first vs settled verdicts" {
	sandbox_init ev n1
	plan_iscsi_state 1
	run_scrape first iscsi >/dev/null      # empty cache -> MISSING
	run_scrape second iscsi >/dev/null     # settled -> VALUE
	f="$SB_EVID/events.ndjson"
	grep -q '"run":1,"step":"first","svc":"iscsi"' "$f"
	grep -q '"run":2,"step":"second","svc":"iscsi"' "$f"
	grep -q '"step":"first".*"verdict":"MISSING"' "$f"
	grep -q '"step":"second".*"verdict":"VALUE"' "$f"
}

@test "events are valid JSON (python json.loads), when python3 is available" {
	# Probe that python3 can actually RUN, not just that the name resolves: on
	# Windows the `python3` on PATH is often a Microsoft Store app-execution stub
	# that prints nothing and exits non-zero. Skip cleanly in that case (the
	# structural checks above already validate the events without python).
	if ! python3 -c 'import json' >/dev/null 2>&1; then
		skip "python3 not available or non-functional (e.g. a Windows Store stub)"
	fi
	sandbox_init ev n1
	plan_nfs_state 1
	run_scrape only nfs >/dev/null
	f="$SB_EVID/events.ndjson"
	run python3 -c 'import json,sys
n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    json.loads(line); n+=1
assert n>=1, "no events"
print("ok",n)' "$f"
	[ "$status" -eq 0 ]
}
