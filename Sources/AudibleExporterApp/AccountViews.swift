import AppKit
import AudibleExporterCore
import AudibleExporterPresentation
import SwiftUI

/// The avatar and name at the leading edge of the toolbar; opens the account popover.
struct AccountButton: View {
    let model: AppViewModel
    private var session: SessionViewModel { model.session }
    @State private var isPopoverPresented = false

    var body: some View {
        Button { isPopoverPresented.toggle() } label: {
            AccountButtonLabel(
                name: session.session?.customerName,
                isSignedIn: session.isSignedIn,
                needsReauthentication: session.needsReauthentication
            )
        }
        .buttonStyle(.plain)
        .help(session.isSignedIn ? "Account" : "Sign in to Audible")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            AccountPopover(model: model) { isPopoverPresented = false }
        }
    }
}

/// The account button's avatar, name, and re-authentication warning.
struct AccountButtonLabel: View {
    let name: String?
    let isSignedIn: Bool
    let needsReauthentication: Bool

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(name: name, size: 24)
            Text(title)
                .fontWeight(.semibold)
                .lineLimit(1)
            if needsReauthentication {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .contentShape(Rectangle())
    }

    private var title: String {
        guard isSignedIn else { return "Sign In" }
        return name ?? "Account"
    }
}

/// Maps the session onto `AccountPopoverContent`.
private struct AccountPopover: View {
    let model: AppViewModel
    let dismiss: () -> Void

    var body: some View {
        @Bindable var session = model.session
        AccountPopoverContent(
            account: session.session,
            needsReauthentication: session.needsReauthentication,
            marketplace: $session.marketplace,
            canChangeMarketplace: session.canChangeMarketplace,
            canSignIn: session.canSignIn,
            canSignOut: session.canSignOut,
            signIn: {
                dismiss()
                Task { await session.signIn() }
            },
            signOut: {
                dismiss()
                if model.hasActiveJobs {
                    // Let the popover close before the modal alert takes over.
                    DispatchQueue.main.async {
                        if confirmSignOutWithActiveJobs() { Task { await model.signOut() } }
                    }
                } else {
                    Task { await model.signOut() }
                }
            }
        )
    }
}

/// Signed in: the account and Sign Out. Signed out: marketplace and Sign In, with a warning
/// when the session expired.
struct AccountPopoverContent: View {
    let account: AudibleSession?
    let needsReauthentication: Bool
    @Binding var marketplace: Marketplace
    let canChangeMarketplace: Bool
    let canSignIn: Bool
    let canSignOut: Bool
    let signIn: () -> Void
    let signOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let account {
                HStack(spacing: 12) {
                    AccountAvatar(name: account.customerName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.customerName ?? "Signed in").font(.headline)
                        Text("Audible \(account.marketplace.name)").foregroundStyle(.secondary)
                    }
                }
            } else {
                if needsReauthentication {
                    Label("Your session expired. Sign in again to continue.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Marketplace", selection: $marketplace) {
                    ForEach(Marketplace.all) { Text($0.name).tag($0) }
                }
                .disabled(!canChangeMarketplace)
                Button(action: signIn) {
                    Text("Sign In").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
            }

            if canSignOut {
                Divider()
                Button(role: .destructive, action: signOut) {
                    Text("Sign Out").frame(maxWidth: .infinity)
                }
            }
        }
        .controlSize(.large)
        .padding(16)
        .frame(width: 280)
    }
}

/// Signing out cancels every queued and running job; finished files are kept.
@MainActor
private func confirmSignOutWithActiveJobs() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Sign out and cancel the jobs in progress?"
    alert.informativeText = "Unfinished downloads and exports are discarded. Finished files are kept."
    alert.addButton(withTitle: "Sign Out")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

/// A circle with the account's initial, or a person symbol when there is no name.
struct AccountAvatar: View {
    let name: String?
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.70, green: 0.75, blue: 0.90), Color(red: 0.53, green: 0.58, blue: 0.78)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay {
                if let initial = name?.trimmingCharacters(in: .whitespaces).first {
                    Text(String(initial).uppercased())
                        .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "person.fill").font(.system(size: size * 0.45))
                }
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Avatar – initial") { PreviewCatalog.view(.avatarInitial) }
#Preview("Avatar – no name") { PreviewCatalog.view(.avatarNoName) }
#Preview("Avatar – 44 pt") { PreviewCatalog.view(.avatarLarge) }
#Preview("Account button – signed out") { PreviewCatalog.view(.accountButtonSignedOut) }
#Preview("Account button – signed in") { PreviewCatalog.view(.accountButtonSignedIn) }
#Preview("Account button – long name") { PreviewCatalog.view(.accountButtonLongName) }
#Preview("Account button – needs re-auth") { PreviewCatalog.view(.accountButtonNeedsReauthentication) }
#Preview("Account popover – signed out") { PreviewCatalog.view(.accountPopoverSignedOut) }
#Preview("Account popover – working") { PreviewCatalog.view(.accountPopoverWorking) }
#Preview("Account popover – session expired") { PreviewCatalog.view(.accountPopoverExpired) }
#Preview("Account popover – signed in") { PreviewCatalog.view(.accountPopoverSignedIn) }
#endif
