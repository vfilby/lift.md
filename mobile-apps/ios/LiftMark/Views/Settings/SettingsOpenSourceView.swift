import SwiftUI

struct OpenSourcePackage: Identifiable {
    let name: String
    let license: String
    let homepageURL: URL
    let licenseURL: URL

    var id: String { name }
}

struct SettingsOpenSourceView: View {
    private let packages: [OpenSourcePackage] = [
        OpenSourcePackage(
            name: "GRDB.swift",
            license: "MIT",
            homepageURL: URL(string: "https://github.com/groue/GRDB.swift")!,
            licenseURL: URL(string: "https://github.com/groue/GRDB.swift/blob/master/LICENSE")!
        ),
        OpenSourcePackage(
            name: "Sentry Cocoa",
            license: "MIT",
            homepageURL: URL(string: "https://github.com/getsentry/sentry-cocoa")!,
            licenseURL: URL(string: "https://github.com/getsentry/sentry-cocoa/blob/main/LICENSE.md")!
        )
    ]

    var body: some View {
        List {
            Section {
                Text("lift.md is built with the following open source packages. "
                    + "Thanks to their authors and maintainers.")
                    .font(.lmFootnote)
                    .foregroundStyle(.secondary)
            }

            Section("Packages") {
                ForEach(packages) { package in
                    VStack(alignment: .leading, spacing: 6) {
                        Link(destination: package.homepageURL) {
                            HStack {
                                Text(package.name)
                                    .foregroundStyle(Color.primary)
                                Spacer()
                                Text(package.license)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                                    .font(.lmFootnote)
                            }
                        }
                        Link("View license", destination: package.licenseURL)
                            .font(.lmFootnote)
                    }
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("oss-package-\(package.name)")
                }
            }
        }
        .navigationTitle("Open Source")
        .accessibilityIdentifier("open-source-screen")
    }
}
