"""Closed private-unit source/evidence protocol. No application code or credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

MAX_ZIP = 128 * 1024 * 1024
MAX_EXPANDED = 768 * 1024 * 1024
MAX_FILES = 12000
MAX_INVENTORY = 50000
MAX_CONTROL = 32 * 1024 * 1024
MODULES = {"BaseModule", "SpringAppBase", "SpringAppBackend", "SpringAppFrontend",
           "FacebookBot", "InstagramBot", "TelegramBot", "task_parameters", "UnixClient"}
COMPILE_MODULES = MODULES | {"CheckingProgram"}
VENDORS = ("SeleniumModule", "CaptchaSolverModule")
SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
CLASS = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")
METHOD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
CONTROLS = {"control/source-manifest.json", "control/green-manifest.json",
            "control/green.patch", "control/unit-spec.json"}


def need(value, code):
    if not value:
        raise ValueError(code)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def blob(raw):
    return hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()


def relative(name, windows=True):
    need(isinstance(name, str) and 0 < len(name) <= 1024, "BAD_PATH")
    p = PurePosixPath(name)
    need(not p.is_absolute() and p.as_posix() == name and ".." not in p.parts
         and "\\" not in name and not any(ord(c) < 32 for c in name), "BAD_PATH")
    if windows:
        devices = {"CON", "PRN", "AUX", "NUL", *("COM" + str(n) for n in range(1, 10)),
                   *("LPT" + str(n) for n in range(1, 10))}
        need(":" not in name and not any(c in name for c in '<>"|?*'), "WINDOWS_PATH_ALIAS")
        need(all(not part.endswith((" ", ".")) and part.split(".")[0].upper() not in devices
                 for part in p.parts), "WINDOWS_PATH_ALIAS")
        need(not any(part.casefold() in {".git", ".env", ".ssh", ".aws", ".azure", ".m2", "node_modules", "target"}
                     for part in p.parts), "PRIVATE_OR_GENERATED_INPUT")
        need(p.name.casefold() not in {"settings.xml", "id_rsa", "id_ed25519"}, "PRIVATE_INPUT")
    return p


def ordinary(path):
    current = path
    while True:
        info = current.lstat()
        need(not stat.S_ISLNK(info.st_mode) and not getattr(info, "st_file_attributes", 0) & 1024, "REPARSE_OR_SYMLINK")
        if current.parent == current:
            break
        current = current.parent


def merkle(inventory):
    need(isinstance(inventory, list) and 0 < len(inventory) <= MAX_INVENTORY, "BAD_INVENTORY")
    root = {}
    paths = {}
    for row in inventory:
        name = row["path"]
        p = relative(name, windows=False)
        need(name not in paths and row["mode"] in {"100644", "100755", "120000", "160000"}
             and SHA1.fullmatch(row["git_blob"]), "BAD_GIT_ENTRY")
        paths[name] = row
        directory = root
        for part in p.parts[:-1]:
            found = directory.setdefault(part, {})
            need(isinstance(found, dict), "GIT_FILE_DIRECTORY_COLLISION")
            directory = found
        need(p.name not in directory, "GIT_FILE_DIRECTORY_COLLISION")
        directory[p.name] = (row["mode"], row["git_blob"])

    def tree(directory):
        entries = []
        for name, item in directory.items():
            encoded = name.encode("utf-8")
            if isinstance(item, dict):
                mode, identity, sort_key = "40000", tree(item), encoded + b"/"
            else:
                mode, identity = item
                sort_key = encoded
            entries.append((sort_key, mode.encode() + b" " + encoded + b"\0" + bytes.fromhex(identity)))
        raw = b"".join(entry for _, entry in sorted(entries))
        return hashlib.sha1(b"tree " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    return tree(root), paths


def manifest(data, expected):
    need(data.get("format") == "leadya-private-unit-manifest/v1" and SHA1.fullmatch(expected), "BAD_MANIFEST")
    observed, inventory = merkle(data["inventory"])
    need(data["tree"] == expected == observed, "GIT_TREE_MISMATCH")
    rows = data["source_files"]
    need(isinstance(rows, list) and 0 < len(rows) <= MAX_FILES, "BAD_SOURCE_COUNT")
    names, folded, total = {}, set(), 0
    for row in rows:
        name = relative(row["path"]).as_posix()
        alias = unicodedata.normalize("NFC", name).casefold()
        need(name not in names and alias not in folded, "SOURCE_ALIAS")
        need(type(row["bytes"]) is int and 0 <= row["bytes"] <= MAX_EXPANDED
             and SHA256.fullmatch(row["sha256"]), "BAD_SOURCE_DIGEST")
        original = inventory.get(name)
        need(original is not None and row["mode"] in {"100644", "100755"}
             and (row["mode"], row["git_blob"]) == (original["mode"], original["git_blob"]), "SOURCE_NOT_IN_TREE")
        total += row["bytes"]
        need(total <= MAX_EXPANDED, "SOURCE_SIZE_LIMIT")
        names[name] = row
        folded.add(alias)
    return names


def load_json(path):
    need(path.stat().st_size <= MAX_CONTROL, "CONTROL_SIZE_LIMIT")
    return json.loads(path.read_text(encoding="utf-8-sig"))


def spec(data):
    need(set(data) == {"format", "compile_modules", "red", "green", "node", "green_patch_sha256"}
         and data["format"] == "leadya-private-unit-spec/v1", "BAD_UNIT_SPEC")
    need(isinstance(data["compile_modules"], list) and 0 < len(data["compile_modules"]) <= len(COMPILE_MODULES)
         and len(set(data["compile_modules"])) == len(data["compile_modules"])
         and set(data["compile_modules"]) <= COMPILE_MODULES, "BAD_COMPILE_MODULES")
    red = data["red"]
    need(set(red) == {"module", "class", "method", "failure_contains"}
         and red["module"] in MODULES and CLASS.fullmatch(red["class"])
         and METHOD.fullmatch(red["method"]) and isinstance(red["failure_contains"], str)
         and 0 < len(red["failure_contains"]) <= 512, "BAD_RED_SPEC")
    need(isinstance(data["green"], list) and 0 < len(data["green"]) <= len(MODULES), "BAD_GREEN_SPEC")
    seen = set()
    for suite in data["green"]:
        need(set(suite) == {"module", "tests"} and suite["module"] in MODULES
             and suite["module"] not in seen and suite["module"] in data["compile_modules"], "BAD_GREEN_MODULE")
        tests = suite["tests"]
        need(isinstance(tests, list) and 0 < len(tests) <= 100 and len(set(tests)) == len(tests)
             and all(isinstance(t, str) and CLASS.fullmatch(t) for t in tests), "BAD_GREEN_TESTS")
        seen.add(suite["module"])
    need(red["module"] in data["compile_modules"] and any(s["module"] == red["module"] and red["class"] in s["tests"]
         for s in data["green"]), "RED_NOT_COVERED_BY_GREEN")
    need(isinstance(data["node"], list) and 0 < len(data["node"]) <= 128, "BAD_NODE_SPEC")
    for name in data["node"]:
        p = relative(name)
        need((re.search(r"(?:^|/)test(?:s)?/", name)
              or name == 'docker/n8n/workflows/leadya-chat-rag-code.test.cjs')
             and p.name.endswith((".test.js", ".test.cjs", ".test.mjs")), "BAD_NODE_PATH")
    need(len(set(data["node"])) == len(data["node"]) and SHA256.fullmatch(data["green_patch_sha256"]), "BAD_PATCH_DIGEST")
    return data


def verify_files(root, rows, generated=False):
    ordinary(root)
    for name, row in rows.items():
        path = root.joinpath(*PurePosixPath(name).parts)
        ordinary(path)
        need(path.is_file() and path.stat().st_size == row["bytes"], "SOURCE_FILE_SIZE")
        raw = path.read_bytes()
        need(digest(raw) == row["sha256"] and blob(raw) == row["git_blob"], "SOURCE_BLOB_MISMATCH")
    actual = set()
    for directory, dirs, files in os.walk(root, followlinks=False):
        base = Path(directory)
        ordinary(base)
        for name in list(dirs):
            ordinary(base / name)
            if generated and name == "target" and (base / "pom.xml").is_file():
                dirs.remove(name)
            elif generated and name == 'node_modules' and base == root / 'SpringAppFrontend/src/test/js' and (base / 'package-lock.json').is_file():
                dirs.remove(name)
        for name in files:
            path = base / name
            ordinary(path)
            actual.add(path.relative_to(root).as_posix())
    need(actual == set(rows), "UNMANIFESTED_SOURCE_FILE")


def materialize(archive_path, destination, red_tree, green_tree, zip_sha):
    need(SHA256.fullmatch(zip_sha) and archive_path.stat().st_size <= MAX_ZIP, "BAD_SOURCE_ZIP")
    need(digest(archive_path.read_bytes()) == zip_sha, "SOURCE_ZIP_DIGEST")
    need(not destination.exists(), "DESTINATION_EXISTS")
    ordinary(destination.parent)
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
        need(0 < len(entries) <= MAX_FILES + len(CONTROLS), "ZIP_FILE_COUNT")
        total, aliases, members = 0, set(), {}
        for entry in entries:
            p = relative(entry.filename)
            alias = unicodedata.normalize("NFC", entry.filename).casefold()
            mode = entry.external_attr >> 16
            need(not entry.is_dir() and stat.S_IFMT(mode) in {0, stat.S_IFREG}
                 and not entry.flag_bits & 1 and alias not in aliases, "UNSAFE_ZIP_ENTRY")
            need(entry.filename in CONTROLS or p.parts[0] == "source", "UNEXPECTED_ZIP_ENTRY")
            need(0 <= entry.file_size <= MAX_EXPANDED, "ZIP_ENTRY_SIZE")
            total += entry.file_size
            need(total <= MAX_EXPANDED, "ZIP_EXPANSION_LIMIT")
            aliases.add(alias)
            members[entry.filename] = entry
        need(CONTROLS <= set(members), "MISSING_CONTROL")
        controls = {}
        for name in CONTROLS:
            need(members[name].file_size <= MAX_CONTROL, "CONTROL_SIZE_LIMIT")
            controls[name] = archive.read(name)
        red = json.loads(controls["control/source-manifest.json"])
        green = json.loads(controls["control/green-manifest.json"])
        red_rows, green_rows = manifest(red, red_tree), manifest(green, green_tree)
        plan = spec(json.loads(controls["control/unit-spec.json"]))
        need(digest(controls["control/green.patch"]) == plan["green_patch_sha256"], "GREEN_PATCH_DIGEST")
        need(set(members) == CONTROLS | {"source/" + name for name in red_rows}, "ZIP_MANIFEST_CLOSURE")
        for module in {*plan["compile_modules"], *VENDORS}:
            need(module + "/pom.xml" in red_rows, "MISSING_MODULE_SOURCE")
        need("pom.xml" in red_rows and set(plan["node"]) <= set(red_rows), "MISSING_BUILD_SOURCE")
        destination.mkdir()
        for name, entry in members.items():
            target = destination.joinpath(*PurePosixPath(name).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            ordinary(target.parent)
            copied = 0
            with archive.open(entry) as incoming, target.open("xb") as outgoing:
                while chunk := incoming.read(65536):
                    copied += len(chunk)
                    need(copied <= entry.file_size, "ZIP_STREAM_LIMIT")
                    outgoing.write(chunk)
            need(copied == entry.file_size, "ZIP_TRUNCATED")
        verify_files(destination / "source", red_rows)
    return {"source_tree": red_tree, "prospective_green_tree": green_tree,
            "source_zip_sha256": zip_sha, "verified_source_files": len(red_rows),
            "inventory_entries": len(red["inventory"]), "runtime_tests": "NOT_RUN"}


def patch_paths(raw):
    text = raw.decode("utf-8")
    need(not any(s in text for s in ("GIT binary patch", "rename from ", "rename to ", "copy from ", "copy to ", "120000", "160000")), "PATCH_KIND_REFUSED")
    paths = set()
    for line in text.splitlines():
        if line.startswith("diff --git "):
            found = re.fullmatch(r"diff --git a/(\S+) b/(\S+)", line)
            need(found is not None and found[1] == found[2], "PATCH_PATH")
            name = relative(found[1]).as_posix()
            need(name not in paths, "DUPLICATE_PATCH_PATH")
            paths.add(name)
    need(paths, "EMPTY_GREEN_PATCH")
    return paths


def apply_green(root, control, expected_red, expected_green):
    red = load_json(control / "source-manifest.json")
    green = load_json(control / "green-manifest.json")
    red_rows, green_rows = manifest(red, expected_red), manifest(green, expected_green)
    verify_files(root, red_rows, generated=True)
    plan = spec(load_json(control / "unit-spec.json"))
    raw = (control / "green.patch").read_bytes()
    need(digest(raw) == plan["green_patch_sha256"], "GREEN_PATCH_DIGEST")
    changed = patch_paths(raw)
    before = {r["path"]: (r["mode"], r["git_blob"]) for r in red["inventory"]}
    after = {r["path"]: (r["mode"], r["git_blob"]) for r in green["inventory"]}
    need(changed == {p for p in before.keys() | after.keys() if before.get(p) != after.get(p)}, "GREEN_TREE_PATCH_MISMATCH")
    need(changed <= set(red_rows) | set(green_rows), "PATCH_OUTSIDE_SOURCE_CLOSURE")
    env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="NUL" if os.name == "nt" else "/dev/null",
               GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0", GIT_CEILING_DIRECTORIES=str(root.parent.resolve()))
    for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR'):
        env.pop(key, None)
    for checking in (True, False):
        args = ["git", "-c", "core.autocrlf=false", "-c", "protocol.allow=never", "apply", "--verbose", "--whitespace=error-all"]
        if checking:
            args.append("--check")
        args.append(str((control / "green.patch").resolve()))
        completed = subprocess.run(args, cwd=root, env=env, capture_output=True, timeout=60,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        need(completed.returncode == 0, "GREEN_PATCH_APPLY_FAILED")
    verify_files(root, green_rows, generated=True)


def test_cases(directory):
    files = sorted(directory.glob("TEST-*.xml"))
    need(0 < len(files) <= 500, "MISSING_TEST_REPORTS")
    cases, total = [], 0
    for path in files:
        ordinary(path)
        size = path.stat().st_size
        total += size
        need(size <= 8 * 1024 * 1024 and total <= 64 * 1024 * 1024, "TEST_REPORT_LIMIT")
        with path.open('rb') as stream:
            raw = stream.read(8 * 1024 * 1024 + 1)
        need(len(raw) == size, "TEST_REPORT_CHANGED_OR_OVERSIZED")
        need(b"<!DOCTYPE" not in raw.upper() and b"<!ENTITY" not in raw.upper(), "XML_ENTITY_REFUSED")
        cases.extend(ET.fromstring(raw).iter("testcase"))
    return cases


def evaluate_red(directory, plan, exit_code):
    cases = test_cases(directory)
    red = plan["red"]
    need(exit_code != 0 and len(cases) == 1, "RED_NOT_ONE_FAILED_TEST")
    case = cases[0]
    failure = case.find("failure")
    need(case.get("classname") == red["class"] and case.get("name") == red["method"]
         and failure is not None and case.find("error") is None and case.find("skipped") is None, "RED_WRONG_FAILURE")
    need(failure.get("type") in {"org.opentest4j.AssertionFailedError", "java.lang.AssertionError", "org.junit.ComparisonFailure"}
         and red["failure_contains"] in (failure.get("message", "") + (failure.text or "")), "RED_NOT_CAUSAL_ASSERTION")
    return {"tests": 1, "failures": 1, "errors": 0, "skipped": 0, "causal_red": True}


def evaluate_green(directory, tests, exit_code, red=None):
    cases = test_cases(directory)
    observed = {case.get("classname") for case in cases}
    need(exit_code == 0 and observed == set(tests) and cases, "GREEN_SCOPE_MISMATCH")
    need(all(case.find("failure") is None and case.find("error") is None and case.find("skipped") is None for case in cases), "GREEN_FAILED_OR_SKIPPED")
    if red is not None:
        need(sum(case.get("classname") == red["class"] and case.get("name") == red["method"] for case in cases) == 1,
             "GREEN_MISSING_RED_REGRESSION")
    return {"tests": len(cases), "failures": 0, "errors": 0, "skipped": 0}


def evaluate_node(log, exit_code):
    raw = log.read_text(encoding="utf-8", errors="replace")
    fields = {}
    for key in ("tests", "pass", "fail", "cancelled", "skipped"):
        matches = re.findall(r"^# " + key + r" (\d+)\s*$", raw, re.M)
        need(len(matches) == 1, "NODE_SUMMARY_MISSING")
        fields[key] = int(matches[0])
    need(exit_code == 0 and fields["tests"] > 0 and fields["tests"] == fields["pass"]
         and fields["fail"] == fields["cancelled"] == fields["skipped"] == 0, "NODE_FAILED_OR_SKIPPED")
    return fields


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    material = sub.add_parser("materialize")
    for option in ("archive", "destination", "red-tree", "green-tree", "zip-sha256", "provenance"):
        material.add_argument("--" + option, required=True)
    green = sub.add_parser("apply-green")
    for option in ("source", "control", "red-tree", "green-tree"):
        green.add_argument("--" + option, required=True)
    args = parser.parse_args()
    try:
        if args.action == "materialize":
            provenance = materialize(Path(args.archive), Path(args.destination), args.red_tree, args.green_tree, args.zip_sha256)
            Path(args.provenance).write_text(json.dumps(provenance, indent=2), encoding="utf-8")
        else:
            apply_green(Path(args.source), Path(args.control), args.red_tree, args.green_tree)
    except Exception as error:
        # The enclosing job captures this privately and exposes only a fixed failure label.
        raise SystemExit("PRIVATE_UNIT_PROTOCOL_FAILED:" + type(error).__name__)
