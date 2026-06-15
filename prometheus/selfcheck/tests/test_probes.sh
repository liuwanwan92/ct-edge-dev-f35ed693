#!/usr/bin/env bash
#
# test_probes.sh - behavioral tests for the three service probes, driven
# entirely by a mock environment (fake tools on PATH). No real cluster,
# network, or probe dependencies are required.
#
# Each probe's documented state codes are PINNED so a future edit cannot
# silently change the contract. The known "fake success" gap (a missing
# dependency reported as a normal service state) is asserted explicitly so it
# is visible and regression-protected, per the decision to detect-not-fix it.
#
# NOTE: `set -u` only, NOT pipefail. The probe scripts were authored for default
# pipeline semantics (they read $? as the last command's status); enabling
# pipefail here could change how their pipelines behave during the test.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROM_DIR="$(cd "$SELF_DIR/.." && pwd)"
LIB="$SELF_DIR/lib"
source "$LIB/common.sh"
source "$LIB/mockenv.sh"

ISCSI="$PROM_DIR/svc-checks/nedge-prom-iscsi-check"
NFS="$PROM_DIR/svc-checks/nedge-prom-nfs-check"
S3="$PROM_DIR/svc-checks/nedge-prom-s3-check"
MOUNTLINE='1.2.3.4:/exp on /mnt/nfssvc1 type nfs (rw,addr=1.2.3.4)'

begin_category "test_probes"

# ---------------- iSCSI: states 1 / 0 / -1 ----------------
st=$( mock_init; trap mock_cleanup EXIT
      mock_tool iscsi-ls 0 "Lun:1"
      load_probe_funcs "$ISCSI"; iscsi_check svc 'iscsi://1.2.3.4:3260^1' )
assert_eq 1 "$st" "iscsi: discoverable + LUN present => 1"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool iscsi-ls 0 "Target: foo"
      load_probe_funcs "$ISCSI"; iscsi_check svc 'iscsi://1.2.3.4:3260^1' )
assert_eq 0 "$st" "iscsi: discoverable, LUN not found => 0"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool iscsi-ls 1
      load_probe_funcs "$ISCSI"; iscsi_check svc 'iscsi://1.2.3.4:3260^1' )
assert_eq -1 "$st" "iscsi: not discoverable => -1"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool_absent iscsi-ls
      load_probe_funcs "$ISCSI"; iscsi_check svc 'iscsi://1.2.3.4:3260^1' )
assert_eq -1 "$st" "iscsi: KNOWN GAP - absent iscsi-ls also yields -1 (missing dep looks like network-down)"

# ---------------- NFS: states -3 / 1 / 0 / -2 / -1 ----------------
st=$( mock_init; trap mock_cleanup EXIT
      mock_tool mount 0 ""
      load_probe_funcs "$NFS"; nfs_check svc /mnt/nfssvc1 )
assert_eq -3 "$st" "nfs: not mounted => -3"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool mount 0 "$MOUNTLINE"; mock_tool showmount 0; mock_tool df 0
      mock_tool rpcinfo 0 "ready"; mock_ps_threshold 999999; mock_sleep_noop; mock_kill_noop
      load_probe_funcs "$NFS"; nfs_check svc /mnt/nfssvc1 )
assert_eq 1 "$st" "nfs: mounted + rpcinfo ready => 1"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool mount 0 "$MOUNTLINE"; mock_tool showmount 0; mock_tool df 0
      mock_tool rpcinfo 0 ""; mock_ps_threshold 999999; mock_sleep_noop; mock_kill_noop
      load_probe_funcs "$NFS"; nfs_check svc /mnt/nfssvc1 )
assert_eq 0 "$st" "nfs: mounted + rpcinfo not ready => 0"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool mount 0 "$MOUNTLINE"; mock_tool showmount 0; mock_tool df 0
      mock_tool rpcinfo 0 "ready"; mock_ps_threshold 0; mock_sleep_noop; mock_kill_noop
      load_probe_funcs "$NFS"; nfs_check svc /mnt/nfssvc1 )
assert_eq -2 "$st" "nfs: showmount hangs => -2"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool mount 0 "$MOUNTLINE"; mock_tool showmount 0; mock_tool df 0
      mock_tool rpcinfo 0 "ready"; mock_ps_threshold 2; mock_sleep_noop; mock_kill_noop
      load_probe_funcs "$NFS"; nfs_check svc /mnt/nfssvc1 )
assert_eq -1 "$st" "nfs: df hangs => -1"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool_absent mount
      load_probe_funcs "$NFS"; nfs_check svc /mnt/nfssvc1 )
assert_eq -3 "$st" "nfs: KNOWN GAP - absent mount also yields -3 (missing dep looks like not-mounted)"

# ---------------- S3: states 1 / 0 / -1 / -2 ----------------
S3PATH='http://1.2.3.4:9982/bk1/obj1^KEYID^SECRET'

st=$( mock_init; trap mock_cleanup EXIT
      mock_curl_seq 200; mock_tool openssl 0 "sig"; mock_tool base64 0 "c2ln"
      load_probe_funcs "$S3"; s3_check svc "$S3PATH" )
assert_eq 1 "$st" "s3: object HEAD 200 => 1"

st=$( mock_init; trap mock_cleanup EXIT
      mock_curl_seq none 200; mock_tool openssl 0 "sig"; mock_tool base64 0 "c2ln"
      load_probe_funcs "$S3"; s3_check svc "$S3PATH" )
assert_eq 0 "$st" "s3: object fail, bucket HEAD 200 => 0"

st=$( mock_init; trap mock_cleanup EXIT
      mock_curl_seq none none 403; mock_tool openssl 0 "sig"; mock_tool base64 0 "c2ln"
      load_probe_funcs "$S3"; s3_check svc "$S3PATH" )
assert_eq -1 "$st" "s3: object+bucket fail, service 403 => -1"

st=$( mock_init; trap mock_cleanup EXIT
      mock_curl_seq none none none; mock_tool openssl 0 "sig"; mock_tool base64 0 "c2ln"
      load_probe_funcs "$S3"; s3_check svc "$S3PATH" )
assert_eq -2 "$st" "s3: nothing reachable => -2"

st=$( mock_init; trap mock_cleanup EXIT
      mock_tool_absent curl; mock_tool openssl 0 "sig"; mock_tool base64 0 "c2ln"
      load_probe_funcs "$S3"; s3_check svc "$S3PATH" )
assert_eq -2 "$st" "s3: KNOWN GAP - absent curl also yields -2 (missing dep looks like not-discoverable)"

finish
exit $?
