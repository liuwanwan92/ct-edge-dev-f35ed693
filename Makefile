# NexentaEdge Monitoring Config Self-Check
# Run: make check (or make check-<suite>)

SHELL := /usr/bin/env bash
PROJECT_ROOT := $(CURDIR)
export PROJECT_ROOT

CHECK := bash tests/check_monitoring.sh

.PHONY: check check-prometheus check-services check-dashboards check-install check-grafana check-cross check-verbose clean help

## Run all monitoring config checks (default)
check:
	@$(CHECK) --all

## Run only Prometheus scrape config checks
check-prometheus:
	@$(CHECK) --suite=prometheus

## Run only service probe script checks
check-services:
	@$(CHECK) --suite=services

## Run only Grafana dashboard JSON checks
check-dashboards:
	@$(CHECK) --suite=dashboards

## Run only install_dashboard.sh checks
check-install:
	@$(CHECK) --suite=install

## Run only Grafana provisioning config checks
check-grafana:
	@$(CHECK) --suite=grafana

## Run only cross-config consistency checks
check-cross:
	@$(CHECK) --suite=cross

## Run all checks with verbose output
check-verbose:
	@$(CHECK) --all --verbose

## Clean temporary files
clean:
	@rm -rf /tmp/mock_env.* /tmp/mock_logs.*
	@rm -f tests/fixtures/invalid/*.tmp
	@echo "Cleaned temporary files."

## Show available targets
help:
	@echo "Available targets:"
	@echo "  check              Run all monitoring config checks (default)"
	@echo "  check-prometheus   Prometheus scrape config validation"
	@echo "  check-services     Service probe script validation"
	@echo "  check-dashboards   Grafana dashboard JSON validation"
	@echo "  check-install      install_dashboard.sh validation"
	@echo "  check-grafana      Grafana provisioning config validation"
	@echo "  check-cross        Cross-config consistency + conf/* scan"
	@echo "  check-verbose      Run all checks with verbose output"
	@echo "  clean              Clean temporary files"
	@echo "  help               Show this help"
