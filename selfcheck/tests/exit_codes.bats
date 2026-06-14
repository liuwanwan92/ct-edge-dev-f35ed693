#!/usr/bin/env bats
# Core: three-state exit-code semantics, consistency across example dirs,
# --strict promotion, and the partial-not-ready oracle.
load helpers

@test "exit: a clean profile run exits 0 (data + gateway are consistent)" {
	run bash "$SC/selfcheck.sh" --target conf/default
	[ "$status" -eq 0 ]
	run bash "$SC/selfcheck.sh" --target conf/gateway
	[ "$status" -eq 0 ]
}

@test "exit: a FAIL yields 1" {
	run_config_fixture gateway-has-devices.json gateway
	[ "$status" -eq 1 ]
}

@test "exit: a SKIP_DEP yields 2, and --strict promotes it to 1" {
	export SELFCHECK_FORCE_JSON_BACKEND=none
	run bash "$SC/checks/check-config" --target "$REPO/conf/default"
	[ "$status" -eq 2 ]
	export SELFCHECK_STRICT=1
	run bash "$SC/checks/check-config" --target "$REPO/conf/default"
	[ "$status" -eq 1 ]
}

@test "exit: bad CLI args yield 3 (harness/usage error, not a check failure)" {
	run bash "$SC/selfcheck.sh" --frobnicate
	[ "$status" -eq 3 ]
	run bash "$SC/selfcheck.sh" --target conf/does-not-exist
	[ "$status" -eq 3 ]
}

@test "partial: a service that exists but is not serving -> FAIL (container running != serving)" {
	export SELFCHECK_LIVE=1
	run bash "$SC/checks/verify-partial" --target "$REPO/conf/default"
	[ "$status" -eq 0 ]                       # healthy mocks: all serving
	export MOCK_NEADM_PARTIAL=1
	run bash "$SC/checks/verify-partial" --target "$REPO/conf/default"
	[ "$status" -eq 1 ]
	[[ "$output" == *partial.notserving* ]]
}

@test "deploy: a process up but not serving is caught via the svc-check oracle" {
	export SELFCHECK_LIVE=1 SELFCHECK_PROTOCOLS=iscsi
	run bash "$SC/checks/verify-deploy" --target "$REPO/conf/default"
	[ "$status" -eq 0 ]
	export MOCK_ISCSI_STATE=nolun           # LUN not found -> svc-check status 0
	run bash "$SC/checks/verify-deploy" --target "$REPO/conf/default"
	[ "$status" -eq 1 ]
	[[ "$output" == *deploy.iscsi.serve* ]]
}
