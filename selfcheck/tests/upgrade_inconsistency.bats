#!/usr/bin/env bats
# Scenario 4: upgrade before/after inconsistency (version skew + schema drift).
load helpers

@test "upgrade: matching versions pass" {
	# shellcheck source=/dev/null
	source "$FIX/versions/match.env"
	export SELFCHECK_LIVE=1
	run bash "$SC/checks/verify-upgrade" --target "$REPO/conf/default"
	[ "$status" -eq 0 ]
	[[ "$output" == *upgrade.version* ]]
	[[ "$output" != *FAIL\ id=upgrade.version* ]]
}

@test "upgrade: version skew -> FAIL" {
	# shellcheck source=/dev/null
	source "$FIX/versions/skew.env"
	export SELFCHECK_LIVE=1
	run bash "$SC/checks/verify-upgrade" --target "$REPO/conf/default"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL id=upgrade.version"* ]]
}

@test "upgrade: nesetup satisfies the target image schema (image-1.0)" {
	# shellcheck source=/dev/null
	source "$FIX/versions/match.env"
	export SELFCHECK_LIVE=1 SELFCHECK_SCHEMA_KEYS="$FIX/schema/image-1.0.keys"
	run bash "$SC/checks/verify-upgrade" --target "$REPO/conf/default"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS id=upgrade.schema"* ]]
}

@test "upgrade: schema drift under new image (image-2.0) -> FAIL" {
	# shellcheck source=/dev/null
	source "$FIX/versions/match.env"
	export SELFCHECK_LIVE=1 SELFCHECK_SCHEMA_KEYS="$FIX/schema/image-2.0.keys"
	run bash "$SC/checks/verify-upgrade" --target "$REPO/conf/default"
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL id=upgrade.schema"* ]]
	[[ "$output" == *replication_count* ]]
}
