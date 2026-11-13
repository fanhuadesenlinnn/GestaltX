#!/usr/bin/env python3
"""Compare real FieldsView searches and previews using native Foundation.

The private SwiftUI methods are extracted verbatim into minimal actor-isolated
wrappers. Document, preset, value formatting and localization code is compiled
unchanged. Run on macOS with Swift; this does not simulate UI rendering or measure
physical-device typing latency. Timing results are evidence, not CI thresholds.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess


CORE = ["Capabilities.swift", "MobileGestaltCacheLayout.swift", "DeviceCacheOptions.swift",
        "GestaltDocument.swift", "Localization.swift"]
CASES = [(128, "staged", "no-match-zz"), (512, "staged", "no-match-zz"),
         (2048, "staged", "no-match-zz"), (512, "staged", "value-0128"),
         (512, "staged", "Staged Model"), (512, "unchanged", "no-match-zz"),
         (512, "staged", "")]


def source(repo, ref, path):
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{ref}:{path}"])


def between(text, start, end):
    assert text.count(start) == 1 and text.count(end) == 1, (start, end)
    return start + text.split(start, 1)[1].split(end, 1)[0]


def adapter(manager, content):
    preview = between(manager, "    var preview: GestaltDocument? {", "\n    private func log(")
    fields = content.split("struct FieldsView: View {", 1)[1].split("struct FieldEditorView: View {", 1)[0]
    search = between(fields, "    private var keys: [String] {", "    var body: some View {")
    return """import Foundation
@MainActor final class SearchModel {
    var working: GestaltDocument?
    var snapshot: DocumentSnapshot?
    var choices: [String: PresetChoice] = [:]
    var subtype = 0
    var changesName = false
    var modelName = ""
    var regionID = "keep"
    var regionCodeID = "keep"
    var modelID = "keep"
""" + preview + """
}
@MainActor struct SearchFields {
    let model: SearchModel
    var search: String
""" + search + """
    @inline(never) func matchingKeys() -> [String] { keys }
    func displayText(_ key: String) -> String { valueText(key) }
}
"""


def run(command, output, label, timeout=180):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        (output / f"{label}.stdout").write_bytes(stdout)
        (output / f"{label}.stderr").write_bytes(stderr)
        raise RuntimeError(f"{label}: timeout is not a valid performance result")
    (output / f"{label}.stdout").write_bytes(stdout)
    (output / f"{label}.stderr").write_bytes(stderr)
    if process.returncode:
        raise RuntimeError(f"{label} failed ({process.returncode}): {stderr.decode(errors='replace')}")
    return stdout.decode()


def compile_case(repo, ref, tests_ref, output):
    output.mkdir(parents=True, exist_ok=True)
    files = {name: source(repo, ref, f"GestaltX/{name}") for name in CORE}
    manager = source(repo, ref, "GestaltX/GestaltManager.swift")
    content = source(repo, ref, "GestaltX/ContentView.swift")
    files["FieldSearchProduction.swift"] = adapter(manager.decode(), content.decode()).encode()
    files["FieldSearchTests.swift"] = source(repo, tests_ref, "tests/FieldSearchTests.swift")
    for name, contents in files.items():
        (output / name).write_bytes(contents)
    (output / "provenance.json").write_text(json.dumps({
        "source_commit": ref, "tests_commit": tests_ref,
        "manager_sha256": hashlib.sha256(manager).hexdigest(),
        "content_view_sha256": hashlib.sha256(content).hexdigest(),
        "files": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
        "scope": "Verbatim preview and search methods with real document/preset/formatting code; no UI rendering."
    }, indent=2) + "\n")
    binary = output / "field-search-tests"
    run(["swiftc", "-O", "-swift-version", "5", "-parse-as-library",
         *[str(output / name) for name in files], "-o", str(binary)], output, "compile")
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"]).decode().strip()
    summary = {"base": args.base, "head": head, "correctness": {}, "benchmarks": {}}
    binaries = {}
    for label, ref in [("baseline", args.base), ("fixed", head)]:
        destination = output / label
        binaries[label] = compile_case(repo, ref, head, destination)
        stdout = run([str(binaries[label])], destination, "correctness")
        summary["correctness"][label] = stdout.splitlines()
        assert len(summary["correctness"][label]) == 18 and all(line.startswith("PASS ") for line in stdout.splitlines())
        print(label, stdout, flush=True)
        summary["benchmarks"][label] = []
    # Alternate original/revised measurements for each workload on the same host.
    for index, (count, mode, query) in enumerate(CASES):
        for label in (["baseline", "fixed"] if index % 2 == 0 else ["fixed", "baseline"]):
            stdout = run([str(binaries[label]), "benchmark", str(count), mode, query],
                         output / label, f"benchmark-{index}", timeout=180)
            result = json.loads(stdout)
            summary["benchmarks"][label].append(result)
            print(label, "BENCHMARK", json.dumps({k: v for k, v in result.items() if k != "matching_keys"}), flush=True)
        before, after = (summary["benchmarks"][label][-1] for label in ["baseline", "fixed"])
        for key in ["matching_keys", "checksum", "fixture_fields", "preview_fields", "mode", "query"]:
            assert before[key] == after[key], (index, key)
    summary["success"] = True
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("PASS original/revised compatibility and all benchmark result comparisons", flush=True)


if __name__ == "__main__":
    main()
