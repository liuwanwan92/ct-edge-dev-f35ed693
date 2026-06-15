#!/usr/bin/env bash
# Scenario: Docker pre-existing-containers
#
# A Prometheus container already exists from a previous installation.
# The install_dashboard.sh script checks `docker ps -a --filter name="prometheus"`
# and counts lines. If more than 1 line (header + container), it aborts
# with "ERROR: Prometheus container already exists".
#
# Expected behavior:
#   - docker pull: succeeds (images may already be cached)
#   - docker ps -a --filter name="prometheus": returns header + container line
#     → wc -l returns 2, which IS > 1 → script dies with error
#   - Subsequent docker commands are never reached
#
# Production script: prometheus/install_dashboard.sh
# Expected script result: exit 1 with "ERROR: Prometheus container already exists"

scenario_setup() {
    # Clear any direct docker response so the scenario handler takes priority
    unset MOCK_RESPONSE_DOCKER 2>/dev/null || true
    unset MOCK_EXIT_DOCKER 2>/dev/null || true

    # Point the docker shim to this scenario file for handler dispatch
    local scenario_file="${MOCK_ROOT}/scenarios/docker/pre-existing-containers.sh"
    export "MOCK_SCENARIO_DOCKER=${scenario_file}"

    # curl is used to download config files; return dummy content
    mock_set_response curl "# Prometheus/Grafana config placeholder"

    # sleep is a no-op
    mock_set_exit sleep 0
}

# Context-aware docker handler for pre-existing containers scenario.
# The key difference from fresh-install is docker ps returning an existing container.
mock_docker_handler() {
    local subcmd="$1"
    shift

    case "${subcmd}" in
        pull)
            # docker pull: image already cached, but still succeeds
            echo "Using default tag: latest"
            echo "Status: Image is up to date for $1"
            return 0
            ;;

        ps)
            # docker ps -a --filter name="prometheus": return header AND an
            # existing container line. The production script does:
            #   n=$(docker ps -a --filter name="prometheus" | wc -l)
            #   if [ $n -gt 1 ]; then die "ERROR: ...already exists"; fi
            # 2 lines (header + container) → n=2 → 2 > 1 → abort
            echo "CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES"
            echo "x9y8z7w6v5u4   prom/prometheus:v2.2.1   \"/bin/prometheus\"   2 days ago   Up 2 days   0.0.0.0:9090->9090/tcp   prometheus"
            return 0
            ;;

        run)
            # docker run: should not be reached in this scenario, but handle it
            echo "Error: container name already in use"
            return 1
            ;;

        inspect)
            # docker inspect: return IP of existing container
            echo "172.17.0.3"
            return 0
            ;;

        exec)
            # docker exec: succeed
            return 0
            ;;

        network)
            # docker network create: succeed
            if [[ "$1" == "create" ]]; then
                echo "net123abc456def"
                return 0
            fi
            return 0
            ;;

        rm)
            # docker rm: succeed
            return 0
            ;;

        *)
            return 0
            ;;
    esac
}
