import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        HStack(spacing: 120) {
            VStack(alignment: .leading, spacing: 24) {
                Text("ororo")
                    .font(.system(size: 120, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                Text("TV shows and movies in their original language, with subtitles.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 600, alignment: .leading)
            }

            VStack(spacing: 30) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text(busy ? "Signing in…" : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(busy || email.isEmpty || password.isEmpty)

                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
                }
                Text("Use the email and password for your ororo.tv account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 700)
        }
        .padding(80)
        .task {
            #if DEBUG
            // Lets you sign in on the simulator from a terminal instead of the on-screen keyboard:
            // SIMCTL_CHILD_OROROTV_EMAIL / SIMCTL_CHILD_OROROTV_PASSWORD with `xcrun simctl launch`.
            let env = ProcessInfo.processInfo.environment
            if let e = env["OROROTV_EMAIL"], let p = env["OROROTV_PASSWORD"], !e.isEmpty, !p.isEmpty {
                email = e
                password = p
                await submit()
            }
            #endif
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
