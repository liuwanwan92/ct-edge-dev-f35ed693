#!/usr/bin/env bats
# Scenario 3: repeated invocation -- the harness is idempotent, and it
# neutralizes the svc-check serve-stale non-idempotency.
load helpers

@test "harness: repeated runs give the same exit and leave no drift" {
	before="$(git -C "$REPO" status --porcelain | sort)"
	run bash "$SC/selfcheck.sh" --target conf/default
	rc1=$status
	run bash "$SC/selfcheck.sh" --target conf/default
	rc2=$status
	[ "$rc1" -eq "$rc2" ]
	after="$(git -C "$REPO" status --porcelain | sort)"
	[ "$before" = "$after" ]                       # no repo file drift
	! ls /tmp/nedge-prom-*-check.last >/dev/null 2>&1   # no /tmp cache residue
}

@test "svc-check raw path IS non-idempotent (serve-stale), harness path is stable" {
	export MOCK_ISCSI_STATE=ready
	svc_cache_clean
	o1="$(svc_http_once "$ISCSI")"
	sleep 1
	o2="$(svc_http_once "$ISCSI")"
	# first raw response has no metric body; the second serves the prior result
	run bash -c "printf '%s' \"$o1\" | grep -q 'nedge_iscsi_service_status{'"
	[ "$status" -ne 0 ]
	printf '%s' "$o2" | grep -q 'nedge_iscsi_service_status{'
	[ "$o1" != "$o2" ]
	# the harness driver (clears cache + settles) is stable across calls
	a="$(svc_check_status "$ISCSI" nedge_iscsi_service_status iscsisvc)"
	b="$(svc_check_status "$ISCSI" nedge_iscsi_service_status iscsisvc)"
	[ "$a" = "$b" ]
	[ "$a" = 1 ]
}
