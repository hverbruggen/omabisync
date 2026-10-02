#!/usr/bin/env python3
"""Read-only status snapshot for an rclone bisync systemd --user service.

Usage: status.py <unit> [history_days] [max_runs] [max_groups]

Prints one JSON object on stdout. Reads only systemd state, the unit's
journal, bisync's own listing files and (cached hourly) `rclone about`.
Never runs a sync itself.
"""

import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time

CACHE_DIR = os.path.expanduser("~/.cache/omabisync")
BISYNC_DIR = os.path.expanduser("~/.cache/rclone/bisync")
QUOTA_TTL_SEC = 3600

# Journal lines worth keeping, matched after ANSI colour codes are stripped
# (bisync colours some of its output even when not on a terminal).
INTERESTING = (
    r"^(INFO  : (No changes found|Bisync (successful|critical error|aborted)|"
    r"Path[12]: +\d+ changes|- Path[12] +(File is|Do queued)|.*: (Copied|Deleted|Moved|Updated)|"
    r".*changed in both paths)|ERROR|NOTICE: [A-Z]|Starting |Finished |Failed |.*: Failed with result)"
)
CHANGES_RE = re.compile(r"Path([12]): +(\d+) changes: +(\d+) new, +(\d+) modified, +(\d+) deleted")
QUEUE_RE = re.compile(r"- Path([12]) +Do queued (copies|deletes|renames)? ?(to|on)? +- Path([12])")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
INTERESTING_RE = re.compile(INTERESTING)
ACTION_RE = re.compile(r"^INFO  : (.+): (Copied \([^)]*\)|Deleted|Moved[^:]*|Updated[^:]*)$")


def run(cmd, timeout=20):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return out.returncode, out.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def show(unit, props):
    _, out = run(["systemctl", "--user", "show", unit, "-p", ",".join(props)])
    result = {}
    for line in out.splitlines():
        key, _, value = line.partition("=")
        result[key] = value
    return result


# rclone flags that take a separate value ("--flag value"), so the value is
# never mistaken for one of bisync's two path arguments.
VALUED_FLAGS = {
    "--filters-file", "--compare", "--max-lock", "--conflict-resolve", "--conflict-loser",
    "--conflict-suffix", "--check-filename", "--log-file", "--log-level", "--log-format",
    "--workdir", "--backup-dir1", "--backup-dir2", "--max-delete", "--resync-mode",
    "--stats", "--stats-log-level", "--config", "--transfers", "--checkers", "--tpslimit",
    "--tpslimit-burst", "--bwlimit", "--retries", "--low-level-retries", "--timeout",
    "--contimeout", "--filter", "--filter-from", "--include", "--include-from",
    "--exclude", "--exclude-from", "--files-from", "--max-age", "--min-age", "--max-size",
    "--min-size", "--order-by", "--user-agent", "--backup-dir", "--suffix", "--color",
    "--max-duration", "--cutoff-mode", "--compare-dest", "--copy-dest", "--hash",
}


def bisync_paths(exec_start):
    """Pull the two bisync paths out of systemctl's ExecStart property."""
    match = re.search(r"argv\[\]=(.*?) ;", exec_start or "")
    if not match:
        return "", ""
    try:
        argv = shlex.split(match.group(1))
    except ValueError:
        argv = match.group(1).split()
    if "bisync" not in argv:
        return "", ""
    positional = []
    args = argv[argv.index("bisync") + 1:]
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg.startswith("-"):
            # A flag in "--flag value" form: its value is not a path argument.
            skip = "=" not in arg and arg in VALUED_FLAGS
            continue
        positional.append(arg)
    # Path arguments are absolute/relative local paths or remote:path specs.
    positional = [a for a in positional if a.startswith(("/", "~", ".")) or ":" in a]
    return (positional + ["", ""])[0], (positional + ["", ""])[1]


