#!/usr/bin/env bats
# Core: the svc-check exporters map probe states to the documented status
# numbers -- so the runtime oracle can be trusted (no false success).
load helpers

@test "iscsi contract: ready=1, nolun=0, down=-1" {
	export MOCK_ISCSI_STATE=ready; [ "$(svc_check_status "$ISCSI" nedge_iscsi_service_status iscsisvc)" = 1 ]
	export MOCK_ISCSI_STATE=nolun; [ "$(svc_check_status "$ISCSI" nedge_iscsi_service_status iscsisvc)" = 0 ]
	export MOCK_ISCSI_STATE=down;  [ "$(svc_check_status "$ISCSI" nedge_iscsi_service_status iscsisvc)" = -1 ]
}

@test "s3 contract: ok=1, bucket=0, obj=-1, down=-2" {
	export MOCK_S3_STATE=ok;     [ "$(svc_check_status "$S3C" nedge_s3_service_status s3svc1)" = 1 ]
	export MOCK_S3_STATE=bucket; [ "$(svc_check_status "$S3C" nedge_s3_service_status s3svc1)" = 0 ]
	export MOCK_S3_STATE=obj;    [ "$(svc_check_status "$S3C" nedge_s3_service_status s3svc1)" = -1 ]
	export MOCK_S3_STATE=down;   [ "$(svc_check_status "$S3C" nedge_s3_service_status s3svc1)" = -2 ]
}

@test "nfs contract (fast): ready=1, rpc-down=0, unmounted=-3" {
	export MOCK_NFS_MOUNTED=1 MOCK_RPCINFO=ready; [ "$(svc_check_status "$NFSC" nedge_nfs_service_status nfssvc1)" = 1 ]
	export MOCK_NFS_MOUNTED=1 MOCK_RPCINFO=down;  [ "$(svc_check_status "$NFSC" nedge_nfs_service_status nfssvc1)" = 0 ]
	export MOCK_NFS_MOUNTED=0;                    [ "$(svc_check_status "$NFSC" nedge_nfs_service_status nfssvc1)" = -3 ]
}

@test "nfs contract (slow): df-broken=-1, showmount-broken=-2" {
	[ "${SELFCHECK_SLOW:-0}" = 1 ] || skip "slow NFS hang states (~19s each); set SELFCHECK_SLOW=1 to run"
	export SELFCHECK_SETTLE_TRIES=300
	export MOCK_NFS_MOUNTED=1 MOCK_SHOWMOUNT=ok MOCK_DF=hang
	[ "$(svc_check_status "$NFSC" nedge_nfs_service_status nfssvc1)" = -1 ]
	export MOCK_NFS_MOUNTED=1 MOCK_SHOWMOUNT=hang MOCK_DF=ok
	[ "$(svc_check_status "$NFSC" nedge_nfs_service_status nfssvc1)" = -2 ]
}
