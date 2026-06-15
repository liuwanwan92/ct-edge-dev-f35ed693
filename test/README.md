# svc-check regression & diagnostic harness

Reproduces — deterministically and in isolation — the **flaky transitional states**
of the NexentaEdge Prometheus service checks
(`prometheus/svc-checks/nedge-prom-{nfs,iscsi,s3}-check`), so the
"first scrape fails, second recovers" class of false positives can be turned into
a regression test instead of a thing that only happens on a real cluster.

**Production check logic is never modified.** Everything here lives under `test/`.
The harness runs an *instrumented copy* of each check whose only difference from
production is the cache path (see the drift guard below).

## Run it

Requires **bash** and **bats-core**, on **Linux** (CI or a nedge/client container).

```sh
cd test
./run.sh                  # whole suite
./run.sh nfs_states       # one suite
./run.sh cache_race evidence
```

`run.sh` checks for bats (and prints install hints if missing), runs the suites
against one shared work dir, and tells you where the evidence landed.

> Note on speed: the suite is designed for Linux, where each scrape is milliseconds.
> On Windows + Git-bash/Cygwin it still passes but is *slow* (emulated `fork`, and
> the production kill-loops spawn `ps` repeatedly). Treat Linux/CI as canonical.

## What it reproduces, and why

All three checks share one read-through-cache pattern (`*_last_result`): emit the
**previous** run's `/tmp/nedge-prom-<svc>-check.last`, then recompute the next value
in a **backgrounded** subshell. Three symptoms fall out of that, each with a suite:

| Symptom | Cause | Suite |
|---|---|---|
| **Empty first scrape** ("1st fails, 2nd recovers") | on a fresh node `.last` doesn't exist, so the first body has no metric line | `install_scenario.bats` |
| **One-scrape lag** (false positive on failover / just-started) | a scrape reports the world as captured by the *previous* background export | `upgrade_scenario.bats` |
| **Truncate-then-slow-refill race** | `( … ) > $cache` truncates immediately, then the `df`/`showmount` kill-loops take up to ~20s to refill; a scrape in that window reads a half-written file | `cache_race.bats` |
| **Cross-contamination** (install vs upgrade "串味") | the cache path is **hardcoded and shared** across scenarios/nodes/runs | `isolation.bats` |

The state codes themselves are pinned by `*_states.bats`:

| svc | codes | how each is driven (via fakes) |
|---|---|---|
| nfs | `-3` no mount addr · `-2` showmount times out · `-1` df times out · `0` idle · `1` ready | `mount` table with/without `addr=`; `showmount`/`df` park forever so the **production kill-loop** takes its timeout branch; `rpcinfo` shows/omits `ready` |
| iscsi | `-1` not discoverable · `0` LUN absent · `1` LUN present | `iscsi-ls` exit code; presence of `Lun:1` |
| s3 | `-2` unreachable · `-1` bucket forbidden · `0` bucket ok/object fail · `1` object ok | the three sequential `curl` HEAD probes (object/bucket/plain), each selected independently |

## How a real cluster maps onto the harness

On a real node: `nestart` brings a service up → `socat TCP4-LISTEN:8090,…,fork
EXEC:<check>` exposes it → Prometheus scrapes `GET /metrics`. Each scrape is **one
process** fed that request on stdin.

The harness models exactly that, minus the infrastructure:

- a **scrape** = `bash <instrumented-check>` fed `GET /metrics` on stdin
  (`run_scrape`); stdout is the HTTP body, stderr is the check's own
  `recv`/`send`/redirect trace.
- the external commands the check calls (`mount`, `showmount`, `df`, `rpcinfo`,
  `iscsi-ls`, `curl`, `hostname`, `sleep`) are **shadowed via PATH** by fakes that
  read a per-call **plan**, so every lifecycle moment (cold, coming-up, flapping,
  ready) is reproducible without timing.
- `sleep` is a **no-op** fake, so the checks' `for i in 1..19; ps -p $PID && sleep 1`
  kill-loops fast-forward; a fake that **parks** (on a FIFO) stays "alive" so the
  check deterministically takes its **kill/timeout** branch in milliseconds.
- the **cold→ready** lifecycle that `nestart` produces is *modeled* by the scenario
  plans (`fixtures/scenarios/{install,upgrade}.bash`); no real `docker`/`nestart`/
  `socat` is launched.

## Isolation model

State is keyed by **(scenario, node)**: each gets its own cache dir
(`NEDGE_CHECK_STATE_DIR`) and its own fake state, so install and upgrade — and
different nodes — cannot bleed into each other. Production's single hardcoded
`/tmp/...last` is what makes them bleed; the harness injects a per-(scenario,node)
path via the instrumented copy.

`guard_instrumentation.bats` is the **drift guard**: it asserts the instrumented
copy differs from the production check by *exactly* the cache-path line and nothing
else (and that production still has the hardcoded path the transform targets). If a
production check is ever edited, or the transform regresses, it fails loudly.

## Diagnostics: which step / node / run polluted the state

Every scrape appends one JSON object to
`.work/run-*/<scenario>/<node>/evidence/events.ndjson`:

```json
{"ts":…,"scenario":"upgrade","node":"n1","run":1,"step":"s1","svc":"nfs",
 "http_status":"200","metric_value":"1","metric_lines":2,
 "last_existed_before":"yes","last_bytes_after":309,"verdict":"VALUE"}
```

So a flap is fully attributable: `run` orders the scrapes, `step` labels them,
`node`/`svc`/`scenario` locate them, and `metric_value`/`verdict` say what was
reported (a number, `MISSING`, or `PARTIAL`). Alongside it, per scrape:
`<run>.<step>.<svc>.metrics` (the body) and `.trace` (the check's own log).

## File tree

```
test/
  run.sh                     entrypoint
  README.md                  this file
  lib/
    harness.bash             sandbox, run_scrape/scrape_bg, evidence, sync helpers
    instrument.bash          instrumented-copy generator + drift assertion
    fakes/                   PATH-shadowing fakes (mount, showmount, df, rpcinfo,
                             sleep, iscsi-ls, curl, hostname) + _fakelib.bash
  fixtures/
    states.bash              single source of truth: drive svc -> state code
    scenarios/install.bash   post-install lifecycle (empty cache + cold->ready)
    scenarios/upgrade.bash   post-upgrade lifecycle (stale cache + degraded->recovered)
  bats/
    load.bash                shared loader for every suite
    guard_instrumentation.bats
    nfs_states.bats  iscsi_states.bats  s3_states.bats
    install_scenario.bats  upgrade_scenario.bats
    cache_race.bats  isolation.bats  evidence.bats
```
