import AppKit
import AudibleExporterCore
import AudibleExporterPresentation
import SwiftUI

/// Maps the model onto `ExportButtonContent` and owns the export folder popover.
struct ExportButton: View {
    let model: AppViewModel
    let showProgress: () -> Void
    @State private var isFolderPopoverPresented = false

    var body: some View {
        let export = model.export
        ExportButtonContent(
            canExport: model.canExport,
            isRunning: export.isRunning,
            fractionCompleted: export.fractionCompleted,
            activityTitle: export.activityTitle,
            isFolderPopoverPresented: $isFolderPopoverPresented,
            export: {
                showProgress()
                if !export.isRunning { Task { await model.exportSelection() } }
            },
            folderPopover: {
                ExportFolderPopover(folder: export.destinationFolder, canChooseFolder: export.canChooseFolder) {
                    isFolderPopoverPresented = false
                    // Let the popover close before the modal open panel takes over.
                    DispatchQueue.main.async { chooseExportFolder(for: model) }
                }
            }
        )
    }
}

/// Split toolbar button: "Export" exports the selection; the chevron shows the destination folder
/// in a popover. Without a selection it is grey rather than accent-tinted. While an export runs,
/// the button shows its progress and reopens the progress sheet.
struct ExportButtonContent<FolderPopover: View>: View {
    let canExport: Bool
    let isRunning: Bool
    let fractionCompleted: Double
    let activityTitle: String
    @Binding var isFolderPopoverPresented: Bool
    let export: () -> Void
    @ViewBuilder let folderPopover: () -> FolderPopover

