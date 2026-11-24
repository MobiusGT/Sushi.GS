import AppKit
import SwiftUI

struct AboutView: View {
    private let repoURL = URL(string: "https://github.com/MobiusGT/Sushi.GS")!
    private let issuesURL = URL(string: "https://github.com/MobiusGT/Sushi.GS/issues")!
    private let sushiBatchURL = URL(string: "https://github.com/C1fer/sushi-batch")!
    private let sushiNextURL = URL(string: "https://github.com/C1fer/sushi-next")!

    var body: some View {
        VStack(spacing: Space.lg) {
            appIconImage
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: Space.xs) {
                Text("Gas Station Sushi")
                    .font(.title2.weight(.semibold))
                Text("Sushi.GS · Version \(versionString)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Native Apple Silicon macOS subtitle retiming and MKV batch processor powered by a managed headless Python worker.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Upstream Credits & Licenses")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                creditRow(title: "C1fer/sushi-batch", license: "MIT License", url: sushiBatchURL)
                creditRow(title: "C1fer/sushi-next (sushi-sub-next)", license: "MIT License", url: sushiNextURL)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(spacing: Space.md) {
                Link("GitHub Repository", destination: repoURL)
                Text("·").foregroundStyle(.tertiary)
                Link("Report an Issue", destination: issuesURL)
            }
            .font(.callout)
        }
        .padding(Space.xxl)
        .frame(width: 380)
        .noInitialFocus()
    }

    private func creditRow(title: String, license: String, url: URL) -> some View {
        HStack {
            Link(title, destination: url)
                .font(.callout)
            Spacer()
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "2"
        return "\(short) (\(build))"
    }

    private var appIconImage: Image {
        if let url = Bundle.main.url(forResource: "AboutIcon", withExtension: "png"),
           let nsImg = NSImage(contentsOf: url) {
            return Image(nsImage: nsImg)
        }
        return Image(nsImage: NSApp.applicationIconImage)
    }
}
