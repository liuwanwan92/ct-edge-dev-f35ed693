#!/usr/bin/env bats
# Scenario 1: config missing items.
load helpers

@test "config: every shipped profile passes" {
	for p in default single-node gateway high-performance large-object-throughput; do
		run bash "$SC/checks/check-config" --target "$REPO/conf/$p"
		[ "$status" -eq 0 ] || { echo "profile $p -> $status: $output"; false; }
		[[ "$output" == *config.ok* ]]
	done
}

@test "config: gateway declaring disks -> FAIL" {
	run_config_fixture gateway-has-devices.json gateway
	[ "$status" -eq 1 ]
	[[ "$output" == *config.gateway.devices* ]]
}

@test "config: data profile with empty devices -> FAIL" {
	run_config_fixture data-empty-devices.json default
	[ "$status" -eq 1 ]
	[[ "$output" == *config.devices.empty* ]]
}

@test "config: device entry missing 'device' key -> FAIL" {
	run_config_fixture device-missing-device.json default
	[ "$status" -eq 1 ]
	[[ "$output" == *config.devices.keys* ]]
}

@test "config: high-performance without journal -> FAIL" {
	run_config_fixture hp-missing-journal.json high-performance
	[ "$status" -eq 1 ]
	[[ "$output" == *config.hp.journal* ]]
}

@test "config: large-object-throughput without sync -> FAIL" {
	run_config_fixture lot-missing-sync.json large-object-throughput
	[ "$status" -eq 1 ]
	[[ "$output" == *config.lot.tuning* ]]
}

@test "config: single-node with failure_domain!=0 -> FAIL" {
	run_config_fixture single-node-fd1.json single-node
	[ "$status" -eq 1 ]
	[[ "$output" == *config.single_node.fd* ]]
}

@test "config: empty transport -> FAIL" {
	run_config_fixture empty-transport.json default
	[ "$status" -eq 1 ]
	[[ "$output" == *config.transport* ]]
}

@test "config: bad is_aggregator -> FAIL" {
	run_config_fixture bad-is-aggregator.json default
	[ "$status" -eq 1 ]
	[[ "$output" == *config.is_aggregator* ]]
}

@test "config: no JSON backend -> SKIP_DEP (exit 2); --strict promotes to FAIL (exit 1)" {
	export SELFCHECK_FORCE_JSON_BACKEND=none
	run bash "$SC/checks/check-config" --target "$REPO/conf/default"
	[ "$status" -eq 2 ]
	[[ "$output" == *SKIP_DEP* ]]
	export SELFCHECK_STRICT=1
	run bash "$SC/checks/check-config" --target "$REPO/conf/default"
	[ "$status" -eq 1 ]
}
