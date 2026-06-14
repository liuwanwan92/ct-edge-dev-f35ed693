# NexentaEdge self-check harness

A CI-runnable shell harness that verifies NexentaEdge **deployment**, **post-upgrade**,
and **partial-service-not-ready** states across the example config profiles —
**without false success**. It reuses the existing operational assets
(`scripts/nestart`, `prometheus/install_dashboard.sh`, the
`prometheus/svc-checks/nedge-prom-*-check` exporters, and the
`conf/*/nesetup.json` profiles) rather than reimplementing them.

## Why

"Everything looks started" but a protocol service isn't actually serving, a
monitoring target is stale, or a reused `nesetup.json` no longer matches the
running image — and you only find out by reading READMEs and scripts by hand.
This harness turns those checks into one command with a consistent, locatable
verdict that can gate CI.

## Two layers

- **static / mock (always, CI-safe — no docker, no root):**
  - `check-config` — profile-aware validation of every `conf/*/nesetup.json`.
  - `check-monitoring` — prometheus.yml target consistency, the
    `install_dashboard.sh` render contract, svc-check `SERVICES` shapes, and the
    svc-check status-code contract (verified through mocks).
  - `check-scripts` — `bash -n` of the reused scripts, nestart's guard path, and
    install_dashboard's re-run guards.
- **live (`--live`, host-only — read-only oracles against a reachable cluster):**
  - `verify-deploy` — REST `:8080`, cluster consistency, devices `ONLINE`, and
    (for `$SELFCHECK_PROTOCOLS`) endpoint listen + the svc-check reporting
    status `1` (truly serving, not just "container up").
  - `verify-upgrade` — neadm/nedge version skew, nesetup schema drift, and
    post-upgrade readiness.
  - `verify-partial` — a service that exists in `neadm service list` but is not
    serving is a FAIL.

## No false success — exit codes

Result kinds are `PASS / FAIL / SKIP_NA / SKIP_DEP / NOTE`. They aggregate into
one process exit code; **no non-PASS result ever maps to 0**:

| exit | meaning |
|------|---------|
| `0`  | all applicable checks passed |
| `1`  | a FAIL — or, under `--strict`, a promoted SKIP_DEP |
| `2`  | incomplete: a dependency/env was missing (SKIP_DEP); tolerated locally |
| `3`  | the harness itself broke (bad args, missing target dir, a check crashed) |

`SKIP_DEP` ("couldn't verify": no jq/python, tool absent) becomes a **failure
under `--strict`** (used in CI). `SKIP_NA` (a live check while not `--live`) is
never fatal and never promoted. Every result line carries `at=<file:line>`,
`target=<profile>`, and a `fix:` hint.

## Usage

```sh
./selfcheck.sh [--target <conf-dir>|all] [--live] [--strict] [--targets-file <file>]

./selfcheck.sh --target all                       # static layer, all profiles
./selfcheck.sh --target conf/gateway              # one profile
./selfcheck.sh --strict --target all              # CI mode (skips become failures)
./selfcheck.sh --target all --targets-file selfcheck/fixtures/targets/default.targets
SELFCHECK_PROTOCOLS="iscsi nfs s3" ./selfcheck.sh --live --strict --target all   # on a node
```

Idempotent: it cleans the exporters' `/tmp` caches and its own temp on entry and
exit, never mutates the repo, and live checks are read-only — so repeated runs
start and end from identical state.

## Environment knobs

| var | effect |
|-----|--------|
| `SELFCHECK_STRICT=1` | promote SKIP_DEP to failure (same as `--strict`) |
| `SELFCHECK_LIVE=1` | run the live layer (same as `--live`) |
| `SELFCHECK_PROTOCOLS` | space list (`iscsi nfs s3`) of endpoints `verify-deploy` checks |
| `SELFCHECK_MGMTIP` | expected mgmt IP for the monitoring target (else use `--targets-file`) |
| `SELFCHECK_SCHEMA_KEYS` | file of nesetup dotpaths the target image requires (drift check) |
| `SELFCHECK_SCRIPT_GUARDS=strict` | treat install_dashboard's missing grafana guard as FAIL (default: NOTE) |
| `SELFCHECK_MOCKS` | dir of mock probe tools (set by the tests; unset = real tools in live mode) |
| `SELFCHECK_SETTLE_SLEEP` / `SELFCHECK_SETTLE_TRIES` | svc-check cache settle poll tuning |

## Layout

```
selfcheck/
  selfcheck.sh   run-ci.sh   Makefile
  lib/      common.sh deps.sh json.sh jsonq.py svccheck.sh discover.sh
  checks/   check-config check-monitoring check-scripts
            verify-deploy verify-upgrade verify-partial
  mocks/    PATH-injected stand-ins for iscsi-ls/showmount/df/curl/neadm/...
  fixtures/ targets/ prometheus/ configs/missing-items/ schema/ versions/
  tests/    *.bats + helpers.bash
```

## CI

`make check` (or `bash selfcheck/run-ci.sh`) runs the static/mock layer with
`--strict` plus the bats suite. See `.github/workflows/selfcheck.yml` (a
template — the three steps copy directly into GitLab CI / a Jenkins `sh` block).
CI installs `jq` so JSON checks never skip.

## Adding a check

Drop a `checks/<name>` script that sources `lib/common.sh`, emits results via
`pass/fail/skip_na/skip_dep/note <id> <msg> [fix]`, ends with `sc_finish`, and
add a `run_check` line in `selfcheck.sh`. Add a `tests/<name>.bats` covering at
least one PASS and one FAIL.

## Notes

- JSON access prefers `jq`; if absent it falls back to a working `python`
  (probed by execution, not just `command -v`); if neither, JSON checks SKIP_DEP.
- On Windows / Git-Bash the harness is correct but slow (each process spawn is
  ~0.3s and there is no `jq`, so it uses `python` per profile). On Linux CI with
  `jq` it runs in seconds. `.gitattributes` pins these scripts to LF so a Windows
  checkout can't introduce CRLF.
- The exporters define **two** services for iSCSI/NFS; `svc_check_status` can
  filter by `service="<name>"`.
