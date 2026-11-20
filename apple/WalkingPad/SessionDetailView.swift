import Charts
import PadKit
import SwiftUI

/// One session: its totals and the speed over the walk.
struct SessionDetailView: View {
  let history: HistoryStore
  let session: Session
  let back: () -> Void

  private enum Samples {
    case loading
    case loaded([Sample])
    case failed(String)
  }

  @State private var samples = Samples.loading

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button(action: back) { Label("History", systemImage: "chevron.left") }
          .buttonStyle(.borderless)
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 2) {
            Text(session.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
              .font(.title3.weight(.semibold))
            Text(timeRange).font(.callout).foregroundStyle(.secondary)
          }
          TotalsRow(
            totals: WalkTotals(
              durationS: session.durationS, distanceM: session.distanceM, steps: session.steps,
              kcal: session.kcal))
          DetailFacts(session: session)
          SpeedChart(samples: samples)
        }
        .padding(20)
      }
    }
    .task { await load() }
  }

  private var timeRange: String {
    let start = session.startedAt.formatted(date: .omitted, time: .shortened)
    guard let end = session.endedAt else { return "\(start) · in progress" }
    return "\(start) to \(end.formatted(date: .omitted, time: .shortened))"
  }

  private func load() async {
    do {
      samples = .loaded(try await history.detail(uuid: session.uuid).samples)
    } catch {
      guard !PadPhase.isCancellation(error) else { return }
      samples = .failed(PadPhase.describe(error))
    }
  }

  private struct SpeedChart: View {
    let samples: Samples

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("Speed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        switch samples {
        case .loading:
          ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 140)
        case .failed(let reason):
          Label(reason, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 140)
        case .loaded(let all):
          chart(SampleSeries.downsample(all, maxPoints: 300))
        }
      }
    }

    @ViewBuilder private func chart(_ points: [Sample]) -> some View {
      if points.isEmpty {
        Text("No samples stored for this walk.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 140)
      } else {
        Chart(Array(points.enumerated()), id: \.offset) { item in
          AreaMark(x: .value("Time", item.element.ts), y: .value("km/h", item.element.speedKmh))
            .foregroundStyle(.tint.opacity(0.15))
          LineMark(x: .value("Time", item.element.ts), y: .value("km/h", item.element.speedKmh))
            .foregroundStyle(.tint)
        }
        .chartYScale(domain: 0...max(6, (points.map(\.speedKmh).max() ?? 0) + 0.5))
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 5)) {
            AxisValueLabel(format: .dateTime.hour().minute())
          }
        }
        .frame(height: 160)
        .accessibilityLabel("Speed over the walk")
      }
    }
  }
}

private struct DetailFacts: View {
  let session: Session

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
      GridRow {
        fact("Average speed", "\(PadFormat.speed(session.avgSpeedKmh)) km/h")
        fact("Top speed", "\(PadFormat.speed(session.maxSpeedKmh)) km/h")
        fact("Pauses", String(session.pauseCount))
        fact("Argo", session.syncedAt == nil ? "Not synced" : "Synced")
      }
    }
  }

  private func fact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(.callout.weight(.semibold)).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}
