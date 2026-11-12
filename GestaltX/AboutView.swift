// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var model: GestaltManager
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    BrandMark(size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GestaltX").font(.headline)
                    }
                }.padding(.vertical, 6)
                Link(destination: GestaltBrand.projects) {
                    Label { Text(L("GitHub Repository")) } icon: {
                        Image("GitHubMark").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 22, height: 22).foregroundStyle(Color(uiColor: .label))
                    }
                }
            }
            Section {
                LabeledContent(L("Supported OS"), value: VersionSupport.range)
                NavigationLink { CompatibilityView() } label: { Label(L("Compatibility"), systemImage: "iphone.badge.checkmark") }
            }
            Section(L("Special Thanks")) {
                Link(destination: URL(string: "https://github.com/forcequitOS/worse_query")!) {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu").font(.title3).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("worse_query").font(.headline).foregroundStyle(.primary)
                            Text("forcequitOS · Taj C").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 6)
                }
            }
            Section {
                NavigationLink { CreditsView() } label: { Label(L("Credits & Licenses"), systemImage: "text.book.closed") }
            } footer: {
                aboutFooter.padding(.top, 8)
            }
        }
        .listSectionSpacing(20)
        .safeAreaPadding(.bottom, 20)
        .navigationTitle(L("About"))
    }

    private var aboutFooter: some View {
        let year = Calendar.current.component(.year, from: .now)
        return VStack(spacing: 8) {
            Text("Version: \(GestaltBrand.version) (\(GestaltBrand.build))")
                .foregroundStyle(.secondary)
            Text("Developed by huamidev")
                .foregroundStyle(.secondary.opacity(0.7))
            Text("© \(String(year)) huamidev. All rights reserved.")
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct CreditsView: View {
    var body: some View {
        List {
            Section(L("License")) {
                NavigationLink { LicenseTextView(name: "GestaltX-GPL-3.0", title: "GNU GPL v3") } label: { Text("GNU GPL v3") }
            }
            Section(L("Credits")) {
                credit("NeoSpring", author: "rooootdev · neonmodder123 · skadz108", url: "https://github.com/rooootdev/neospring")
                credit("Ketamine", author: "Nouvborne", url: "https://github.com/Nouvborne/Ketamine")
                credit("MGKeys", author: "PoomSmart", url: "https://github.com/PoomSmart/MGKeys")
                credit("Nugget", author: "leminlimez", url: "https://github.com/leminlimez/Nugget")
                credit("GestaltEdit", author: "frs0n", url: "https://github.com/frs0n/GestaltEdit")
            }
        }
        .navigationTitle(L("Credits & Licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ project: String, author: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            LabeledContent { Text(author).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                label: { Text(project).foregroundStyle(.primary) }
        }
    }
}
struct CompatibilityView: View {
    var body: some View {
        List {
            Section(L("worse_query")) {
                Text(VersionSupport.range).font(.headline)
                LabeledContent("iOS 26.x", value: L("Unsupported"))
                Text(L("Available paths and MobileGestalt presets vary by device and OS build."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Link(L("Read Upstream Compatibility"), destination: URL(string: "https://github.com/forcequitOS/worse_query")!)
            }
            Section(L("NeoSpring")) {
                Text(L("NeoSpring attempts a SpringBoard refresh using WebKit. Its effectiveness varies by OS build. Some MobileGestalt changes may still need a manual device restart."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.navigationTitle(L("Compatibility"))
    }
}
struct LicenseTextView: View {
    let name: String
    let title: String
    private var paragraphs: [String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [L("License text could not be loaded.")] }
        // GPL's source text is wrapped at fixed columns. Reflow paragraphs for a phone screen.
        return text.components(separatedBy: "\n\n").map { paragraph in
            paragraph.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }.filter { !$0.isEmpty }
    }
    private func isHeading(_ text: String) -> Bool {
        (text.count < 90 && text == text.uppercased()) || text == "Preamble"
            || text.range(of: #"^\d+\. [A-Z]"#, options: .regularExpression) != nil
            || text == "How to Apply These Terms to Your New Programs"
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(isHeading(paragraph) ? .headline : .body)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .environment(\.layoutDirection, .leftToRight)
            .padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
