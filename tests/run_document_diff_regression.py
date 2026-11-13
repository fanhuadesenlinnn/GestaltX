#!/usr/bin/env python3
"""Run the manager's real document-diff methods in a Foundation-only macOS harness.

The UI-facing type imports UIKit. Extract its methods verbatim, retaining the
production document/preset implementations, so the same regression can execute
against an unmodified baseline without an iOS application lifecycle.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


CORE = ["GestaltX/Capabilities.swift", "GestaltX/MobileGestaltCacheLayout.swift",
        "GestaltX/DeviceCacheOptions.swift", "GestaltX/GestaltDocument.swift"]


def extract_member(source, signature, optional=False):
    match = re.search(r"^    " + re.escape(signature), source, re.MULTILINE)
    if match is None:
        if optional:
            return ""
        raise ValueError("Missing production member: " + signature)
    start = source.index("{", match.start())
    depth = 1
    end = start + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[match.start():end]


def harness(source):
    members = [extract_member(source, signature) for signature in
               ["private func describe(", "private func diffLines("]]
    return """import Foundation
@MainActor final class DocumentDiffHarness {
    @inline(never) func rendered(_ before: [String: Any], _ after: [String: Any], prefix: String = "") -> [String] {
        diffLines(before, after, prefix: prefix)
    }
""" + "\n".join(members) + "\n}\n"


def compile_regression(source_root, test, output):
    output.mkdir(parents=True, exist_ok=True)
    manager = source_root / "GestaltX/GestaltManager.swift"
    generated = output / "DocumentDiffHarness.swift"
    generated.write_text(harness(manager.read_text()))
    sources = [source_root / path for path in CORE]
    provenance = [{"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                  for path in [manager, *sources, test, generated]]
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    binary = output / "document-diff"
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", *map(str, sources),
                    str(generated), str(test), "-o", str(binary)], check=True, timeout=180)
    return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--test", type=Path, required=True)
    parser.add_argument("--case", default="correctness")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="document-diff-") as temporary:
        binary = compile_regression(args.source.resolve(), args.test.resolve(), Path(temporary))
        subprocess.run([str(binary), args.case], check=True, timeout=60)


if __name__ == "__main__":
    main()
