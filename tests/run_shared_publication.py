#!/usr/bin/env python3
"""Run the controller's publication path with native Foundation inboxes.

The UIKit provider supplies a temporary file fixture. The controller's save
method and receipt cleanup are extracted unchanged from each commit.
This does not exercise the full UI or a physical device.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess


def source(repo, ref, path):
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{ref}:{path}"])


def run(command, output, label, timeout=120):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        raise RuntimeError(f"{label}: timeout is not a behavioral reproduction")
    (output / f"{label}.stdout").write_bytes(stdout)
    (output / f"{label}.stderr").write_bytes(stderr)
    return process.returncode, stdout.decode(errors="replace"), stderr.decode(errors="replace")


def compile_case(repo, ref, tests_ref, output):
    output.mkdir(parents=True, exist_ok=True)
    production = source(repo, ref, "Shared/SharedPlistInbox.swift")
    controller = source(repo, ref, "ShareExtension/ShareViewController.swift")
    test = source(repo, tests_ref, "tests/SharedInboxPublicationTests.swift")
    text = controller.decode()
    receipt_start = text.index("    private struct Receipt: Sendable {")
    receipt_end = text.index("    private let status", receipt_start)
    save_start = text.index("    nonisolated private static func save(")
    save_end = text.index("    // Same modern responder-chain open", save_start)
    adapter = """import Foundation
enum SharedAppGroups {
    static var inboxes: [SharedPlistInbox] = []
    static var wallpaperInboxes: [SharedPlistInbox] = []
}
enum ControllerPublication {
""" + text[receipt_start:receipt_end] + text[save_start:save_end] + """
    static func publish(_ url: URL, name: String, checkCancellation: () throws -> Void) throws {
        _ = try save(url, suggestedName: name, archiveHint: false, checkCancellation: checkCancellation)
    }
}
@MainActor func publishShareFixture(_ data: Data, name: String, inboxes: [SharedPlistInbox],
                                  wallpaperInboxes: [SharedPlistInbox] = [],
                                  checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws {
    SharedAppGroups.inboxes = inboxes
    SharedAppGroups.wallpaperInboxes = wallpaperInboxes
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent(name)
    try data.write(to: source)
    try ControllerPublication.publish(source, name: name, checkCancellation: checkCancellation)
}
"""
    files = {"SharedPlistInbox.swift": production, "ControllerPublication.swift": adapter.encode(),
             "SharedInboxPublicationTests.swift": test}
    for name, contents in files.items():
        (output / name).write_bytes(contents)
    (output / "provenance.json").write_text(json.dumps({
        "source_commit": ref, "tests_commit": tests_ref,
        "controller_sha256": hashlib.sha256(controller).hexdigest(),
        "files": {name: hashlib.sha256(contents).hexdigest() for name, contents in files.items()},
        "scope": "Exact controller save method and Receipt cleanup; provider URL supplied as a temporary file; real Foundation filesystem."
    }, indent=2))
    binary = output / "publication-tests"
    code, _, error = run(["swiftc", "-swift-version", "5", "-parse-as-library",
                         *[str(output / name) for name in files], "-o", str(binary)], output, "compile", 180)
    if code: raise RuntimeError(f"Compilation failure is not a reproduction: {error}")
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
    summary = {"base": args.base, "head": head, "baseline": [], "fixed": []}
    for label, ref in [("baseline", args.base), ("fixed", head)]:
        destination = output / label
        binary = compile_case(repo, ref, head, destination)
        for case in ["bad-first", "two-bad", "linked-first", "first-healthy", "all-bad", "invalid", "empty", "cancelled",
                     "callback-cancelled", "cancelled-after-publication", "cancelled-after-fallback", "wallpaper"]:
            code, stdout, stderr = run([str(binary), case], destination, case)
            expected_failure = label == "baseline" and case in ["bad-first", "two-bad", "linked-first", "cancelled-after-fallback"]
            if expected_failure:
                assert code != 0 and "A healthy signed inbox must receive the shared document" in stderr, (case, code, stderr)
            else:
                assert code == 0 and f"PASS {case}" in stdout, (case, code, stderr)
            summary[label].append({"case": case, "returncode": code, "expected_failure": expected_failure})
            print(label, case, "REPRODUCED" if expected_failure else "PASS", flush=True)
    existing = {
        "SharedPlistInboxTests": "Shared/SharedPlistInbox.swift",
        "SharedInboxContainmentTests": "Shared/SharedPlistInbox.swift",
        "SharedInboxCleanupTests": "Shared/SharedPlistInbox.swift",
        "SharedMetadataNameTests": "Shared/SharedPlistInbox.swift",
        "ItemProviderLoadTests": "ShareExtension/ItemProviderLoad.swift",
    }
    for name, production_file in existing.items():
        destination = output / name
        destination.mkdir()
        files = [production_file, f"tests/{name}.swift"]
        paths = []
        for path in files:
            target = destination / Path(path).name
            target.write_bytes(source(repo, head, path)); paths.append(str(target))
        binary = destination / "test"
        code, _, stderr = run(["swiftc", "-swift-version", "5", "-parse-as-library", *paths, "-o", str(binary)], destination, "compile", 180)
        assert code == 0, stderr
        code, stdout, stderr = run([str(binary)], destination, "run")
        assert code == 0, stderr
        print(stdout, flush=True)
    summary["existing_passed"] = list(existing)
    (output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
