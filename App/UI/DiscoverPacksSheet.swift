// Bazaar discovery reuses the existing source-review import flow.

import SwiftUI
import AppKit

struct DiscoverPacksSheet: View {
    let installedRepos: Set<String>     // Canonical HTTPS repository URLs, lowercase.
    let onImport: (CatalogPack) -> Void
    let onClose: () -> Void

    private enum Phase: Equatable {
        case loading
        case loaded([CatalogPack])
        case failed(String)
    }
    @State private var phase: Phase = .loading
    @State private var query = ""
    @State private var type = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                TextField(String(localized: "discover.search"), text: $query)
                Picker(String(localized: "discover.type"), selection: $type) {
                    Text(String(localized: "discover.allTypes")).tag("")
                    Text(String(localized: "discover.tool")).tag("tool")
                    Text(String(localized: "discover.workflow")).tag("workflow")
                    Text(String(localized: "discover.finder")).tag("finder")
                }.frame(width: 150)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            content
            footer
        }
        .frame(width: 560, height: 520)
        .background(AWColor.content)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon("shippingbox", size: 34, hue: .teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "discover.title"))
                    .font(.system(size: 14.5, weight: .semibold))
                Text("AnyWhere Bazaar")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(AWColor.label2)
            }
            Spacer(minLength: 0)
            AWButton(String(localized: "discover.refresh"), systemImage: "arrow.clockwise", size: .sm, action: load)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(AWColor.separator).frame(height: 0.5) }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            centered { ProgressView().controlSize(.small)
                Text(String(localized: "discover.loading")).font(.system(size: 12.5)).foregroundStyle(AWColor.label2) }
        case .failed(let msg):
            centered {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 34)).foregroundStyle(AWColor.label3)
                Text(String(localized: "discover.failed")).font(.system(size: 13, weight: .medium))
                Text(msg).font(.system(size: 11)).foregroundStyle(AWColor.label3).multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    AWButton(String(localized: "discover.retry"), size: .sm, action: load)
                    AWButton(String(localized: "discover.openInBrowser"), kind: .plain, size: .sm, action: openMarketplace)
                }.padding(.top, 4)
            }
        case .loaded(let packs) where filtered(packs).isEmpty:
            centered {
                Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(AWColor.label3)
                Text(String(localized: "discover.empty")).font(.system(size: 12.5)).foregroundStyle(AWColor.label2)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
        case .loaded(let packs):
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(filtered(packs).enumerated()), id: \.element.id) { i, pack in
                        if i > 0 { Rectangle().fill(AWColor.separator).frame(height: 0.5) }
                        row(pack)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    private func filtered(_ packs: [CatalogPack]) -> [CatalogPack] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return packs.filter {
            (type.isEmpty || $0.types.contains(type)) &&
            (text.isEmpty || [$0.name, $0.repo, $0.description ?? ""].contains { $0.localizedCaseInsensitiveContains(text) })
        }
    }

    private func row(_ pack: CatalogPack) -> some View {
        let installed = installedRepos.contains(pack.repository.lowercased())
        return HStack(spacing: 11) {
            AppIcon(pack.icon, size: 30, hue: .teal)
            VStack(alignment: .leading, spacing: 1) {
                Text(pack.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(AWColor.label)
                if let d = pack.description, !d.isEmpty {
                    Text(d).font(.system(size: 11.5)).foregroundStyle(AWColor.label2).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if installed {
                Badge(String(localized: "discover.installed"), tone: .green)
            } else {
                AWButton(String(localized: "discover.import"), kind: .primary, size: .sm) { onImport(pack) }
            }
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AWColor.separator).frame(height: 0.5)
            HStack(spacing: 9) {
                AWButton(String(localized: "discover.openInBrowser"), systemImage: "arrow.up.right.square", kind: .plain, size: .sm, action: openMarketplace)
                Spacer(minLength: 0)
                AWButton(String(localized: "discover.close"), size: .sm, action: onClose)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    @ViewBuilder private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 10) { c() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        phase = .loading
        Task {
            do {
                let packs = try await PackDiscovery.catalog().packages
                await MainActor.run { phase = .loaded(packs) }
            } catch {
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func openMarketplace() {
        NSWorkspace.shared.open(PackDiscovery.website)
    }
}
