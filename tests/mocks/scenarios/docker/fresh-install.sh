#!/usr/bin/env bash
# Scenario: Docker fresh-install
#
# Clean environment with no pre-existing Docker containers or networks.
# The install_dashboard.sh script can proceed with pulling images,
# creating containers, and configuring the dashboard from scratch.
#
# Expected behavior:
#   - docker pull: succeeds (simulates downloading images)
#   - docker ps -a --filter name="prometheus": returns only header line (1 line)
#     → wc -l returns 1, which is NOT > 1, so "already exists" check passes
#   - docker run: succeeds, outputs a container ID
#   - docker inspect: returns a container IP address
#   - docker exec: succeeds (Grafana configuration commands)
#
# Production script: prometheus/install_dashboard.sh

scenario_setup() {
    # Clear any direct docker response so the scenario handler takes priority
    unset MOCK_RESPONSE_DOCKER 2>/dev/null || true
    unset MOCK_EXIT_DOCKER 2>/dev/null || true

    # Point the docker shim to this scenario file for handler dispatch
    local scenario_file="${MOCK_ROOT}/scenarios/docker/fresh-install.sh"
    export "MOCK_SCENARIO_DOCKER=${scenario_file}"

    # curl is used to download config files from GitHub; return dummy content
    mock_set_response curl "# Prometheus/Grafana config placeholder"

    # sleep is used to wait for Grafana to start; make it a no-op
    mock_set_exit sleep 0
}

# Context-aware docker handler for fresh install.
# Routes based on the docker subcommand (first argument).
mock_docker_handler() {
    local subcmd="$1"
    shift

    case "${subcmd}" in
        pull)
            # docker pull <image>: simulate successful image download
            echo "Using default tag: latest"
            echo "latest: Pulling from $1"
            echo "Digest: sha256:abc123def456"
            echo "Status: Downloaded newer image for $1"
            return 0
            ;;

        ps)
            # docker ps -a --filter name="prometheus": return only the header line.
            # The production script does: wc -l on this output.
            # 1 line (header only) means no pre-existing container → proceed.
            echo "CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES"
            return 0
            ;;

        run)
            # docker run -d ...: simulate successful container creation.
            # Output a fake container ID.
            echo "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
            return 0
            ;;

        inspect)
            # docker inspect -f '...' <container>: return a container IP address.
            # The production script uses this to get the Prometheus container IP
            # for configuring Grafana's datasource.
            echo "172.17.0.2"
            return 0
            ;;

        exec)
            # docker exec -i <container> bash -: simulate successful command execution.
            # Used for Grafana configuration (password change, dashboard setup).
            return 0
            ;;

        network)
            # docker network create: simulate successful network creation
            if [[ "$1" == "create" ]]; then
                echo "f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7"
                return 0
            fi
            return 0
            ;;

        rm)
            # docker rm: simulate successful container removal
            return 0
            ;;

        *)
            # Unknown subcommand: succeed silently
            return 0
            ;;
    esac
}
