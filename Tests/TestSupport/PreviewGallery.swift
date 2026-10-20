import Foundation
@testable import LoudibleApp

/// Static galleries use relative image links so the entire folder can be moved or shared.
enum PreviewGallery {
    static func folder(for source: URL, root: URL?) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        return (root ?? source.deletingLastPathComponent())
            .appendingPathComponent("\(stem)-Previews", isDirectory: true)
    }

    @MainActor
    static func html(source: URL, previews: [ViewPreview]) -> String {
        let title = escape(source.lastPathComponent)
        let items = previews.map { preview in
            """
            <figure id="\(escape(preview.id))">
              <figcaption>\(escape(preview.title)) <small>\(escape(preview.id))</small></figcaption>
              <a href="images/\(escape(preview.id)).png">
                <img src="images/\(escape(preview.id)).png" alt="\(escape(preview.title))"
                     width="\(Int(preview.size.width))" loading="lazy">
              </a>
            </figure>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(title) previews</title>
          <style>
            body { margin: 32px; font: 16px system-ui, sans-serif; background: #f4f4f6; color: #222; }
            main { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 24px; }
            figure { margin: 0; padding: 16px; background: white; border-radius: 12px; max-width: 100%; }
            figcaption { margin-bottom: 12px; font-weight: 600; }
            small { display: block; margin-top: 4px; font-weight: 400; color: #666; }
            img { display: block; max-width: 100%; height: auto; }
          </style>
        </head>
        <body>
          <h1>\(title)</h1>
          <p>\(previews.count) previews. Select an image to view it at full size.</p>
          <main>
        \(items)
          </main>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
