import AppKit
import Charts
import PadKit
import SwiftUI

/// The History window: this week's and month's totals, the distance of every day as bars, and the
/// stored sessions by day. A click on a session opens its detail. Read-only: it only issues GETs.
struct HistoryView: View {
  static let windowID = "history"

  let model: HistoryStore
  @State private var selected: Session?

  var body: some View {
    VStack(spacing: 0) {
      if let session = selected {
        SessionDetailView(history: model, session: session) { selected = nil }
      } else {
        HistoryHeader(model: model)
        Divider()
        HistoryContent(model: model) { selected = $0 }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 700)
    .task { await model.reload() }
  }
}

private struct HistoryHeader: View {
  let model: HistoryStore

  var body: some View {
    HStack {
      Text("History").font(.title3.weight(.semibold))
      Spacer()
      if model.load == .loading { ProgressView().controlSize(.small) }
      Button {
        Task { await model.reload() }
      } label: {
        Image(systemName: "arrow.clockwise").accessibilityLabel("Reload")
      }
      .buttonStyle(.borderless)
      .help("Reload")
      .disabled(model.load == .loading)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }
}

private struct HistoryContent: View {
  let model: HistoryStore
  let open: (Session) -> Void

  var body: some View {
    content.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private var content: some View {
    if case .failed(let reason) = model.load {
      HistoryFailure(model: model, reason: reason)
    } else if model.week == nil {
      ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.sessions.isEmpty {
      ContentUnavailableView(
        "No walks yet", systemImage: "figure.walk",
        description: Text("Walks you take on the pad show up here."))
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          PeriodCards(model: model)
          DistanceChart(model: model)
          SessionList(model: model, open: open)
        }
        .padding(20)
      }
    }
  }
}

private struct HistoryFailure: View {
  let model: HistoryStore
  let reason: String

  var body: some View {
    ContentUnavailableView {
      Label("Can't load the history", systemImage: "network.slash")
    } description: {
      Text(reason)
    } actions: {
      HStack {
        Button("Try Again") { Task { await model.reload() } }
          .buttonStyle(.borderedProminent)
        SettingsButton(label: "Open Settings", systemImage: "gearshape")
          .buttonStyle(.bordered)
      }
    }
  }
}

// MARK: - Totals

private struct PeriodCards: View {
  let model: HistoryStore

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      PeriodCard(title: "This week", summary: model.week)
      PeriodCard(title: "This month", summary: model.month)
    }
  }
}

private struct PeriodCard: View {
  let title: String
  let summary: Summary?

  var body: some View {
    let totals =
      summary.map {
        WalkTotals(durationS: $0.durationS, distanceM: $0.distanceM, steps: $0.steps, kcal: $0.kcal)
      } ?? .zero
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      Text(PadFormat.distance(totals.distanceM))
        .font(.title2.weight(.semibold))
        .monospacedDigit()
      Text(walks).font(.caption).foregroundStyle(.secondary)
      Text("\(PadFormat.steps(totals.steps)) steps · \(PadFormat.kcal(totals.kcal))")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  private var walks: String {
    let count = summary?.sessions ?? 0
    let label = count == 1 ? "1 walk" : "\(count) walks"
    return "\(label) · \(PadFormat.duration(summary?.durationS ?? 0))"
  }
}

// MARK: - Chart

private struct DistanceChart: View {
  @Bindable var model: HistoryStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Distance per day").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        Picker("Range", selection: $model.range) {
          ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
      }
      Chart(model.bars(model.range)) { bar in
        BarMark(
          x: .value("Day", bar.date, unit: .day), y: .value("Distance", bar.distanceM / 1000)
        )
        .foregroundStyle(.tint)
      }
      .chartYAxis {
        AxisMarks(position: .leading) { value in
          AxisGridLine()
          AxisValueLabel {
            if let kilometres = value.as(Double.self) { Text("\(kilometres.formatted()) km") }
          }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
          AxisTick()
          AxisValueLabel(format: .dateTime.day().month(.abbreviated))
        }
      }
      .frame(height: 150)
      .overlay {
        if model.isEmpty(model.range) {
          Text("No walks in the last \(model.range.days) days")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("Distance per day, last \(model.range.days) days")
    }
  }
}

// MARK: - Sessions

private struct SessionList: View {
  let model: HistoryStore
  let open: (Session) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Walks").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      ForEach(model.groupedSessions) { day in
        DaySection(day: day, open: open)
      }
      if model.canLoadMore {
        HStack {
          Button("Load older walks") { Task { await model.loadMore() } }
            .buttonStyle(.bordered)
            .disabled(model.isLoadingMore)
          if model.isLoadingMore { ProgressView().controlSize(.small) }
          if let error = model.moreError {
            Text(error).font(.caption).foregroundStyle(.red)
          }
        }
      }
    }
  }
}

private struct DaySection: View {
  let day: SessionDay
  let open: (Session) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.callout.weight(.semibold))
        Spacer()
        Text(
          "\(PadFormat.distance(day.totals.distanceM)) · \(PadFormat.duration(day.totals.durationS))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
      ForEach(day.sessions, id: \.uuid) { session in
        SessionRow(session: session) { open(session) }
      }
    }
  }

  private var title: String {
    let calendar = Calendar.current
    if calendar.isDateInToday(day.day) { return "Today" }
    if calendar.isDateInYesterday(day.day) { return "Yesterday" }
    let date = day.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    let ago = HistoryDates.daysAgo(day.day, now: Date(), calendar: calendar)
    guard ago >= 2 else { return date }
    return "\(date) · \(ago) days ago"
  }
}

private struct SessionRow: View {
  let session: Session
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Text(session.startedAt.formatted(date: .omitted, time: .shortened))
          .frame(width: 64, alignment: .leading)
        Text(PadFormat.duration(session.durationS)).frame(width: 64, alignment: .leading)
        Text(PadFormat.distance(session.distanceM)).frame(width: 70, alignment: .leading)
        Text("\(PadFormat.steps(session.steps)) steps").foregroundStyle(.secondary)
        Spacer()
        Text("\(PadFormat.speed(session.avgSpeedKmh)) km/h").foregroundStyle(.secondary)
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
      }
      .font(.callout)
      .monospacedDigit()
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Opens the History window and brings the accessory app forward.
struct HistoryButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: HistoryView.windowID)
      NSApplication.shared.activate()
    } label: {
      Label("History", systemImage: "chart.bar.xaxis")
    }
  }
}
