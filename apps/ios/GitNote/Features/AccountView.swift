import SwiftUI
import UIKit

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                    }
                } else {
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
                                Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                    } header: {
                        Text("GitHub")
                    } footer: {
                        Text("GitNote requests access to public repositories so it can browse and sync them. GitHub opens in your browser; the resulting token is stored in Keychain.")
                    }
                }

                Section("Local storage") {
                    Text("Working copies are stored under Files → On My iPhone/iPad → GitNote → Repositories.")
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
        .interactiveDismissDisabled(model.isGitHubSignInInProgress)
    }
}
