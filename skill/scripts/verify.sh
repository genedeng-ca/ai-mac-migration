#!/bin/bash
# Read-only verification of the approved migration plan.
# Usage: ./verify.sh USER@SOURCE_IP verification-plan.json
# Exit 0: declared checks passed; 1: mismatch/failure; 2: incomplete evidence.
# A plan records scope; it does not grant approval or authorize data transfer.
set -u
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'VERIFICATION SUMMARY: INCOMPLETE — python3 is unavailable'
  exit 2
fi
exec python3 -I -S - "$@" <<'PY'
import base64
import fnmatch
import json
import os
import re
import shlex
import stat
import subprocess
import sys

# Static scanner runs on both hosts. It returns metadata/digests, never file contents.
SCANNER = r'''
import fnmatch, hashlib, json, os, stat, sys, base64

def inventory(spec):
    root = os.path.expanduser(spec["path"])
    if not os.path.isabs(root):
        root = os.path.join(os.path.expanduser("~"), root)
    result = {"present": True, "entries": {}, "errors": []}
    patterns = spec.get("exclude", [])
    def visit(path, rel):
        name = os.path.basename(path)
        if rel and any(fnmatch.fnmatchcase(rel, p) or
                       ("/" not in p and fnmatch.fnmatchcase(name, p)) for p in patterns):
            return
        try:
            before = os.lstat(path)
            if stat.S_ISLNK(before.st_mode):
                result["entries"][rel] = ["link", os.readlink(path)]
            elif stat.S_ISREG(before.st_mode):
                digest = hashlib.sha256()
                with open(path, "rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                result["entries"][rel] = ["file", before.st_size, digest.hexdigest()]
            elif stat.S_ISDIR(before.st_mode):
                result["entries"][rel] = ["directory"]
                with os.scandir(path) as entries:
                    children = sorted(entries, key=lambda item: item.name)
                for child in children:
                    visit(child.path, child.name if not rel else rel + "/" + child.name)
            else:
                raise OSError("unsupported file type")
            after = os.lstat(path)
            signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if signature(before) != signature(after):
                raise OSError("changed while being verified")
        except FileNotFoundError:
            if rel == "":
                result["present"] = False
            else:
                result["errors"].append(rel + ": disappeared during scan")
        except OSError as exc:
            result["errors"].append((rel or ".") + ": " + str(exc))
    visit(root, "")
    return result

if __name__ == "__main__":
    specs = json.loads(base64.urlsafe_b64decode(sys.argv[1]).decode("utf-8"))
    print(json.dumps([inventory(spec) for spec in specs], ensure_ascii=True))
'''

counts = {"PASS": 0, "FAIL": 0, "INCOMPLETE": 0, "N/A": 0}

def report(status, message):
    counts[status] += 1
    print("[{}] {}".format(status, message))

def safe_path(value):
    return (isinstance(value, str) and bool(value) and "\0" not in value
            and ".." not in value.split("/") and not value.startswith("~"))

def validate(plan):
    if not isinstance(plan, dict) or plan.get("schema_version") != 1:
        raise ValueError("expected an object with schema_version=1")
    if not isinstance(plan.get("approval_reference"), str) or not plan["approval_reference"].strip():
        raise ValueError("record the existing approval reference; a plan is not approval")
    entries = plan.get("entries")
    if not isinstance(entries, list) or not entries:
        raise ValueError("entries must be a non-empty approved source/target list")
    for entry in entries:
        if not isinstance(entry, dict) or not all(safe_path(entry.get(k)) for k in ("source", "target")):
            raise ValueError("entry paths must be absolute or home-relative, without ~ or ..")
        if type(entry.get("required", True)) is not bool:
            raise ValueError("required must be boolean")
        patterns = entry.get("exclude", [])
        if not isinstance(patterns, list) or not all(isinstance(p, str) and p and "\0" not in p for p in patterns):
            raise ValueError("exclude must be a list of approved non-empty glob patterns")
    permissions = plan.get("permissions", [])
    if not isinstance(permissions, list):
        raise ValueError("permissions must be a list")
    for item in permissions:
        if not isinstance(item, dict) or not safe_path(item.get("path")) or not re.fullmatch(r"[0-7]{3,4}", str(item.get("mode", ""))):
            raise ValueError("permission checks require a path and octal mode")
    checks = plan.get("manual_checks", [])
    if not isinstance(checks, list):
        raise ValueError("manual_checks must be a list")
    for check in checks:
        if not isinstance(check, dict) or not isinstance(check.get("name"), str) or not check["name"].strip():
            raise ValueError("manual checks require a name")
        if check.get("status", "pending") not in ("passed", "failed", "pending", "not_applicable"):
            raise ValueError("invalid manual check status")
        if not isinstance(check.get("evidence", ""), str):
            raise ValueError("manual check evidence must be a string")
    return entries, permissions, checks

