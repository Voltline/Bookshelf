import SwiftUI

struct OnlineBookDetailView: View {
    let result: OnlineBookResult
    @State private var details: OnlineBookDetails?
    @State private var isLoading = true
    @State private var failedToLoad = false

    private var displayed: OnlineBookDetails { details ?? .preview(for: result) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let rating = displayed.rating {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(.orange)
                        Text(rating).font(.title3.weight(.semibold))
                        if let count = displayed.ratingCount {
                            Text("\(count.formatted()) 人评价")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                if !displayed.facts.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("书籍信息").font(.headline)
                        ForEach(displayed.facts) { fact in
                            LabeledContent(fact.label, value: fact.value)
                            if fact.id != displayed.facts.last?.id { Divider() }
                        }
                    }
                    .padding(18)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }

                if !displayed.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("标签").font(.headline)
                        Text(displayed.tags.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if let summary = displayed.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("内容简介").font(.headline)
                        Text(summary).font(.body).lineSpacing(5)
                    }
                }

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在补充原站详情…").foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else if failedToLoad {
                    HStack(spacing: 10) {
                        Text("暂时无法加载更多详情，仍可前往原站查看。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重试") { Task { await loadDetails() } }
                            .font(.footnote)
                    }
                }

                Text("书籍资料来自\(result.source.rawValue)，以原站为准。")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("书籍详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Link(destination: result.url) {
                Label("前往网站查看", systemImage: "arrow.up.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
        .task(id: result.id) { await loadDetails() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            OnlineBookCover(url: result.coverURL, source: result.source, width: 104, height: 152)
            VStack(alignment: .leading, spacing: 9) {
                Text(result.source.rawValue)
                    .font(.caption).foregroundStyle(.tint)
                Text(result.title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let author = displayed.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadDetails() async {
        isLoading = true
        failedToLoad = false
        do {
            let loaded = try await OnlineBookDetailService.fetch(for: result)
            guard !Task.isCancelled else { return }
            details = loaded
        } catch {
            guard !Task.isCancelled else { return }
            failedToLoad = true
        }
        isLoading = false
    }
}
