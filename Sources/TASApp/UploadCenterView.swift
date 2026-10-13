#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct UploadCenterView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    var body: some View {
        LibrarySurface(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label(L10n.tr("文件（文件夹）上传"), systemImage: "tray.and.arrow.up").font(LibraryStyle.sectionTitle)
                    Spacer()
                    Button(L10n.tr("上传文件或文件夹…"), systemImage: "doc.badge.plus") { model.chooseUpload() }
                        .keyboardShortcut("u").buttonStyle(.borderedProminent)
                        .disabled(!model.canOperate || model.historyFile != nil)
                }
                UploadDropZone(kind: .filesAndFolders)
                Text(L10n.tr("保留文件夹层级，跳过隐藏项。同名文件可保存为新版本。"))
                    .font(LibraryStyle.helper).foregroundStyle(.secondary)
            }
        }
    }
}

enum UploadKind {
    case files, folders, filesAndFolders
    /// Validate the complete selection before collection or any transfer. Never
    /// infer enrollment from a dropped directory or partially accept a batch.
    func validate(_ urls: [URL]) throws {
        for url in urls {
            guard url.isFileURL else { throw UploadInputError(kind: self) }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            let matchesKind: Bool
            switch self {
            case .files: matchesKind = values.isRegularFile == true
            case .folders: matchesKind = values.isDirectory == true
            case .filesAndFolders: matchesKind = values.isRegularFile == true || values.isDirectory == true
            }
            guard values.isSymbolicLink != true, matchesKind else {
                throw UploadInputError(kind: self)
            }
        }
    }
}

struct UploadInputError: LocalizedError {
    let kind: UploadKind
    var errorDescription: String? {
        switch kind {
        case .files: L10n.tr("此区域仅接受普通文件。请将文件夹拖入文件夹区域；未开始上传。")
        case .folders: L10n.tr("此区域仅接受文件夹，不接受普通文件或符号链接；未开始上传。")
        case .filesAndFolders: L10n.tr("仅接受普通文件或文件夹，不接受符号链接；未开始上传。")
        }
    }
}

/// Finder advertises a dragged item as `public.file-url`, but other sources offer
/// only `public.url`, and the payload arrives either as a URL object or as encoded
/// URL data. Every combination is read before a drop is declared unreadable.
enum UploadDropLoader {
    /// Returns one URL per readable provider. A short result means at least one
    /// provider could not be read, so the caller refuses the whole batch.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard let url = await url(from: provider) else { return urls }
            urls.append(url)
        }
        return urls
    }

    static func url(from provider: NSItemProvider) async -> URL? {
        for identifier in [UTType.fileURL.identifier, UTType.url.identifier]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            let item: NSSecureCoding? = await withCheckedContinuation { (continuation: CheckedContinuation<NSSecureCoding?, Never>) in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    continuation.resume(returning: item)
                }
            }
            if let url = url(from: item) { return url }
        }
        return nil
    }

    static func url(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        switch item {
        case let value as URL: url = value
        case let value as NSURL: url = value as URL
        case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
        default: url = nil
        }
        guard let url, url.isFileURL else { return nil }
        return url
    }
}

/// A dedicated one-time upload target. It stays hit-testable while unavailable so a
/// drop reports why it was refused instead of disappearing without feedback.
struct UploadDropZone: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    let kind: UploadKind
    @State private var targeted = false
    private var acceptsInput: Bool { model.canOperate && model.historyFile == nil }
    private var title: String {
        switch kind {
        case .folders: L10n.tr("拖入文件夹，一次性上传")
        case .files: L10n.tr("拖入文件")
        case .filesAndFolders: L10n.tr("拖入文件或文件夹")
        }
    }
    private var detail: String {
        switch kind {
        case .folders: L10n.tr("保留层级，跳过隐藏项")
        case .files: L10n.tr("仅接受文件")
        case .filesAndFolders: L10n.tr("一次性上传，保留文件夹层级")
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(TASDesign.selected).frame(width: 38, height: 38)
                HStack(spacing: 2) {
                    Image(systemName: "doc.badge.plus")
                    if kind != .files { Image(systemName: "folder.badge.plus") }
                }.font(.system(size: 14, weight: .medium)).foregroundStyle(TASDesign.accent)
            }
            VStack(spacing: 2) {
                Text(title).font(LibraryStyle.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.tr("点击选择")).font(.caption).foregroundStyle(TASDesign.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(targeted ? TASDesign.selected : TASDesign.dropZone, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(targeted ? TASDesign.accent : TASDesign.dropBorder,
                          style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6])))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .opacity(acceptsInput ? 1 : 0.55)
        .onTapGesture { if acceptsInput { model.chooseUpload() } }
        .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: $targeted) { model.acceptUploadDrop($0, kind: kind) }
        .accessibilityElement(children: .combine)
        .accessibilityHint(acceptsInput ? L10n.tr("点击选择上传内容") : L10n.tr("文件库未就绪；请先解锁"))
    }
}
#endif
