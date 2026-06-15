#!/usr/bin/env bash
# services.bash - SERVICE array override mechanism
#
# Production scripts hardcode SERVICES[name]=value in their configuration
# section. This library creates patched copies with custom service definitions.

# Create a patched script with custom NFS services
# Usage: create_nfs_script <service_name> <mount_path> [service_name2 mount_path2 ...]
# Returns: path to the patched script
create_nfs_script() {
    local base_script="${SVC_CHECK_DIR}/nedge-prom-nfs-check"
    local output="${SANDBOX_BIN}/nfs-check-custom"

    cp "${base_script}" "${output}"

    # Build new SERVICES lines
    local services_lines=""
    while [[ $# -ge 2 ]]; do
        local name="$1" path="$2"
        shift 2
        services_lines+="SERVICES[${name}]=${path}"$'\n'
    done

    # Replace the SERVICES configuration section
    # Find lines between CONFIGURATION SECTION and the next ###### line
    sed -i '/^SERVICES\[/d' "${output}"
    sed -i "/CONFIGURATION SECTION/a\\
${services_lines}" "${output}"

    chmod +x "${output}"
    echo "${output}"
}

# Create a patched script with custom iSCSI services
# Usage: create_iscsi_script <service_name> <iscsi_path^lun> [...]
create_iscsi_script() {
    local base_script="${SVC_CHECK_DIR}/nedge-prom-iscsi-check"
    local output="${SANDBOX_BIN}/iscsi-check-custom"

    cp "${base_script}" "${output}"

    local services_lines=""
    while [[ $# -ge 2 ]]; do
        local name="$1" path="$2"
        shift 2
        services_lines+="SERVICES[${name}]=${path}"$'\n'
    done

    sed -i '/^SERVICES\[/d' "${output}"
    sed -i "/CONFIGURATION SECTION/a\\
${services_lines}" "${output}"

    chmod +x "${output}"
    echo "${output}"
}

# Create a patched script with custom S3 services
# Usage: create_s3_script <service_name> <url^keyid^secret> [...]
create_s3_script() {
    local base_script="${SVC_CHECK_DIR}/nedge-prom-s3-check"
    local output="${SANDBOX_BIN}/s3-check-custom"

    cp "${base_script}" "${output}"

    local services_lines=""
    while [[ $# -ge 2 ]]; do
        local name="$1" path="$2"
        shift 2
        services_lines+="SERVICES[${name}]=${path}"$'\n'
    done

    sed -i '/^SERVICES\[/d' "${output}"
    sed -i "/CONFIGURATION SECTION/a\\
${services_lines}" "${output}"

    chmod +x "${output}"
    echo "${output}"
}

# Get the path to the original (unmodified) production script
# The sandbox_exec function will patch /tmp/ paths at runtime.
# Usage: get_nfs_script | get_iscsi_script | get_s3_script
get_nfs_script() {
    echo "${SVC_CHECK_DIR}/nedge-prom-nfs-check"
}

get_iscsi_script() {
    echo "${SVC_CHECK_DIR}/nedge-prom-iscsi-check"
}

get_s3_script() {
    echo "${SVC_CHECK_DIR}/nedge-prom-s3-check"
}

# Create a standard test NFS script with default test services
# Services: testsvc1=/mnt/test1, testsvc2=/mnt/test2
create_default_nfs_script() {
    create_nfs_script "testsvc1" "/mnt/test1" "testsvc2" "/mnt/test2"
}

# Create a standard test iSCSI script with default test services
create_default_iscsi_script() {
    create_iscsi_script "testiscsi" "iscsi://10.0.0.1:3260^1"
}

# Create a standard test S3 script with default test services
create_default_s3_script() {
    create_s3_script "tests3" "http://10.0.0.1:9982/bk1/obj1^TESTKEY^TESTSECRET"
}
