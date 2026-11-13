import MiscKitCore
import SwiftUI

/// 设置「网址」页：Quicklink 的完整增删改。
/// 编辑区就在这一页里，不上弹窗 —— 整个 App 只有面板和设置两个窗口。
struct QuicklinkPane: View {
    @Environment(\.appLanguage) private var appLanguage
    @State private var store = QuicklinkStore.shared
    @State private var editingID: UUID?
    @State private var keyword = ""
    @State private var title = ""
    @State private var template = ""
    @State private var errorText: String?

    var body: some View {
        let _ = appLanguage
        Form {
            Section {
                if store.links.isEmpty {
                    Text(L10n.Quicklink.empty)
                        .foregroundStyle(Theme.secondaryText)
                }
                ForEach(store.links) { link in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                            Text(link.title)
                            Text("\(link.keyword)  →  \(link.template)")
                                .font(Type.meta)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: Layout.Spacing.s)
                        Button(L10n.Common.edit) { load(link) }
                            .buttonStyle(.link)
                        Button {
                            store.remove(id: link.id)
                            if editingID == link.id { reset() }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.Quicklink.deleteA11y(link.title))
                    }
                }
            } header: {
                Text(L10n.Quicklink.savedHeader)
            }

            Section {
                TextField(L10n.Quicklink.keywordField, text: $keyword)
                TextField(L10n.Quicklink.nameField, text: $title)
                TextField(L10n.Quicklink.templateField, text: $template)
                if let errorText {
                    Text(errorText)
                        .font(Type.meta)
                        .foregroundStyle(Theme.errorText)
                }
                HStack(spacing: Layout.Spacing.s) {
                    Button(editingID == nil ? L10n.Common.add : L10n.Common.save) { commit() }
                        .keyboardShortcut(.defaultAction)
                    if editingID != nil {
                        Button(L10n.Common.cancel) { reset() }
                    }
                }
            } header: {
                Text(editingID == nil ? L10n.Quicklink.sectionNew : L10n.Common.edit)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func load(_ link: Quicklink) {
        editingID = link.id
        keyword = link.keyword
        title = link.title
        template = link.template
        errorText = nil
    }

    private func reset() {
        editingID = nil
        keyword = ""
        title = ""
        template = ""
        errorText = nil
    }

    private func commit() {
        let link = Quicklink(id: editingID ?? UUID(), keyword: keyword,
                             title: title, template: template)
        do {
            if editingID == nil {
                try store.add(link)
            } else {
                try store.update(link)
            }
            reset()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
