import Charts
import SwiftUI

struct ReadingActivityView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: LibraryStore
    @ObservedObject private var activity: ReadingActivityStore
    var onRead: ((Book) -> Void)?
    @State private var period = 7
    @State private var confirmReset = false

    init(library: LibraryStore, onRead: ((Book) -> Void)? = nil) {
        self.library = library
        self.onRead = onRead
        _activity = ObservedObject(wrappedValue: library.activity)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
            .navigationTitle("阅读记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("清空全部阅读记录？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空阅读记录", role: .destructive) { activity.reset() }
            } message: { Text("阅读和听书时长将永久清空，无法撤销。书籍、进度、划线、笔记与每日目标不会受影响。") }
        }
    }

    private func content(now: Date) -> some View {
        let days = chartDays(now: now)
        let today = activity.totals(day: ReadingActivityCalendar.key(now))
        let total = activity.totals()
        let recent = recentBooks(days: Set(days.map { ReadingActivityCalendar.key($0.date) }))
        return List {
            if let error = activity.persistenceError {
                Section { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ReadingActivityFormat.duration(today.total)).font(.title2.weight(.semibold)).monospacedDigit()
                        Spacer()
                        if activity.goalMinutes > 0, today.total >= Double(activity.goalMinutes * 60) {
                            Label("已达成", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green)
                        }
                    }
                    if activity.goalMinutes > 0 {
                        ProgressView(value: min(1, today.total / Double(activity.goalMinutes * 60)))
                            .accessibilityLabel("今日目标进度")
                            .accessibilityValue("百分之 \(Int(min(100, today.total / Double(activity.goalMinutes * 60) * 100)))")
                    }
                    HStack(spacing: 20) {
                        Label("阅读 \(ReadingActivityFormat.duration(today.reading))", systemImage: "book")
                        Label("听书 \(ReadingActivityFormat.duration(today.listening))", systemImage: "headphones")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
                NavigationLink {
                    ReadingGoalView(activity: activity)
                } label: {
                    LabeledContent("每日目标", value: activity.goalMinutes > 0 ? "\(activity.goalMinutes) 分钟" : "未开启")
                }
            } header: { Text("今天") } footer: { Text("目标合计阅读与听书时长，同一时段不重复累计。") }

            Section {
                Picker("时间范围", selection: $period) {
                    Text("最近 7 天").tag(7)
                    Text("最近 30 天").tag(30)
                }.pickerStyle(.segmented)
                Chart(days) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("分钟", day.reading / 60))
                        .foregroundStyle(by: .value("方式", "阅读"))
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，阅读")
                        .accessibilityValue(ReadingActivityFormat.duration(day.reading))
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("分钟", day.listening / 60))
                        .foregroundStyle(by: .value("方式", "听书"))
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))，听书")
                        .accessibilityValue(ReadingActivityFormat.duration(day.listening))
                }
                .chartForegroundStyleScale(["阅读": Color.accentColor, "听书": Color.orange])
                .chartYScale(domain: 0...max(5, (days.map { ($0.reading + $0.listening) / 60 }.max() ?? 0) * 1.15))
                .chartYAxisLabel("分钟")
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: period == 7 ? 1 : 7)) { _ in
                        AxisValueLabel(format: .dateTime.day())
                    }
                }
                .frame(height: 190).padding(.vertical, 8)
                LabeledContent("这 \(period) 天", value: ReadingActivityFormat.duration(days.reduce(0) { $0 + $1.reading + $1.listening }))
                LabeledContent("连续阅读", value: "\(activity.streak(now: now)) 天")
            } header: { Text("阅读趋势") } footer: { Text("每天累计至少 1 分钟算作一个阅读日；今天尚未开始时，连续天数从昨天计算。") }

            if !recent.isEmpty {
                Section("最近阅读 · \(period) 天") {
                    ForEach(recent.prefix(20)) { item in
                        Button {
                            if item.book.deletedAt == nil { onRead?(item.book) }
                        } label: {
                            HStack(spacing: 12) {
                                BookCover(title: item.book.title, url: library.coverURL(for: item.book))
                                    .frame(width: 38, height: 54).clipShape(.rect(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.book.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(item.book.deletedAt == nil ? ReadingActivityFormat.duration(item.total) : "最近删除 · \(ReadingActivityFormat.duration(item.total))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if item.book.deletedAt == nil, onRead != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(item.book.deletedAt != nil || onRead == nil)
                    }
                }
            }

            Section {
                LabeledContent("阅读", value: ReadingActivityFormat.duration(total.reading))
                LabeledContent("听书", value: ReadingActivityFormat.duration(total.listening))
                LabeledContent("记录天数", value: "\(Set(activity.records.filter { $0.total > 0 }.map(\.day)).count) 天")
            } header: { Text("累计") } footer: {
                Text("从本版本开始记录，不补算历史。前台正文停留计入阅读；打开面板、切入后台或超过 5 分钟无翻页 / 点击会暂停阅读计时。播放朗读时只计听书，暂停或停止后不再计听书。长时间无运行回调不追补，以免把系统挂起算作阅读。数据仅保存在本机，永久删除原书后只保留匿名时长。")
            }
            Section { Button("清空阅读记录", role: .destructive) { confirmReset = true } }
        }
    }

    private func chartDays(now: Date) -> [ActivityChartDay] {
        let calendar = ReadingActivityCalendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<period).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let total = activity.totals(day: ReadingActivityCalendar.key(date, calendar: calendar))
            return .init(date: date, reading: total.reading, listening: total.listening)
        }
    }

    private func recentBooks(days: Set<String>) -> [ActivityRecentBook] {
        let grouped = Dictionary(grouping: activity.records.filter { days.contains($0.day) && $0.bookID != nil }, by: \.bookID)
        let booksByID = Dictionary((library.books + library.deletedBooks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return grouped.compactMap { id, records in
            guard let id, let book = booksByID[id], let latest = records.map(\.lastActivityAt).max() else { return nil }
            return ActivityRecentBook(book: book, total: records.reduce(0) { $0 + $1.total }, latest: latest)
        }.sorted { $0.latest == $1.latest ? $0.id.uuidString < $1.id.uuidString : $0.latest > $1.latest }
    }
}

private struct ActivityChartDay: Identifiable {
    let date: Date
    let reading: Double
    let listening: Double
    var id: Date { date }
}

private struct ActivityRecentBook: Identifiable {
    let book: Book
    let total: Double
    let latest: Date
    var id: UUID { book.id }
}

struct ReadingGoalView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var activity: ReadingActivityStore
    @State private var enabled: Bool
    @State private var minutes: Int

    init(activity: ReadingActivityStore) {
        self.activity = activity
        _enabled = State(initialValue: activity.goalMinutes > 0)
        _minutes = State(initialValue: max(5, activity.goalMinutes))
    }

    var body: some View {
        Form {
            Section {
                Toggle("开启每日目标", isOn: $enabled)
                if enabled {
                    Stepper("每天 \(minutes) 分钟", value: $minutes, in: 5...240, step: 5)
                }
            } footer: { Text("阅读与听书都计入目标。关闭目标不会删除统计，也不会发送通知。") }
            if let error = activity.persistenceError { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("每日目标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { if activity.setGoal(minutes: enabled ? minutes : 0) { dismiss() } } } }
    }
}

struct ReadingGoalSummary: View {
    @ObservedObject var activity: ReadingActivityStore
    let onOpen: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let total = activity.totals(day: ReadingActivityCalendar.key(context.date)).total
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("今日阅读", systemImage: "chart.bar.xaxis") .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(ReadingActivityFormat.duration(total)).font(.subheadline.monospacedDigit())
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    if activity.goalMinutes > 0 {
                        ProgressView(value: min(1, total / Double(activity.goalMinutes * 60)))
                        Text(total >= Double(activity.goalMinutes * 60) ? "已完成今日 \(activity.goalMinutes) 分钟目标" : "每日目标 \(activity.goalMinutes) 分钟 · 阅读与听书合计")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            }.buttonStyle(.plain)
        }
    }
}

struct BookActivitySummary: View {
    @ObservedObject var activity: ReadingActivityStore
    let bookID: UUID
    var body: some View {
        let total = activity.totals(bookID: bookID)
        LabeledContent("累计阅读", value: ReadingActivityFormat.duration(total.reading))
        LabeledContent("累计听书", value: ReadingActivityFormat.duration(total.listening))
    }
}
