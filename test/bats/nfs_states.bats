#!/usr/bin/env bats
# nfs_states.bats - reproduce every documented NFS state code deterministically.
#  -3 no mount addr | -2 showmount times out | -1 df times out | 0 idle | 1 ready
# The -2/-1 cases rely on the production kill-loop terminating a fake that parks
# forever; the no-op sleep fake makes that loop fast-forward instantly.

load load

@test "nfs reports -3 when the export finds no mount address" {
	sandbox_init nfs_states n1
	plan_nfs_state -3
	v="$(warm_then_read nfs)"
	[ "$v" = "-3" ]
}

@test "nfs reports -2 when showmount hangs (export kills it and reports -2)" {
	sandbox_init nfs_states n1
	plan_nfs_state -2
	v="$(warm_then_read nfs)"
	[ "$v" = "-2" ]
}

@test "nfs reports -1 when df hangs (export kills it and reports -1)" {
	sandbox_init nfs_states n1
	plan_nfs_state -1
	v="$(warm_then_read nfs)"
	[ "$v" = "-1" ]
}

@test "nfs reports 0 when rpcinfo shows no ready/waiting program" {
	sandbox_init nfs_states n1
	plan_nfs_state 0
	v="$(warm_then_read nfs)"
	[ "$v" = "0" ]
}

@test "nfs reports 1 when rpcinfo shows the service ready" {
	sandbox_init nfs_states n1
	plan_nfs_state 1
	v="$(warm_then_read nfs)"
	[ "$v" = "1" ]
}
