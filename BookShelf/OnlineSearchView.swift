import SwiftUI

struct OnlineSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchedTerm = ""
    @State private var source: OnlineBookSource = .all
    @State private var results: [OnlineBookResult] = []
    @State private var failures: [String] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("搜索网站", selection: $source) {
                    ForEach(OnlineBookSource.allCases) { site in Text(site.rawValue).tag(site) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

                List {
                    if isSearching {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在搜索…").foregroundStyle(.secondary)
                        }
                    }
                    if hasSearched && !isSearching && results.isEmpty && failures.isEmpty {
                        ContentUnavailableView.search(text: searchedTerm)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(results) { result in
                        NavigationLink {
                            OnlineBookDetailView(result: result)
                        } label: {
                            HStack(spacing: 12) {
                                OnlineBookCover(url: result.coverURL, source: result.source)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(result.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    HStack(spacing: 8) {
                                        Text(result.source.rawValue).font(.caption).foregroundStyle(.tint)
                                        if !result.detail.isEmpty {
                                            Text(result.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    if !result.summary.isEmpty {
                                        Text(result.summary)
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if !failures.isEmpty {
                        Section {
                            ForEach(failures, id: \.self) { failure in
                                Label(failure, systemImage: "wifi.exclamationmark")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if hasSearched {
                        Section {
                            ForEach(source.searchSources) { site in
                                if let url = site.searchPage(for: searchedTerm) {
                                    Link("在\(site.rawValue)继续搜索", destination: url)
                                }
                            }
                        } footer: {
                            Text("仅显示原站书目信息和链接，不提供电子书文件或正文。")
                        }
                    }
                }
                .overlay {
                    if !hasSearched {
                        ContentUnavailableView {
                            Label("搜索在线书目", systemImage: "book.magnifyingglass")
                        } description: {
                            Text("输入书名或作者，点击键盘上的“搜索”。结果将在原网站打开。")
                        }
                    }
                }
            }
            .navigationTitle("在线找书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .searchable(text: $query, prompt: "书名或作者")
            .onSubmit(of: .search) { performSearch() }
            .onChange(of: source) { _, _ in if hasSearched { performSearch() } }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func performSearch() {
        searchTask?.cancel()
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !term.isEmpty else {
            results = []
            failures = []
            hasSearched = false
            isSearching = false
            searchedTerm = ""
            return
        }
        searchedTerm = term
        results = []
        failures = []
        hasSearched = true
        isSearching = true
        let selectedSources = source.searchSources
        searchTask = Task {
            let outcome = await OnlineBookSearch.search(term, sources: selectedSources)
            guard !Task.isCancelled else { return }
            results = outcome.results
            failures = outcome.failures
            isSearching = false
        }
    }
}

struct OnlineBookCover: View {
    let url: URL?
    let source: OnlineBookSource
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?

    init(url: URL?, source: OnlineBookSource, width: CGFloat = 64, height: CGFloat = 92) {
        self.url = url
        self.source = source
        self.width = width
        self.height = height
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "book.closed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            image = nil
            guard let url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            if source == .douban {
                request.setValue("https://book.douban.com/", forHTTPHeaderField: "Referer")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.mimeType?.hasPrefix("image/") == true,
                  data.count < 5_000_000,
                  let decoded = UIImage(data: data),
                  !Task.isCancelled else { return }
            image = decoded
        }
        .accessibilityHidden(true)
    }
}
