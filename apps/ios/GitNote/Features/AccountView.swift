import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

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
                            token = ""
                        }
                    }
                } else {
                    Section {
                        SecureField("Fine-grained personal access token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect") {
                            Task {
                                if await model.connect(token: token) {
                                    token = ""
                                }
                            }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("GitHub")
                    } footer: {
                        Text("For this MVP, use a fine-grained token with read-only metadata access. GitNote stores it in Keychain and does not put it in Git URLs.")
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
                }
            }
        }
    }
}
