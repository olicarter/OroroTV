import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var passwordFocused: Bool

    #if os(tvOS)
    private let layout = AnyLayout(HStackLayout(spacing: 120))
    private let logoSize: CGFloat = 120
    private let alignment = HorizontalAlignment.leading
    private let formWidth: CGFloat = 700
    #else
    /// Stacked so it fits in portrait and alongside the keyboard.
    private let layout = AnyLayout(VStackLayout(spacing: 48))
    private let logoSize: CGFloat = 80
    private let alignment = HorizontalAlignment.center
    private let formWidth: CGFloat = 420
    #endif

    var body: some View {
        layout {
            VStack(alignment: alignment, spacing: 24) {
                Text("ororo")
                    .font(.system(size: logoSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                Text("TV shows and movies in their original language, with subtitles.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .frame(maxWidth: 600, alignment: Alignment(horizontal: alignment, vertical: .center))
            }

            VStack(spacing: 30) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .onSubmit { passwordFocused = true }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($passwordFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if busy { ProgressView() }
                        Text(busy ? "Signing in…" : "Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .primaryButtonStyle()
                .disabled(busy || email.isEmpty || password.isEmpty)

                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
                }
                Text("Use the email and password for your ororo.tv account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .frame(width: formWidth)
        }
        .padding(Metrics.detailMargin)
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
        guard !busy, !email.isEmpty, !password.isEmpty else { return }
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