def listing_stats(local, remote):
    """File count and size from bisync's last Path1 listing (cached by mtime)."""
    if not local:
        return None
    # bisync names its listings after both paths, e.g. data_Sync..remote_Sync.path1.lst
    stem = local.strip("/").replace("/", "_")
    candidates = sorted(glob.glob(os.path.join(BISYNC_DIR, "*.path1.lst")), key=os.path.getmtime, reverse=True)
    candidates = [c for c in candidates if os.path.basename(c).split("..")[0].endswith(stem)]
    if not candidates:
        return None
    path = candidates[0]
    mtime = os.path.getmtime(path)
    cache_file = os.path.join(CACHE_DIR, "listing.json")
    try:
        with open(cache_file) as f:
            cached = json.load(f)
        if cached.get("path") == path and cached.get("mtime") == mtime:
            return cached["stats"]
    except (OSError, ValueError, KeyError):
        pass
    files = dirs = size = 0
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("-"):
                files += 1
                parts = line.split(None, 2)
                if len(parts) > 1 and parts[1].lstrip("-").isdigit():
                    size += max(0, int(parts[1]))
            elif line.startswith("d"):
                dirs += 1
    stats = {"files": files, "dirs": dirs, "bytes": size, "updatedTs": int(mtime)}
    write_cache(cache_file, {"path": path, "mtime": mtime, "stats": stats})
    return stats


def remote_quota(remote):
    name = remote.split(":", 1)[0] if ":" in remote else ""
    if not name:
        return None
    cache_file = os.path.join(CACHE_DIR, "quota-%s.json" % name)
    try:
        with open(cache_file) as f:
            cached = json.load(f)
        if time.time() - cached.get("ts", 0) < QUOTA_TTL_SEC:
            return cached.get("quota")
    except (OSError, ValueError):
        pass
    code, out = run(["rclone", "about", name + ":", "--json"], timeout=20)
    quota = None
    if code == 0:
        try:
            about = json.loads(out)
            quota = {"used": about.get("used"), "total": about.get("total"), "free": about.get("free")}
        except ValueError:
            quota = None
    write_cache(cache_file, {"ts": time.time(), "quota": quota})
    return quota


def write_cache(path, data):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except OSError:
        pass


def journal(unit, days):
    code, out = run([
        "journalctl", "--user", "-u", unit, "-o", "json", "--no-pager",
        "--since", "-%dd" % days,
        # Drop the per-symlink warnings in journalctl itself; there can be thousands per run.
        "-g", "^(?!.*follow symlink)",
        "--output-fields=MESSAGE,_SYSTEMD_INVOCATION_ID,USER_INVOCATION_ID,__REALTIME_TIMESTAMP",
    ], timeout=30)
    entries = []
    for line in out.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        message = entry.get("MESSAGE")
        if isinstance(message, list):  # non-UTF8 messages arrive as byte arrays
            message = bytes(message).decode("utf-8", "replace")
        message = ANSI_RE.sub("", str(message or "")).rstrip("\n")
        if not INTERESTING_RE.match(message):
            continue
        entries.append({
            "ts": int(entry.get("__REALTIME_TIMESTAMP", "0")) / 1e6,
            "inv": entry.get("_SYSTEMD_INVOCATION_ID") or entry.get("USER_INVOCATION_ID") or "",
            "msg": message,
        })
    return entries


