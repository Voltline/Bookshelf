import SwiftUI

struct CollectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    var onSelect: ((UUID) -> Void)?
    @State private var editor: CollectionEditorRequest?
    @State private var pendingDeletion: BookCollection?

    var body: some View {
        let counts = library.books.reduce(into: [UUID: Int]()) { counts, book in
            for id in Set(book.collectionIDs) { counts[id, default: 0] += 1 }
        }
        return NavigationStack {
            List {
                ForEach(library.collections) { collection in
                    Button {
                        if let onSelect { onSelect(collection.id); dismiss() }
                        else { editor = .init(collection: collection) }
                    } label: {
                        HStack {
                            Label(collection.name, systemImage: "folder")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(counts[collection.id, default: 0]) 本")
                                .foregroundStyle(.secondary).font(.subheadline)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("删除", role: .destructive) { pendingDeletion = collection }
                        Button("重命名") { editor = .init(collection: collection) }.tint(.blue)
                    }
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") { editor = .init(collection: collection) }
                        Button("删除书单", systemImage: "trash", role: .destructive) { pendingDeletion = collection }
                    }
                }
            }
            .overlay {
                if library.collections.isEmpty {
                    ContentUnavailableView("还没有书单", systemImage: "folder", description: Text("按系列、主题或阅读计划整理书籍，一本书可以加入多个书单。"))
                }
            }
            .navigationTitle("我的书单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("新建", systemImage: "folder.badge.plus") { editor = .init(collection: nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .sheet(item: $editor) { request in CollectionNameEditor(library: library, collection: request.collection) }
            .confirmationDialog("删除书单“\(pendingDeletion?.name ?? "")”？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("删除书单", role: .destructive) {
                    if let pendingDeletion { library.deleteCollection(pendingDeletion) }
                    pendingDeletion = nil
                }
            } message: { Text("只删除书单，书籍和阅读进度不会受影响。") }
            .libraryErrorAlert(library)
        }
    }
}

private struct CollectionEditorRequest: Identifiable {
    let id = UUID()
    var collection: BookCollection?
}

struct CollectionNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    let collection: BookCollection?
    @State private var name: String
    @FocusState private var focused: Bool

    init(library: LibraryStore, collection: BookCollection? = nil) {
        self.library = library
        self.collection = collection
        _name = State(initialValue: collection?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("书单名称", text: $name).focused($focused).submitLabel(.done).onSubmit(save)
            }
            .navigationTitle(collection == nil ? "新建书单" : "重命名书单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
            .libraryErrorAlert(library)
        }
        .presentationDetents([.medium])
    }

    private func save() {
        if library.saveCollection(id: collection?.id, name: name) { dismiss() }
    }
}

struct BookCollectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    let book: Book
    @State private var selection: Set<UUID>
    @State private var showCreate = false

    init(book: Book, library: LibraryStore) {
        self.book = book; self.library = library
        _selection = State(initialValue: Set(book.collectionIDs))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.collections) { collection in
                        Button {
                            if selection.contains(collection.id) { selection.remove(collection.id) }
                            else { selection.insert(collection.id) }
                        } label: {
                            HStack {
                                Text(collection.name).foregroundStyle(.primary)
                                Spacer()
                                if selection.contains(collection.id) { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.contains(collection.id) ? .isSelected : [])
                    }
                    Button("新建书单", systemImage: "folder.badge.plus") { showCreate = true }
                } header: { Text(book.title) } footer: { Text("可以选择多个书单。取消勾选只会移出书单，不会删除书籍。") }
            }
            .navigationTitle("加入书单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { if library.setCollections(selection, for: book.id) { dismiss() } }
                }
            }
            .sheet(isPresented: $showCreate) { CollectionNameEditor(library: library) }
            .libraryErrorAlert(library)
        }
    }
}

struct RecentlyDeletedView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    @State private var pendingDeletion: Book?
    @State private var showEmptyConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if !library.deletedBooks.isEmpty {
                    Section {
                        ForEach(library.deletedBooks) { book in
                            HStack(spacing: 12) {
                                BookCover(title: book.title, url: library.coverURL(for: book))
                                    .frame(width: 42, height: 60).clipShape(.rect(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(book.title).lineLimit(2)
                                    if let date = book.deletedAt {
                                        Text("删除于 \(date.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                                Menu {
                                    Button("恢复到书架", systemImage: "arrow.uturn.backward") { library.restore(book) }
                                    Button("永久删除", systemImage: "trash", role: .destructive) { pendingDeletion = book }
                                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
                                .accessibilityLabel("管理《\(book.title)》")
                            }
                            .swipeActions(edge: .leading) {
                                Button("恢复") { library.restore(book) }.tint(.green)
                            }
                            .swipeActions {
                                Button("永久删除", role: .destructive) { pendingDeletion = book }
                            }
                        }
                    } footer: { Text("书籍会一直保留，直到你手动永久删除。恢复时会保留进度、书单、划线与笔记。") }
                }
            }
            .overlay {
                if library.deletedBooks.isEmpty { ContentUnavailableView("没有最近删除的书籍", systemImage: "trash", description: Text("从书架删除的书籍会先保留在这里。")) }
            }
            .navigationTitle("最近删除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空", role: .destructive) { showEmptyConfirmation = true }.disabled(library.deletedBooks.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("永久删除《\(pendingDeletion?.title ?? "")》？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("永久删除", role: .destructive) {
                    if let pendingDeletion { library.permanentlyDelete(pendingDeletion) }
                    pendingDeletion = nil
                }
            } message: { Text("书籍文件、阅读进度和笔记将从本机移除，无法撤销。") }
            .confirmationDialog("清空最近删除？", isPresented: $showEmptyConfirmation, titleVisibility: .visible) {
                Button("永久删除全部 \(library.deletedBooks.count) 本书", role: .destructive) {
                    for book in library.deletedBooks { if !library.permanentlyDelete(book) { break } }
                }
            } message: { Text("所有已删除书籍及其笔记将永久移除，无法撤销。") }
            .libraryErrorAlert(library)
        }
    }
}

extension View {
    func libraryErrorAlert(_ library: LibraryStore) -> some View {
        alert("无法完成操作", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "请重试。") }
    }
}
