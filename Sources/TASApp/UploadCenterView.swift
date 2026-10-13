#if os(macOS)
import SwiftUI
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
                Text(L10n.tr("文件夹保留名称和层级；跳过隐藏项及空目录，不加入持续同步。同名文件可确认保存为新版本。"))
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

struct UploadDropZone: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @EnvironmentObject private var model: AppModel
    let kind: UploadKind
    @State private var targeted = false
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                Image(systemName: "doc.badge.plus")
                if kind == .filesAndFolders { Image(systemName: "folder.badge.plus") }
            }
            .font(.title2).foregroundStyle(TASDesign.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .folders ? L10n.tr("拖入文件夹，一次性上传") : kind == .files ? L10n.tr("将文件拖到这里") : L10n.tr("将文件或文件夹拖到这里"))
                    .font(LibraryStyle.body)
                Text(kind == .folders ? L10n.tr("保留目录层级；跳过隐藏项，不保存空目录，不加入持续同步。") : kind == .files ? L10n.tr("仅接受普通文件") : L10n.tr("一次性上传，不添加同步目录"))
                    .font(LibraryStyle.helper).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, minHeight: 64)
        .background(targeted ? TASDesign.selected : TASDesign.dropZone, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? TASDesign.accent : TASDesign.dropBorder, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6])))
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { model.acceptUploadDrop($0, kind: kind) }
        .accessibilityElement(children: .combine)
        .disabled(!model.canOperate || model.historyFile != nil)
    }
}
#endif
