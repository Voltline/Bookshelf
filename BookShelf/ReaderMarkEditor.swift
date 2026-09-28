import SwiftUI

struct ReaderMarkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var color: ReaderMark.Color
    @State private var confirmDeletion = false

    let mark: ReaderMark
    let isSaved: Bool
    let onSave: (ReaderMark) -> Bool
    let onDelete: () -> Bool
    let onGoTo: () -> Void

    init(
        mark: ReaderMark,
        isSaved: Bool,
        onSave: @escaping (ReaderMark) -> Bool,
        onDelete: @escaping () -> Bool,
        onGoTo: @escaping () -> Void
    ) {
        self.mark = mark
        self.isSaved = isSaved
        self.onSave = onSave
        self.onDelete = onDelete
        self.onGoTo = onGoTo
        _note = State(initialValue: mark.note)
        _color = State(initialValue: mark.color)
    }

    var body: some View {
        Form {
            Section("划线内容") {
                Text(mark.excerpt)
                    .textSelection(.enabled)
                Text(mark.chapter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("颜色") {
                Picker("划线颜色", selection: $color) {
                    ForEach(ReaderMark.Color.allCases) { option in
                        Text(option.name).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("笔记") {
                TextField("写下想法（可选）", text: $note, axis: .vertical)
                    .lineLimit(4...12)
            }
            if isSaved {
                Section {
                    Button("跳转到原文", systemImage: "arrow.turn.down.right") {
                        onGoTo()
                        dismiss()
                    }
                    Button("删除划线与笔记", role: .destructive) { confirmDeletion = true }
                }
            }
        }
        .navigationTitle(isSaved ? "编辑划线" : "添加笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    var updated = mark
                    updated.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.color = color
                    if onSave(updated) { dismiss() }
                }
            }
        }
        .confirmationDialog("删除这条划线和笔记？", isPresented: $confirmDeletion) {
            Button("删除", role: .destructive) {
                if onDelete() { dismiss() }
            }
        }
    }
}
