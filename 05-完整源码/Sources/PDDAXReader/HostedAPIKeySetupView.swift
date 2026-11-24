import SwiftUI

struct HostedAPIKeySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keyFocused: Bool
    @State private var key = ""
    @State private var errorMessage: String?

    let save: (String) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(BilingualText.lines("托管 API 密钥", "Hosted API Key"))
                .font(.title2.weight(.semibold))
            Text(BilingualText.lines(
                "请粘贴用于此店铺的拼多多 API 密钥。密钥保存在此 Mac 上。",
                "Paste the Pinduoduo API key for this store. It is saved on this Mac."
            ))
            .foregroundStyle(.secondary)
            SecureField("PINDUODUO_V2_API_KEY", text: $key)
                .focused($keyFocused)
                .accessibilityIdentifier("hosted-api-key-input")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(BilingualText.lines("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(BilingualText.lines("保存密钥", "Save Key"), action: saveKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { keyFocused = true }
    }

    private func saveKey() {
        do {
            try save(key)
            key = ""
            dismiss()
        } catch {
            errorMessage = (error as? PinduoduoV2CredentialError)?.localizedDescription
                ?? BilingualText.lines("无法保存密钥，请检查本机应用支持目录的权限。",
                                       "Could not save the key. Check access to your Application Support folder.")
        }
    }
}
