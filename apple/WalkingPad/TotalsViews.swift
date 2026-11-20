import PadKit
import SwiftUI

/// Time, distance, steps and kcal in one row.
struct TotalsSection: View {
  let title: String
  let totals: WalkTotals

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      TotalsRow(totals: totals)
    }
  }
}

struct TotalsRow: View {
  let totals: WalkTotals

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14) {
      GridRow {
        figure(PadFormat.duration(totals.durationS), "Time")
        figure(PadFormat.distance(totals.distanceM), "Distance")
        figure(PadFormat.steps(totals.steps), "Steps")
        figure(PadFormat.kcal(totals.kcal), "Energy")
      }
    }
  }

  private func figure(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

/// Today's totals next to a ring that fills toward the daily distance goal.
struct TodaySection: View {
  /// The goal the Raycast extension's rings used.
  static let distanceGoalM = 5000.0

  let totals: WalkTotals

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Today").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      HStack(spacing: 12) {
        ProgressRing(progress: totals.distanceM / Self.distanceGoalM)
          .frame(width: 38, height: 38)
          .help(
            "\(PadFormat.distance(totals.distanceM)) of \(PadFormat.distance(Self.distanceGoalM))")
        TotalsRow(totals: totals)
      }
    }
  }
}

struct ProgressRing: View {
  let progress: Double

  var body: some View {
    ZStack {
      Circle().stroke(.quaternary, lineWidth: 6)
      Circle()
        .trim(from: 0, to: min(max(progress, 0), 1))
        .stroke(.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(3)
    .accessibilityLabel("Daily distance goal")
    .accessibilityValue("\(Int((min(progress, 1) * 100).rounded())) percent")
  }
}
