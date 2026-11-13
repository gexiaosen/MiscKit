import MiscKitCore
import SwiftUI

/// 设置「功能」页：所有已注册功能 + 各自的唤醒词 + 开关。
///
/// 清单从 `ToolRegistry` 现取、词从 `TriggerDescriptor` 现读，不在这里手写第二张表 ——
/// 工具加一个词，这页自己就多一个 chip；漏登记的功能才会看不见，而那正是该修的错。
struct FeaturesPane: View {
    @Bindable var settings: AppSettings
    @Environment(\.appLanguage) private var appLanguage

    private struct Row: Identifiable {
        let id: ToolID
        let title: String
        let symbol: String
        let words: [String]
        let notes: [String]
    }

    private var rows: [Row] {
        ToolRegistry.shared.tools.map { tool in
            Row(id: tool.id,
                title: tool.title,
                symbol: tool.symbol,
                words: tool.triggers.flatMap(\.keywordWords),
                notes: tool.triggers.compactMap(\.weakHint) + tool.entries)
        }
    }

    var body: some View {
        let _ = appLanguage
        Form {
            Section {
                ForEach(rows) { row in
                    featureRow(row)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func featureRow(_ row: Row) -> some View {
        LabeledContent {
            Toggle(L10n.Common.enable, isOn: binding(for: row.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(row.title)
        } label: {
            VStack(alignment: .leading, spacing: Layout.Spacing.xs) {
                Text(row.title)
                HStack(spacing: Layout.Spacing.xs) {
                    if row.words.isEmpty {
                        word(L10n.Features.noKeywords, dimmed: true)
                    } else {
                        ForEach(row.words, id: \.self) { word($0, dimmed: false) }
                    }
                }
                if !row.notes.isEmpty {
                    Text(row.notes.joined(separator: " · "))
                        .font(Type.meta)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func word(_ text: String, dimmed: Bool) -> some View {
        Text(text)
            .font(Type.meta)
            .foregroundStyle(dimmed ? Theme.decorationOnly : Theme.textBody)
            .padding(.horizontal, Layout.Spacing.s)
            .padding(.vertical, 2)
            .background(Theme.keycapFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 开关只认 `AppSettings.isEnabled` 这一处；视图不许自己比对 `disabledTools` 数组。
    private func binding(for id: ToolID) -> Binding<Bool> {
        Binding(get: { settings.isEnabled(id) },
                set: { settings.setEnabled(id, $0) })
    }
}