def main():
    if len(sys.argv) != 3:
        report("INCOMPLETE", "Usage: verify.sh USER@SOURCE_IP verification-plan.json; missing scope is not a pass")
        return
    source, plan_path = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:%+\-\[\]]*", source):
        report("INCOMPLETE", "invalid SSH source/alias")
        return
    with open(plan_path, encoding="utf-8") as stream:
        plan = json.load(stream)
    entries, permissions, checks = validate(plan)
    scope = [{"path": e["source"], "exclude": e.get("exclude", [])} for e in entries]
    encoded = base64.urlsafe_b64encode(json.dumps(scope).encode()).decode()
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", source,
               "python3 -I -S - " + shlex.quote(encoded)]
    remote = None
    try:
        timeout = int(os.environ.get("VERIFY_TIMEOUT_SECONDS", "900"))
        if timeout <= 0:
            raise ValueError("VERIFY_TIMEOUT_SECONDS must be positive")
        proc = subprocess.run(command, input=SCANNER, text=True, capture_output=True, timeout=timeout)
        if proc.returncode != 0:
            report("INCOMPLETE", "source inventory unavailable (SSH/remote Python exit {}); not an empty source".format(proc.returncode))
        else:
            remote = json.loads(proc.stdout)
            if not isinstance(remote, list) or len(remote) != len(entries):
                raise ValueError("invalid source inventory response")
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        report("INCOMPLETE", "source inventory could not be established: " + type(exc).__name__)
        remote = None
    namespace = {"__name__": "scanner_library"}
    exec(SCANNER, namespace)
    scan = namespace["inventory"]
    for index, entry in enumerate(entries):
        label = entry["source"] + " -> " + entry["target"]
        try:
            local = scan({"path": entry["target"], "exclude": entry.get("exclude", [])})
            if local["errors"]:
                report("INCOMPLETE", label + ": target unreadable or changed during scan")
                continue
            if remote is None:
                continue
            original = remote[index]
            if not isinstance(original, dict) or not isinstance(original.get("entries"), dict) or type(original.get("present")) is not bool or not isinstance(original.get("errors"), list):
                raise ValueError("invalid inventory entry")
            if original["errors"]:
                report("INCOMPLETE", label + ": source unreadable or changed during scan")
            elif not original["present"]:
                report("FAIL" if entry.get("required", True) else "N/A", label + ": source path absent")
            elif not local["present"]:
                report("FAIL", label + ": target path absent")
            else:
                different = [path for path, value in original["entries"].items() if local["entries"].get(path) != value]
                if different:
                    report("FAIL", label + ": {} missing or different entries (SHA-256/type/link checks)".format(len(different)))
                else:
                    report("PASS", label + ": {} entries verified by content/type/link".format(len(original["entries"])))
                extras = len(set(local["entries"]) - set(original["entries"]))
                if extras:
                    print("[INFO] {}: {} target-only entries retained; no deletion".format(label, extras))
        except (OSError, ValueError, TypeError, KeyError) as exc:
            report("INCOMPLETE", label + ": check unavailable (" + type(exc).__name__ + ")")
    for item in permissions:
        path = item["path"] if os.path.isabs(item["path"]) else os.path.join(os.path.expanduser("~"), item["path"])
        try:
            info = os.lstat(path)
            ok = not stat.S_ISLNK(info.st_mode) and stat.S_IMODE(info.st_mode) == int(str(item["mode"]), 8)
            report("PASS" if ok else "FAIL", "permission check: " + item["path"])
        except FileNotFoundError:
            report("FAIL", "permission target missing: " + item["path"])
        except OSError:
            report("INCOMPLETE", "permission target unreadable: " + item["path"])
    for check in checks:
        status = check.get("status", "pending")
        evidence = check.get("evidence", "").strip()
        if status == "failed":
            report("FAIL", "recorded manual check: " + check["name"])
        elif status == "pending" or not evidence:
            report("INCOMPLETE", "manual evidence required: " + check["name"])
        else:
            report("PASS" if status == "passed" else "N/A", "recorded manual evidence (not independently executed): " + check["name"])

try:
    main()
except (OSError, ValueError, TypeError, KeyError) as exc:
    report("INCOMPLETE", "verification input/check error: " + str(exc))
except KeyboardInterrupt:
    report("INCOMPLETE", "verification interrupted")
if not counts["PASS"] and not counts["FAIL"] and not counts["INCOMPLETE"]:
    report("INCOMPLETE", "no applicable checks verified")
status, code = ("FAILED", 1) if counts["FAIL"] else (("INCOMPLETE", 2) if counts["INCOMPLETE"] else ("PASSED", 0))
print("VERIFICATION SUMMARY: {} | PASS={} FAIL={} INCOMPLETE={} N/A={}".format(status, counts["PASS"], counts["FAIL"], counts["INCOMPLETE"], counts["N/A"]))
print("Scope: declared approved-plan checks only; not an automatic declaration that the entire migration is complete.")
sys.exit(code)
PY
