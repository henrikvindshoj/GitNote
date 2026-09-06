import SwiftUI
import UIKit

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var personalToken = ""

    var body: some View {
        NavigationStack {
            Form {
                if let user = model.githubUser {
                    Section("Connected account") {
                        LabeledContent("GitHub user", value: "@\(user.login)")
                        Button("Refresh repositories") {
                            Task { await model.refreshRemoteRepositories() }
                        }
                        Button("Disconnect", role: .destructive) {
                            model.disconnect()
                        }
                        .disabled(model.isBusy)
                    }
                } else {
                    Section {
                        SecureField("Fine-grained personal access token", text: $personalToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect selected repositories") {
                            let token = personalToken
                            personalToken = ""
                            Task { _ = await model.connectPersonalAccessToken(token) }
                        }
                        .disabled(personalToken.isEmpty || model.isBusy || model.isGitHubSignInInProgress)
                        Link("Create a fine-grained token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    } header: {
                        Text("Selected repositories (recommended)")
                    } footer: {
                        Text("Select only your notes repositories and grant Contents read/write permission. Set an expiration date. Your token is stored in Keychain and available only while this device is unlocked.")
                    }
                    Section {
                        if let authorization = model.githubDeviceAuthorization {
                            Text("Copy this code, then paste it into GitHub on the next screen.")
                                .foregroundStyle(.secondary)
                            LabeledContent("One-time code") {
                                Text(authorization.userCode)
                                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                                    .textSelection(.enabled)
                            }
                            Button("Copy Code and Open GitHub", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = authorization.userCode
                                openURL(authorization.verificationURI)
                            }
                            ProgressView("Waiting for GitHub authorization…")
                            Button("Cancel", role: .cancel) {
                                model.cancelGitHubSignIn()
                            }
                        } else if model.isGitHubSignInInProgress {
                            ProgressView("Starting GitHub login…")
                            Button("Cancel", role: .cancel) {
                                model.cancelGitHubSignIn()
                            }
                        } else {
                            Button {
                                model.startGitHubSignIn()
                            } label: {
                                Label("Connect public repositories with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    } header: {
                        Text("GitHub")
                    } footer: {
                        Text("Optional OAuth login requests access to all public repositories you can write to. Use a selected-repository token above for narrower access or private notes. Older OAuth grants may retain private-repository access until revoked in GitHub settings.")
                    }
                }

                Section("Local storage") {
                    Text("Working copies are stored under Files → On My iPhone/iPad → GitNote → Repositories. Disconnecting does not remove notes or history. Remove local copies from the repository list when using a shared device.")
                    Link("Manage or revoke GitHub tokens", destination: URL(string: "https://github.com/settings/tokens")!)
                    Link("Revoke previous OAuth access", destination: URL(string: "https://github.com/settings/applications")!)
                    Text("Disconnect removes this device’s token. Revoke it on GitHub to invalidate it everywhere.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isGitHubSignInInProgress)
                }
            }
        }
        .onDisappear { personalToken = "" }
        .interactiveDismissDisabled(model.isGitHubSignInInProgress)
    }
}
