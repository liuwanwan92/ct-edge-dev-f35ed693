#!/usr/bin/env bats
# guard_instrumentation.bats - the drift guard. Proves the instrumented copy the
# harness runs differs from the untouched production check by EXACTLY the cache
# path and nothing else. If someone edits a production check (or the transform
# regresses), these fail loudly - which is what lets us promise "production logic
# is never modified by the tests".

load load

@test "production checks still hardcode a shared /tmp cache path (transform precondition)" {
	for svc in nfs iscsi s3; do
		run grep -E "/tmp/nedge-prom-${svc}-check\.last" "$(prod_check_path "$svc")"
		[ "$status" -eq 0 ]
	done
}

@test "nfs: instrumented copy differs from production only by the cache path" {
	dst="$BATS_TEST_TMPDIR/nfs-check"
	instrument_check nfs "$dst"
	run assert_only_cache_path_changed "$(prod_check_path nfs)" "$dst"
	[ "$status" -eq 0 ]
}

@test "iscsi: instrumented copy differs from production only by the cache path" {
	dst="$BATS_TEST_TMPDIR/iscsi-check"
	instrument_check iscsi "$dst"
	run assert_only_cache_path_changed "$(prod_check_path iscsi)" "$dst"
	[ "$status" -eq 0 ]
}

@test "s3: instrumented copy differs from production only by the cache path" {
	dst="$BATS_TEST_TMPDIR/s3-check"
	instrument_check s3 "$dst"
	run assert_only_cache_path_changed "$(prod_check_path s3)" "$dst"
	[ "$status" -eq 0 ]
}

@test "instrumented copies contain no literal /tmp cache path and reference NEDGE_CHECK_STATE_DIR" {
	for svc in nfs iscsi s3; do
		dst="$BATS_TEST_TMPDIR/$svc-check2"
		instrument_check "$svc" "$dst"
		run grep -E "/tmp/nedge-prom-${svc}-check\.last" "$dst"
		[ "$status" -ne 0 ]                       # absent
		run grep -q 'NEDGE_CHECK_STATE_DIR' "$dst"
		[ "$status" -eq 0 ]                       # present
	done
}