def parse_runs(entries):
    runs = {}
    order = []
    actions = []
    errors = []
    direction = {}
    for e in entries:
        inv = e["inv"]
        msg = e["msg"]
        if inv not in runs:
            runs[inv] = {"startTs": e["ts"], "endTs": 0, "result": "running",
                         "changes": {"path1": None, "path2": None},
                         "up": 0, "down": 0, "deletedLocal": 0, "deletedRemote": 0,
                         "conflicts": 0, "errors": 0}
            order.append(inv)
        r = runs[inv]
        if msg.startswith("Starting "):
            r["startTs"] = e["ts"]
        elif "Bisync successful" in msg:
            r["result"], r["endTs"] = "success", e["ts"]
        elif "Bisync critical error" in msg or "Bisync aborted" in msg:
            r["result"], r["endTs"] = "failed", e["ts"]
            errors.append({"ts": e["ts"], "message": msg.replace("INFO  : ", "")})
        elif msg.startswith("Failed ") or "Failed with result" in msg:
            r["result"] = "failed"
            r["endTs"] = r["endTs"] or e["ts"]
        elif msg.startswith("Finished "):
            r["endTs"] = r["endTs"] or e["ts"]
            if r["result"] == "running":
                r["result"] = "success"
        elif msg.startswith("ERROR"):
            r["errors"] += 1
            errors.append({"ts": e["ts"], "message": msg.replace("ERROR : ", "", 1)})
        elif "No changes found" in msg:
            r["changes"] = {"path1": [0, 0, 0], "path2": [0, 0, 0]}
        else:
            m = CHANGES_RE.search(msg)
            if m:
                r["changes"]["path%s" % m.group(1)] = [int(m.group(3)), int(m.group(4)), int(m.group(5))]
                continue
            m = QUEUE_RE.search(msg)
            if m:
                verb, target = m.group(2) or "", m.group(4)
                if verb == "deletes":
                    direction[inv] = "delLocal" if target == "1" else "delRemote"
                else:
                    direction[inv] = "down" if target == "1" else "up"
                continue
            if "changed in both paths" in msg:
                r["conflicts"] += 1
                path = msg.rsplit(" - ", 1)[-1]
                actions.append({"ts": e["ts"], "inv": inv, "kind": "conflict", "path": path, "detail": "Changed on both sides"})
                continue
            m = ACTION_RE.match(msg)
            if m:
                path, detail = m.group(1), m.group(2)
                kind = direction.get(inv, "up")
                if detail == "Deleted":
                    kind = "delLocal" if kind in ("down", "delLocal") else "delRemote"
                if kind == "up":
                    r["up"] += 1
                elif kind == "down":
                    r["down"] += 1
                elif kind == "delLocal":
                    r["deletedLocal"] += 1
                else:
                    r["deletedRemote"] += 1
                actions.append({"ts": e["ts"], "inv": inv, "kind": kind, "path": path, "detail": detail})
    result = []
    for inv in order:
        r = runs[inv]
        end = r["endTs"] or time.time()
        r["durationSec"] = int(max(0, end - r["startTs"]))
        r["startTs"] = int(r["startTs"])
        r["endTs"] = int(r["endTs"])
        result.append(r)
    return result, actions, errors


# Folders whose contents are noise in a change list: they're folded into one
# "<folder> (N files)" entry instead of being listed file by file.
NOISE_DIRS = {".git", "__pycache__", "node_modules", ".venv", "venv", ".snakemake",
              ".ipynb_checkpoints", ".pytest_cache", ".mypy_cache", "target", ".cache"}
GROUP_DEPTH = 2          # group by the first two folder levels, e.g. DNA_data/peDinoflagellates
MAX_FILES_PER_GROUP = 30


def noise_root(path):
    """Path up to and including the first noise folder, or None."""
    parts = path.split("/")
    for i, part in enumerate(parts[:-1]):
        if part in NOISE_DIRS:
            return "/".join(parts[:i + 1])
    return None


def common_dir(paths):
    split = [p.split("/")[:-1] for p in paths]
    prefix = []
    for parts in zip(*split):
        if all(x == parts[0] for x in parts):
            prefix.append(parts[0])
        else:
            break
    return "/".join(prefix)


def group_changes(actions, max_groups):
    """Group file actions by run, direction and top-level folder (newest first)."""
    groups = {}
    order = []
    for a in actions:
        top = "/".join(a["path"].split("/")[:-1][:GROUP_DEPTH])
        key = "%s|%s|%s" % (a["inv"], a["kind"], top)
        if key not in groups:
            groups[key] = {"key": key, "kind": a["kind"], "ts": a["ts"], "paths": []}
            order.append(key)
        g = groups[key]
        g["ts"] = max(g["ts"], a["ts"])
        g["paths"].append(a["path"])
    result = []
    for key in reversed(order[-max_groups:]):
        g = groups[key]
        paths = g["paths"]
        files, noise = [], {}
        for path in paths:
            root = noise_root(path)
            if root:
                noise[root] = noise.get(root, 0) + 1
            else:
                files.append({"path": path, "count": 1})
        entries = files + [{"path": root, "count": n, "folded": True} for root, n in sorted(noise.items())]
        result.append({
            "key": key,
            "kind": g["kind"],
            "ts": int(g["ts"]),
            "count": len(paths),
            "folder": common_dir(paths) if len(paths) > 1 else "/".join(paths[0].split("/")[:-1]),
            "files": entries[:MAX_FILES_PER_GROUP],
            "moreCount": max(0, len(entries) - MAX_FILES_PER_GROUP),
        })
    return result


