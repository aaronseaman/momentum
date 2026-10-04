import SwiftUI
import UniformTypeIdentifiers
import MomentumKit

/// One-time connection forms. The only typing Momentum ever asks for.
struct ConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let kind: IntegrationKind

    @State private var token = ""
    @State private var issuerID = ""
    @State private var keyID = ""
    @State private var privateKey = ""
    @State private var vendorNumber = ""
    @State private var projectID = ""
    @State private var importingKey = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(instructions).font(.subheadline)
                    Button("Open \(helpLinkTitle)") { openURL(helpURL) }
                }
                fields
                if let error {
                    Section { Text(error).foregroundStyle(Theme.attention) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect \(kind.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Connect", action: connect).disabled(!isComplete)
                    }
                }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data, .data]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    privateKey = text
                    // AuthKey_ABC123XYZ.p8 → key ID
                    let name = url.deletingPathExtension().lastPathComponent
                    if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    @ViewBuilder private var fields: some View {
        switch kind {
        case .github:
            Section("Fine-grained personal access token") {
                SecureField("github_pat_…", text: $token)
            }
        case .appStoreConnect:
            Section("API key (App Store Connect → Users and Access → Integrations)") {
                TextField("Issuer ID", text: $issuerID)
                TextField("Key ID", text: $keyID)
                Button(privateKey.isEmpty ? "Choose .p8 key file…" : "Key file loaded ✓") { importingKey = true }
                TextField("Vendor number (Payments and Financial Reports)", text: $vendorNumber)
            }
        case .revenueCat:
            Section("Secret API key (v2) with read access to metrics") {
                SecureField("sk_…", text: $token)
                TextField("Project ID (proj…)", text: $projectID)
            }
        case .stripe:
            Section("Restricted key with read access to Balance and Subscriptions") {
                SecureField("rk_live_…", text: $token)
            }
        }
    }

    private var isComplete: Bool {
        switch kind {
        case .github, .stripe: !token.isEmpty
        case .revenueCat: !token.isEmpty && !projectID.isEmpty
        case .appStoreConnect: !issuerID.isEmpty && !keyID.isEmpty && !privateKey.isEmpty
        }
    }

    private var instructions: String {
        switch kind {
        case .github:
            "Create a fine-grained token with read-only access to Contents, Metadata, Actions and Issues for the repos you want tracked. Momentum finds your active repos automatically."
        case .appStoreConnect:
            "Create an API key with the Sales or Finance role (Developer works too, without sales). Momentum signs requests on this device; the key never leaves it."
        case .revenueCat:
            "Create a v2 secret key in Project settings → API keys with the charts_metrics:overview:read permission."
        case .stripe:
            "Create a restricted key with read-only Balance and Subscriptions access. Momentum never writes to Stripe."
        }
    }

    private var helpLinkTitle: String {
        switch kind {
        case .github: "GitHub token settings"
        case .appStoreConnect: "App Store Connect"
        case .revenueCat: "RevenueCat dashboard"
        case .stripe: "Stripe API keys"
        }
    }

    private var helpURL: URL {
        switch kind {
        case .github: URL(string: "https://github.com/settings/personal-access-tokens/new")!
        case .appStoreConnect: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!
        case .revenueCat: URL(string: "https://app.revenuecat.com/")!
        case .stripe: URL(string: "https://dashboard.stripe.com/apikeys")!
        }
    }

    private func connect() {
        working = true
        error = nil
        Task {
            do {
                switch kind {
                case .github:
                    try await model.connectGitHub(token: token)
                case .appStoreConnect:
                    try await model.connectAppStore(AppStoreConnectCredentials(
                        issuerID: issuerID.trimmingCharacters(in: .whitespaces),
                        keyID: keyID.trimmingCharacters(in: .whitespaces),
                        privateKey: privateKey,
                        vendorNumber: vendorNumber.trimmingCharacters(in: .whitespaces)))
                case .revenueCat:
                    try await model.connectRevenueCat(key: token, projectID: projectID)
                case .stripe:
                    try await model.connectStripe(key: token)
                }
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "That didn't work. Double-check the key and try again."
            }
            working = false
        }
    }
}
