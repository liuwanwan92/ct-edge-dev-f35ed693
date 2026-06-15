#!/usr/bin/env bats
# iscsi_states.bats - reproduce every documented iSCSI state code.
#  -1 target not discoverable | 0 discoverable but LUN absent | 1 LUN present

load load

@test "iscsi reports -1 when discovery fails" {
	sandbox_init iscsi_states n1
	plan_iscsi_state -1
	v="$(warm_then_read iscsi)"
	[ "$v" = "-1" ]
}

@test "iscsi reports 0 when discoverable but the configured LUN is absent" {
	sandbox_init iscsi_states n1
	plan_iscsi_state 0
	v="$(warm_then_read iscsi)"
	[ "$v" = "0" ]
}

@test "iscsi reports 1 when the configured LUN is present" {
	sandbox_init iscsi_states n1
	plan_iscsi_state 1
	v="$(warm_then_read iscsi)"
	[ "$v" = "1" ]
}
