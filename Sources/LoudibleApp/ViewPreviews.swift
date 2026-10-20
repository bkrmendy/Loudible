#if DEBUG
import SwiftUI

/// A renderable example declared beside the view it showcases.
@MainActor
struct ViewPreview {
    let id: String
    let title: String
    let source: URL
    let size: CGSize
    let windowChrome: Bool
    let content: () -> AnyView

    init(
        _ id: String, _ title: String, width: CGFloat, height: CGFloat,
        windowChrome: Bool = false, source: String = #filePath,
        @ViewBuilder content: @escaping () -> some View
    ) {
        self.id = id
        self.title = title
        self.source = URL(fileURLWithPath: source)
        size = CGSize(width: width, height: height)
        self.windowChrome = windowChrome
        self.content = {
            AnyView(content()
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
    }
}

/// Register each view file here; its examples live in that file's extension.
@MainActor
enum ViewPreviews {
    static var all: [ViewPreview] { account + bookTile + library + login + window }
}
#endif