    var body: some View {
        HStack(spacing: 0) {
            Button(action: export) {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView(value: fractionCompleted)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                        Text(activityTitle)
                    } else {
                        Text("Export")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .disabled(!canExport && !isRunning)
            .help(isRunning ? "Show progress" : "Export the selected books to M4B")

            Divider()
                .frame(height: 14)

            Button {
                isFolderPopoverPresented.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .help("Export folder")
            .popover(isPresented: $isFolderPopoverPresented, arrowEdge: .bottom, content: folderPopover)
        }
        .buttonStyle(.plain)
        .foregroundStyle(canExport || isRunning ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        .frame(height: 30)
        .exportButtonBackground(isProminent: canExport || isRunning)
    }
}

/// Asks for the export destination and remembers it for the next launch.
@MainActor
private func chooseExportFolder(for model: AppViewModel) {
    let export = model.export
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.directoryURL = export.destinationFolder
    guard panel.runModal() == .OK, let url = panel.url else { return }
    export.destinationFolder = url
    UserDefaults.standard.set(url.path, forKey: CompositionRoot.destinationDefaultsKey)
    Task { await model.rescan() }
}

struct ExportFolderPopover: View {
    let folder: URL?
    let canChooseFolder: Bool
    let chooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Folder").font(.headline)
            Label {
                Text(folder?.path ?? "No folder chosen")
                    .foregroundStyle(folder == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "folder")
            }
            Button(action: chooseFolder) {
                Text(folder == nil ? "Choose Folder…" : "Change Folder…")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!canChooseFolder)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// Maps the export model onto `ExportProgressSheetContent`.
struct ExportProgressSheet: View {
    let model: AppViewModel
    let close: () -> Void

    var body: some View {
        let export = model.export
        ExportProgressSheetContent(
            progress: ExportProgress(
                jobs: export.jobs,
                cancellableJobs: Set(export.jobs.filter(export.canCancel).map(\.id)),
                canCancelAll: export.canCancel,
                isRunning: export.isRunning,
                activityTitle: export.activityTitle,
                statusText: export.statusText,
                errorMessage: export.errorMessage,
                isWaitingForAuthentication: export.isWaitingForAuthentication,
                canSignIn: model.session.canSignIn
            ),
            signIn: { Task { await model.session.signIn() } },
            cancel: { job in Task { await export.cancel(job) } },
            cancelAll: {
                // Cancelling everything empties the list, so the sheet closes with it.
                close()
                Task { await export.cancel() }
            },
            close: close
        )
    }
}

/// Everything the progress sheet shows, as plain values.
struct ExportProgress {
    var jobs: [ExportJob]
    /// Jobs that can still be cancelled on their own.
    var cancellableJobs: Set<UUID>
    var canCancelAll: Bool
    var isRunning: Bool
    var activityTitle: String
    var statusText: String?
    var errorMessage: String?
    var isWaitingForAuthentication: Bool
    var canSignIn: Bool
}

/// Download and export jobs, shown over the library once an export starts from the toolbar. Each
/// job can be cancelled on its own, or all at once; hiding the sheet lets them continue.
struct ExportProgressSheetContent: View {
    let progress: ExportProgress
    let signIn: () -> Void
    let cancel: (ExportJob) -> Void
    let cancelAll: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(progress.isRunning ? progress.activityTitle : "Export").font(.title2.bold())

            if let error = progress.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = progress.statusText {
                Text(status).foregroundStyle(.secondary)
            }

            if progress.isWaitingForAuthentication {
                HStack {
                    Label("Sign in to Audible to continue.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Sign In", action: signIn)
                        .disabled(!progress.canSignIn)
                }
            }

            List(progress.jobs) { job in
                ExportJobRow(job: job, canCancel: progress.cancellableJobs.contains(job.id)) {
                    cancel(job)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 180)

            HStack {
                if progress.canCancelAll {
                    Button("Cancel All", role: .destructive, action: cancelAll)
                }
                Spacer()
                Button(progress.isRunning ? "Hide" : "Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

struct ExportJobRow: View {
    let job: ExportJob
    let canCancel: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: job.book.coverImageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 4) {
                Text(job.book.title).lineLimit(1).help(job.book.title)
                status
            }

            Spacer(minLength: 8)

            if canCancel {
                Button("Cancel \(job.book.title)", systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(job.kind == .download ? "Cancel download" : "Cancel export")
            } else if case .completed(let url) = job.state {
                // The magnifier is the standard macOS "reveal" affordance (Safari/Finder downloads).
                Button("Show \(job.book.title) in Finder", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .queued:
            Text(job.kind == .download ? "Queued for download" : "Queued for export").font(.caption).foregroundStyle(.secondary)
        case .running(let phase, _):
            HStack {
                ProgressView(value: job.fractionCompleted).controlSize(.small)
                Text(phase.label).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        case .waitingForAuthentication:
            Text("Waiting for sign-in").font(.caption).foregroundStyle(.orange)
        case .completed:
            Text(job.kind == .download ? "Downloaded" : "Exported").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).help(message)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension ExportJob.Phase {
    fileprivate var label: String {
        switch self {
        case .licensing: "Requesting license"
        case .downloading: "Downloading"
        case .converting: "Converting"
        case .finalizing: "Finishing"
        }
    }
}

private extension View {
    /// A capsule behind the export button: Liquid Glass on macOS 26, tinted with the accent colour
    /// when `isProminent`; a plain filled capsule before it.
    @ViewBuilder
    func exportButtonBackground(isProminent: Bool) -> some View {
        if #available(macOS 26, *) {
            glassEffect(isProminent ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        } else {
            background(isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
        }
    }
}

#if DEBUG
#Preview("Export button – no selection") { PreviewCatalog.view(.exportButtonNoSelection) }
#Preview("Export button – ready") { PreviewCatalog.view(.exportButtonReady) }
#Preview("Export button – running") { PreviewCatalog.view(.exportButtonRunning) }
#Preview("Export folder – none") { PreviewCatalog.view(.exportFolderNone) }
#Preview("Export folder – set") { PreviewCatalog.view(.exportFolderSet) }
#Preview("Export folder – export running") { PreviewCatalog.view(.exportFolderRunning) }
#Preview("Job row – queued") { PreviewCatalog.view(.jobRowQueued) }
#Preview("Job row – licensing") { PreviewCatalog.view(.jobRowLicensing) }
#Preview("Job row – downloading") { PreviewCatalog.view(.jobRowDownloading) }
#Preview("Job row – converting") { PreviewCatalog.view(.jobRowConverting) }
#Preview("Job row – finalizing") { PreviewCatalog.view(.jobRowFinalizing) }
#Preview("Job row – running, not cancellable") { PreviewCatalog.view(.jobRowNotCancellable) }
#Preview("Job row – waiting for sign-in") { PreviewCatalog.view(.jobRowWaitingForSignIn) }
#Preview("Job row – completed") { PreviewCatalog.view(.jobRowCompleted) }
#Preview("Job row – failed") { PreviewCatalog.view(.jobRowFailed) }
#Preview("Job row – cancelled") { PreviewCatalog.view(.jobRowCancelled) }
#Preview("Progress sheet – running") { PreviewCatalog.view(.progressRunning) }
#Preview("Progress sheet – paused for sign-in") { PreviewCatalog.view(.progressPaused) }
#Preview("Progress sheet – finished with failures") { PreviewCatalog.view(.progressFinished) }
#Preview("Progress sheet – start error") { PreviewCatalog.view(.progressError) }
#endif
