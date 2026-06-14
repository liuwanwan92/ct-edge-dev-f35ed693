#!/usr/bin/env bats
# Scenario 2: monitoring target mismatch (+ render contract, SERVICES shapes).
load helpers

@test "monitoring: target matching the expected endpoint passes" {
	run bash "$SC/checks/check-monitoring" \
		--prometheus "$FIX/prometheus/good.yml" --targets-file "$FIX/targets/default.targets"
	[ "$status" -eq 0 ]
	[[ "$output" == *monitoring.target.ok* ]]
}

@test "monitoring: target disagreeing with expected -> FAIL" {
	run bash "$SC/checks/check-monitoring" \
		--prometheus "$FIX/prometheus/mismatch.yml" --targets-file "$FIX/targets/default.targets"
	[ "$status" -eq 1 ]
	[[ "$output" == *monitoring.target.mismatch* ]]
}

@test "monitoring: render contract rewrites the placeholder to MGMTIP:8881" {
	run bash "$SC/checks/check-monitoring" --prometheus "$FIX/prometheus/mismatch.yml"
	[[ "$output" == *monitoring.render.ok* ]]
}

@test "monitoring: svc-check SERVICES blocks are well-formed" {
	run bash "$SC/checks/check-monitoring" --prometheus "$FIX/prometheus/good.yml" --targets-file "$FIX/targets/default.targets"
	[[ "$output" == *monitoring.services.iscsi.ok* ]]
	[[ "$output" == *monitoring.services.nfs.ok* ]]
	[[ "$output" == *monitoring.services.s3.ok* ]]
}
