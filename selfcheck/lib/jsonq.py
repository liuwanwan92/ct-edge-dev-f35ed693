#!/usr/bin/env python3
"""selfcheck/lib/jsonq.py -- tiny JSON query helper used as the python backend
of lib/json.sh (the jq backend is used when jq is installed).

Usage:  jsonq.py <file> <op> [args...]

Ops (dotpath = dot-separated object keys, e.g. ccow.tenant.failure_domain):
  valid                      exit 0 if <file> is valid JSON, else 2
  get        <dotpath>       print scalar value; exit 0 if found+scalar, else 1
  type       <dotpath>       print object|array|string|number|boolean|null|absent
  len        <dotpath>       print array length (exit 0) or -1 (exit 1) if not array
  isint      <dotpath>       exit 0 if value is an integer number, else 1
  nonemptystr <dotpath>      exit 0 if value is a non-empty string, else 1
  allhave    <dotpath> <k..> exit 0 if value is an array whose every element is an
                             object containing all keys k... (empty array -> 0)

Exit codes: 0 = ok/true, 1 = false/absent, 2 = error (bad JSON / IO / usage).
"""
import json
import sys

_MISSING = object()


def _load(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:  # noqa: BLE001 - any load failure is an error exit
        sys.stderr.write("jsonq: %s\n" % exc)
        sys.exit(2)


def _walk(doc, dotpath):
    cur = doc
    if dotpath == "":
        return cur
    for seg in dotpath.split("."):
        if isinstance(cur, dict) and seg in cur:
            cur = cur[seg]
        else:
            return _MISSING
    return cur


def _typename(val):
    if val is None:
        return "null"
    if isinstance(val, bool):
        return "boolean"
    if isinstance(val, (int, float)):
        return "number"
    if isinstance(val, str):
        return "string"
    if isinstance(val, list):
        return "array"
    if isinstance(val, dict):
        return "object"
    return "unknown"


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    path, op = argv[1], argv[2]
    args = argv[3:]
    doc = _load(path)

    if op == "valid":
        return 0

    if op == "facts":
        # One-shot extraction of every fact check-config needs (one process
        # instead of ~10). Only safe scalar/boolean/type tokens are emitted, so
        # the caller can `eval` the output.
        def bint(b):
            return "1" if b else "0"

        def all_have(arr, keys):
            if not isinstance(arr, list):
                return False
            return all(isinstance(e, dict) and all(k in e for k in keys) for e in arr)

        fd = _walk(doc, "ccow.tenant.failure_domain")
        fd_isint = (not isinstance(fd, bool)) and isinstance(fd, int)
        broker = _walk(doc, "ccow.network.broker_interfaces")
        server = _walk(doc, "ccowd.network.server_interfaces")
        transport = _walk(doc, "ccowd.transport")
        isagg = _walk(doc, "auditd.is_aggregator")
        devs = _walk(doc, "rtrd.devices")
        print("FD_ISINT=" + bint(fd_isint))
        print("FD_VALUE=" + (str(fd) if fd_isint else ""))
        print("BROKER_OK=" + bint(isinstance(broker, str) and len(broker) > 0))
        print("SERVER_OK=" + bint(isinstance(server, str) and len(server) > 0))
        print("TRANSPORT_LEN=" + (str(len(transport)) if isinstance(transport, list) else "-1"))
        print("IS_AGG=" + (str(isagg) if (isinstance(isagg, int) and not isinstance(isagg, bool)) else "_absent_"))
        print("DEVICES_TYPE=" + (_typename(devs) if devs is not _MISSING else "absent"))
        print("DEVICES_LEN=" + (str(len(devs)) if isinstance(devs, list) else "-1"))
        print("HAVE_NAME_DEVICE=" + bint(all_have(devs, ["name", "device"])))
        print("HAVE_JOURNAL=" + bint(all_have(devs, ["journal"])))
        print("HAVE_TUNING=" + bint(all_have(devs, ["readahead", "wal_disabled", "sync"])))
        return 0

    if op in ("get", "type", "len", "isint", "nonemptystr", "allhave"):
        if not args:
            sys.stderr.write("jsonq: op %s needs a dotpath\n" % op)
            return 2
        val = _walk(doc, args[0])
    else:
        sys.stderr.write("jsonq: unknown op %s\n" % op)
        return 2

    if op == "get":
        if val is _MISSING or isinstance(val, (list, dict)):
            return 1
        if isinstance(val, bool):
            print("true" if val else "false")
        elif val is None:
            print("null")
        else:
            print(val)
        return 0

    if op == "type":
        if val is _MISSING:
            print("absent")
            return 1
        print(_typename(val))
        return 0

    if op == "len":
        if isinstance(val, list):
            print(len(val))
            return 0
        print(-1)
        return 1

    if op == "isint":
        return 0 if (not isinstance(val, bool) and isinstance(val, int)) else 1

    if op == "nonemptystr":
        return 0 if (isinstance(val, str) and len(val) > 0) else 1

    if op == "allhave":
        keys = args[1:]
        if not isinstance(val, list):
            return 1
        for elem in val:
            if not isinstance(elem, dict):
                return 1
            for k in keys:
                if k not in elem:
                    return 1
        return 0

    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
