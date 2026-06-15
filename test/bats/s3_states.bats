#!/usr/bin/env bats
# s3_states.bats - reproduce every documented S3 state code.
#  -2 endpoint unreachable | -1 bucket forbidden | 0 bucket ok, object fails | 1 object ok
# Driven by the three sequential curl HEAD probes (object/bucket/plain), each
# selected independently by the curl fake's call-site classifier.

load load

@test "s3 reports -2 when nothing responds (endpoint unreachable)" {
	sandbox_init s3_states n1
	plan_s3_state -2
	v="$(warm_then_read s3)"
	[ "$v" = "-2" ]
}

@test "s3 reports -1 when the plain bucket HEAD is forbidden" {
	sandbox_init s3_states n1
	plan_s3_state -1
	v="$(warm_then_read s3)"
	[ "$v" = "-1" ]
}

@test "s3 reports 0 when the authed bucket HEAD succeeds but the object HEAD fails" {
	sandbox_init s3_states n1
	plan_s3_state 0
	v="$(warm_then_read s3)"
	[ "$v" = "0" ]
}

@test "s3 reports 1 when the authed object HEAD succeeds" {
	sandbox_init s3_states n1
	plan_s3_state 1
	v="$(warm_then_read s3)"
	[ "$v" = "1" ]
}