def find_bisync_units():
    """Names (without suffix) of user timers whose service runs rclone bisync."""
    _, out = run(["systemctl", "--user", "list-timers", "--all", "-o", "json", "--no-pager"])
    try:
        timers = json.loads(out or "[]")
    except ValueError:
        return []
    found = []
    for t in timers:
        timer, service = t.get("unit", ""), t.get("activates", "")
        if not timer.endswith(".timer") or not service.endswith(".service"):
            continue
        exec_start = show(service, ["ExecStart"]).get("ExecStart", "")
        if re.search(r"rclone\S*\s+(.*\s)?bisync\b", exec_start):
            found.append(timer[:-len(".timer")])
    return found


def main():
    unit = sys.argv[1] if len(sys.argv) > 1 else "rclone-bisync-sync"
    days = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    max_runs = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    max_groups = int(sys.argv[4]) if len(sys.argv) > 4 else 12

    # If the configured unit doesn't exist but exactly one bisync timer does,
    # watch that one, so a differently named setup works without configuration.
    auto_detected = False
    if show(unit + ".service", ["LoadState"]).get("LoadState") != "loaded":
        candidates = find_bisync_units()
        if len(candidates) == 1:
            unit, auto_detected = candidates[0], True

    service = unit + ".service"
    timer = unit + ".timer"

    svc = show(service, ["LoadState", "ActiveState", "SubState", "Result", "ExecMainStartTimestamp", "ExecStart"])
    tmr = show(timer, ["LoadState", "ActiveState", "UnitFileState"])

    next_ts = None
    _, out = run(["systemctl", "--user", "list-timers", "--all", "-o", "json", "--no-pager"])
    try:
        for t in json.loads(out or "[]"):
            if t.get("unit") == timer and t.get("next"):
                next_ts = int(t["next"] / 1e6)
    except ValueError:
        pass

    local, remote = bisync_paths(svc.get("ExecStart", ""))
    runs, actions, errors = parse_runs(journal(service, days))
    last_success = max([r["endTs"] for r in runs if r["result"] == "success"] or [0])
    finished = [r for r in runs if r["result"] != "running"]

    syncing = svc.get("ActiveState") == "activating"
    if svc.get("LoadState") != "loaded":
        state = "missing"
    elif syncing:
        state = "syncing"
    elif svc.get("Result") not in ("success", "") or (finished and finished[-1]["result"] == "failed"):
        state = "failed"
    elif tmr.get("ActiveState") != "active":
        state = "paused"
    else:
        state = "ok"

    print(json.dumps({
        "ok": True,
        "unit": unit,
        "autoDetected": auto_detected,
        "state": state,
        "local": local,
        "remote": remote,
        "timerExists": tmr.get("LoadState") == "loaded",
        "timerActive": tmr.get("ActiveState") == "active",
        "timerEnabled": tmr.get("UnitFileState") == "enabled",
        "nextTs": next_ts,
        "serviceResult": svc.get("Result", ""),
        "runningSinceTs": int(runs[-1]["startTs"]) if syncing and runs else None,
        "lastSuccessTs": int(last_success) or None,
        "listing": listing_stats(local, remote),
        "quota": remote_quota(remote),
        "runs": list(reversed(runs[-max_runs:])),
        "changes": group_changes(actions, max_groups),
        "errors": list(reversed(errors[-5:])),
    }))


if __name__ == "__main__":
    main()
