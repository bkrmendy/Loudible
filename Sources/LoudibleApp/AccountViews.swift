import AppKit
import LoudibleCore
import LoudiblePresentation
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
    var needsReauthentication = false

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
            otherMarketplaces: model.library.otherMarketplaces,
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
                Task { await model.signOut() }
            }
        )
    }
}

/// Signed in: the account and Sign Out. Signed out: marketplace and Sign In, with a warning
/// when the session expired.
struct AccountPopoverContent: View {
    let account: AudibleSession?
    /// Other stores whose titles are in the library.
    var otherMarketplaces: [LibraryViewModel.MarketplaceCount] = []
    let needsReauthentication: Bool
    @Binding var marketplace: Marketplace
    let canChangeMarketplace: Bool
    let canSignIn: Bool
    let canSignOut: Bool
    let signIn: () -> Void
    let signOut: () -> Void

    init(
        account: AudibleSession? = nil,
        otherMarketplaces: [LibraryViewModel.MarketplaceCount] = [],
        needsReauthentication: Bool = false,
        marketplace: Binding<Marketplace> = .constant(.us),
        canChangeMarketplace: Bool = true,
        canSignIn: Bool = true,
        canSignOut: Bool = false,
        signIn: @escaping () -> Void = {},
        signOut: @escaping () -> Void = {}
    ) {
        self.account = account
        self.otherMarketplaces = otherMarketplaces
        self.needsReauthentication = needsReauthentication
        _marketplace = marketplace
        self.canChangeMarketplace = canChangeMarketplace
        self.canSignIn = canSignIn
        self.canSignOut = canSignOut
        self.signIn = signIn
        self.signOut = signOut
    }

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
                if !otherMarketplaces.isEmpty {
                    Text("Also has titles in " + otherMarketplaces.map { "\($0.marketplace.name) (\($0.count))" }
                        .joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SignInControls(
                    needsReauthentication: needsReauthentication,
                    marketplace: $marketplace,
                    canChangeMarketplace: canChangeMarketplace,
                    canSignIn: canSignIn,
                    signIn: signIn
                )
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

/// Maps the session onto `SignInPanelContent`, shown in the middle of the window while signed out.
struct SignInPanel: View {
    let session: SessionViewModel

    var body: some View {
        @Bindable var session = session
        SignInPanelContent(
            needsReauthentication: session.needsReauthentication,
            marketplace: $session.marketplace,
            canChangeMarketplace: session.canChangeMarketplace,
            canSignIn: session.canSignIn,
            signIn: { Task { await session.signIn() } }
        )
    }
}

/// The empty window's sign-in prompt: the marketplace and Sign In, as in the account popover.
struct SignInPanelContent: View {
    let needsReauthentication: Bool
    @Binding var marketplace: Marketplace
    let canChangeMarketplace: Bool
    let canSignIn: Bool
    let signIn: () -> Void

    init(
        needsReauthentication: Bool = false,
        marketplace: Binding<Marketplace> = .constant(.us),
        canChangeMarketplace: Bool = true,
        canSignIn: Bool = true,
        signIn: @escaping () -> Void = {}
    ) {
        self.needsReauthentication = needsReauthentication
        _marketplace = marketplace
        self.canChangeMarketplace = canChangeMarketplace
        self.canSignIn = canSignIn
        self.signIn = signIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to see your library")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
            SignInControls(
                needsReauthentication: needsReauthentication,
                marketplace: $marketplace,
                canChangeMarketplace: canChangeMarketplace,
                canSignIn: canSignIn,
                usesGlass: true,
                signIn: signIn
            )
        }
        .controlSize(.large)
        .frame(width: 280)
    }
}

/// The expired-session warning, marketplace picker, and Sign In button, shared by the account
/// popover and the window's sign-in prompt.
private struct SignInControls: View {
    let needsReauthentication: Bool
    @Binding var marketplace: Marketplace
    let canChangeMarketplace: Bool
    let canSignIn: Bool
    /// Clear Liquid Glass on macOS 26, like the toolbar buttons, for the window's prompt; the
    /// popover keeps the plain style.
    var usesGlass = false
    let signIn: () -> Void

    var body: some View {
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
        .signInButtonStyle(usesGlass: usesGlass)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSignIn)
    }
}

private extension View {
    @ViewBuilder
    func signInButtonStyle(usesGlass: Bool) -> some View {
        if #available(macOS 26, *), usesGlass {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
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
extension ViewPreviews {
    static var account: [ViewPreview] {
        [
            ViewPreview("avatarInitial", "Avatar – initial", width: 80, height: 80) {
                AccountAvatar(name: "Jane Doe", size: 24)
            },
            ViewPreview("avatarNoName", "Avatar – no name", width: 80, height: 80) {
                AccountAvatar(name: nil, size: 24)
            },
            ViewPreview("avatarLarge", "Avatar – 44 pt", width: 80, height: 80) {
                AccountAvatar(name: "Jane Doe", size: 44)
            },
            ViewPreview("accountButtonSignedOut", "Account button – signed out", width: 260, height: 60) {
                AccountButtonLabel(name: nil, isSignedIn: false)
            },
            ViewPreview("accountButtonSignedIn", "Account button – signed in", width: 260, height: 60) {
                AccountButtonLabel(name: "Jane Doe", isSignedIn: true)
            },
            ViewPreview("accountButtonLongName", "Account button – long name", width: 260, height: 60) {
                AccountButtonLabel(name: "Maximiliane Alexandra Featherstonehaugh-Smythe", isSignedIn: true)
            },
            ViewPreview("accountButtonNeedsReauthentication", "Account button – needs re-auth", width: 260,
            height: 60) {
                AccountButtonLabel(name: nil, isSignedIn: false, needsReauthentication: true)
            },
            ViewPreview("accountPopoverSignedOut", "Account popover – signed out", width: 280, height: 240) {
                AccountPopoverContent()
            },
            ViewPreview("accountPopoverWorking", "Account popover – working", width: 280, height: 240) {
                AccountPopoverContent(canChangeMarketplace: false, canSignIn: false)
            },
            ViewPreview("accountPopoverExpired", "Account popover – session expired", width: 280, height: 240) {
                AccountPopoverContent(needsReauthentication: true, canSignOut: true)
            },
            ViewPreview("accountPopoverSignedIn", "Account popover – signed in", width: 280, height: 240) {
                AccountPopoverContent(account: PreviewData.session, canSignOut: true)
            },
            ViewPreview("accountPopoverOtherMarketplaces", "Account popover – other marketplaces", width: 280,
            height: 240) {
                AccountPopoverContent(account: PreviewData.session, otherMarketplaces: [
                    LibraryViewModel.MarketplaceCount(marketplace: .uk, count: 12), LibraryViewModel.MarketplaceCount(
                        marketplace: .japan,
                        count: 3),
                ], canSignOut: true)
            },
            ViewPreview("signInPanel", "Sign-in panel", width: 400, height: 260) {
                SignInPanelContent()
            },
            ViewPreview("signInPanelExpired", "Sign-in panel – session expired", width: 400, height: 260) {
                SignInPanelContent(needsReauthentication: true)
            },
        ]
    }
}
#endif
