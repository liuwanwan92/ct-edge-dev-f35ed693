#!/usr/bin/env bash
# states.bash - the single source of truth for driving each production svc-check
# to a specific reported state code, by writing the fake-command plans for the
# current sandbox. Reused by the *_states bats (which assert each state in
# isolation) AND by the install/upgrade scenario fixtures (which sequence these
# states into a lifecycle). "How do I make nfs report -2" is defined exactly
# once, here, so the meaning of every state stays consistent across the suite.
#
# Requires: harness.bash already sourced and sandbox_init already called
# (uses fake_set / fake_blob / last_cache_file against the current SB_*).
#
# Blocking states (-2 / -1 for nfs) park a fake on a FIFO that is NEVER released
# by the test: the production kill-loop (`for i in 1..19; ps -p $PID && sleep 1`)
# fast-forwards over the no-op `sleep` fake, finds the fake still alive, and
# takes its own kill/timeout branch in milliseconds. That is the whole point -
# the timeout branch is driven deterministically without any real waiting and
# without the harness having to time a release.

# ---- NFS: -3 (no addr) / -2 (showmount hang) / -1 (df hang) / 0 (idle) / 1 ----

_nfs_blob_addr() {   # realistic mount table: both services mounted, addr present
	fake_blob mount_addr <<'EOF'
srv:/e1 on /mnt/nfssvc1 type nfs (rw,addr=10.16.110.10)
srv:/e2 on /mnt/nfssvc2 type nfs (rw,addr=10.16.110.10)
EOF
}

_nfs_blob_noaddr() { # a mount table that does NOT match either nfs path -> -3
	fake_blob mount_noaddr <<'EOF'
tmpfs on /run type tmpfs (rw,nosuid,nodev)
/dev/sda1 on / type ext4 (rw,relatime)
EOF
}

plan_nfs_state() {   # <-3|-2|-1|0|1>
	case "$1" in
		-3)
			_nfs_blob_noaddr
			fake_set mount _ "cat=blob/mount_noaddr"
			;;
		-2)
			_nfs_blob_addr
			fake_set mount _ "cat=blob/mount_addr"
			# showmount never returns -> prod kill-loop -9's it -> -2
			fake_set showmount _ "block=nfs_sm_hang"
			;;
		-1)
			_nfs_blob_addr
			fake_set mount _ "cat=blob/mount_addr"
			fake_set showmount _ "rc=0"
			# df never returns -> prod kill-loop SIGTERM's it -> -1
			fake_set df _ "block=nfs_df_hang"
			;;
		0)
			_nfs_blob_addr
			fake_set mount _ "cat=blob/mount_addr"
			fake_set showmount _ "rc=0"
			fake_set df _ "rc=0"
			# rpcinfo output has no ready|waiting -> 0
			fake_set rpcinfo _ "echo=idle"
			;;
		1)
			_nfs_blob_addr
			fake_set mount _ "cat=blob/mount_addr"
			fake_set showmount _ "rc=0"
			fake_set df _ "rc=0"
			# rpcinfo output matches ready|waiting -> 1
			fake_set rpcinfo _ "echo=ready"
			;;
		*) echo "plan_nfs_state: bad code '$1'" >&2; return 2 ;;
	esac
}

# ---- iSCSI: -1 (not discoverable) / 0 (no matching Lun) / 1 (Lun present) -----

plan_iscsi_state() { # <-1|0|1>
	case "$1" in
		-1) fake_set iscsi-ls _ "rc=1" ;;              # discovery fails -> -1
		0)  fake_set iscsi-ls _ "rc=0 echo=Lun:0" ;;   # up, lun 1 absent -> 0
		1)  fake_set iscsi-ls _ "rc=0 echo=Lun:1" ;;   # up, lun 1 present -> 1
		*) echo "plan_iscsi_state: bad code '$1'" >&2; return 2 ;;
	esac
}

# ---- S3: 1 (object 200) / 0 (bucket 200) / -1 (plain 403) / -2 (nothing) ------

_s3_blobs() {
	fake_blob s3_200 <<'EOF'
HTTP/1.1 200 OK
Content-Length: 0
EOF
	fake_blob s3_403 <<'EOF'
HTTP/1.1 403 Forbidden
Content-Length: 0
EOF
}

plan_s3_state() {    # <-2|-1|0|1>
	_s3_blobs
	case "$1" in
		1)
			fake_set curl object "cat=blob/s3_200"     # object HEAD 200 -> 1
			;;
		0)
			fake_set curl object "rc=0"                # object HEAD !200
			fake_set curl bucket "cat=blob/s3_200"     # bucket HEAD 200 -> 0
			;;
		-1)
			fake_set curl object "rc=0"
			fake_set curl bucket "rc=0"
			fake_set curl plain  "cat=blob/s3_403"     # plain HEAD 403 -> -1
			;;
		-2)
			fake_set curl object "rc=0"
			fake_set curl bucket "rc=0"
			fake_set curl plain  "rc=0"                # nothing matches -> -2
			;;
		*) echo "plan_s3_state: bad code '$1'" >&2; return 2 ;;
	esac
}

# ---- helper: a well-formed cached metrics body (for seeding stale caches) -----

seed_metric() {      # <svc> <value> -> prints a valid cache body to stdout
	local svc="$1" val="$2"
	case "$svc" in
		nfs)
			printf '# HELP nedge_nfs_service_status NFS service client access status\n'
			printf '# TYPE nedge_nfs_service_status gauge\n'
			printf 'nedge_nfs_service_status{service="nfssvc1",path="/mnt/nfssvc1",hostname="prev",namespace="nedge"} %s\n' "$val"
			printf 'nedge_nfs_service_status{service="nfssvc2",path="/mnt/nfssvc2",hostname="prev",namespace="nedge"} %s\n' "$val"
			;;
		iscsi)
			printf '# HELP nedge_iscsi_service_status iSCSI service client access status\n'
			printf '# TYPE nedge_iscsi_service_status gauge\n'
			printf 'nedge_iscsi_service_status{service="iscsisvc",path="iscsi://10.16.110.214:3260^1",hostname="prev",namespace="nedge"} %s\n' "$val"
			printf 'nedge_iscsi_service_status{service="iscsi-z1",path="iscsi://10.16.110.211:3260^1",hostname="prev",namespace="nedge"} %s\n' "$val"
			;;
		s3)
			printf '# HELP nedge_s3_service_status S3 service client access status\n'
			printf '# TYPE nedge_s3_service_status gauge\n'
			printf 'nedge_s3_service_status{service="s3svc1",path="http://10.16.110.215:9982/bk1/obj1",hostname="prev",namespace="nedge"} %s\n' "$val"
			;;
		*) echo "seed_metric: unknown svc '$svc'" >&2; return 2 ;;
	esac
}
