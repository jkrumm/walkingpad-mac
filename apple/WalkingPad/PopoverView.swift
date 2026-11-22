import AppKit
import Charts
import PadKit
import SwiftUI

/// The popover: the state, the current speed large, Start/Stop, the speed stepper and presets,
/// the walk in progress and today's totals.
struct PopoverView: View {
  let store: PadStore

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PopoverHeader(store: store)
      if store.phase.hasPad {
        SpeedPanel(store: store)
        ControlPanel(store: store)
        if let session = store.status?.currentSession {
          TotalsSection(title: "This walk", totals: WalkTotals(session))
        }
      } else {
        PhaseNotice(store: store)
      }
      if let status = store.status {
        TodaySection(totals: WalkTotals(today: status))
      }
      Divider()
      PopoverFooter()
    }
    .padding(16)
    .frame(width: 320, alignment: .leading)
    .onAppear { store.setPopoverOpen(true) }
    .onDisappear { store.setPopoverOpen(false) }
  }
}

private struct PopoverHeader: View {
  let store: PadStore

  var body: some View {
    let content = MenuBarContent(phase: store.phase, status: store.status, speed: 0)
    HStack(spacing: 10) {
      Image(systemName: content.symbol)
        .font(.title2)
        .foregroundStyle(store.phase.hasPad ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.headline)
        if let device = store.status?.device, store.phase.hasPad, !device.name.isEmpty {
          Text(device.name).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  /// The command in flight speaks for the belt until the host reports the new state.
  private var title: String {
    switch store.command {
    case .start: PadPhase.starting.title
    case .stop: PadPhase.stopping.title
    case .speed, nil: store.phase.title
    }
  }
}

/// The current speed, the stepper and a sparkline of the last minute.
private struct SpeedPanel: View {
  let store: PadStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(PadFormat.speed(store.displayedSpeed))
          .font(.system(size: 52, weight: .semibold, design: .rounded))
          .foregroundStyle(store.phase.isMoving ? .primary : .tertiary)
          .monospacedDigit()
          .contentTransition(.numericText())
        Text("km/h").font(.title3).foregroundStyle(.secondary)
        Spacer()
        StepperButtons(store: store)
      }
      if let samples = store.status?.currentSession?.samples, samples.count > 1,
        store.phase.isMoving
      {
        SpeedSparkline(samples: samples)
      }
      PresetRow(store: store)
    }
  }
}

private struct StepperButtons: View {
  let store: PadStore

  var body: some View {
    HStack(spacing: 6) {
      Button {
        Task { await store.changeSpeed(by: -1) }
      } label: {
        Image(systemName: "minus").frame(width: 18, height: 18)
      }
      .disabled(!store.canChangeSpeed || store.displayedSpeed <= SpeedRange.minimum)
      .help("Slower by \(PadFormat.speed(SpeedRange.step)) km/h")
      Button {
        Task { await store.changeSpeed(by: 1) }
      } label: {
        Image(systemName: "plus").frame(width: 18, height: 18)
      }
      .disabled(!store.canChangeSpeed || store.displayedSpeed >= SpeedRange.maximum)
      .help("Faster by \(PadFormat.speed(SpeedRange.step)) km/h")
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.circle)
    .controlSize(.large)
  }
}

/// Quick speeds: they set the speed while walking and start the belt at it when it stands.
private struct PresetRow: View {
  let store: PadStore

  var body: some View {
    HStack(spacing: 6) {
      ForEach(SpeedRange.presets, id: \.self) { speed in
        Button("\(PadFormat.speed(speed))") {
          Task {
            if store.phase == .active {
              await store.setSpeed(speed)
            } else {
              await store.start(speedKmh: speed)
            }
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(!(store.canChangeSpeed || store.canStart))
  }
}

private struct SpeedSparkline: View {
  let samples: [Sample]

  /// A band around the minute's speeds, so a change of half a km/h is visible.
  private var domain: ClosedRange<Double> {
    let speeds = samples.map(\.speedKmh)
    let low = max((speeds.min() ?? 0) - 1, 0)
    return low...max((speeds.max() ?? 0) + 0.5, low + 1)
  }

  var body: some View {
    Chart(Array(samples.enumerated()), id: \.offset) { item in
      AreaMark(x: .value("Time", item.element.ts), y: .value("km/h", item.element.speedKmh))
        .foregroundStyle(.tint.opacity(0.15))
        .interpolationMethod(.monotone)
      LineMark(x: .value("Time", item.element.ts), y: .value("km/h", item.element.speedKmh))
        .foregroundStyle(.tint)
        .interpolationMethod(.monotone)
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartYScale(domain: domain)
    .frame(height: 36)
    .clipped()
    .accessibilityLabel("Speed over the last minute")
  }
}

/// Start, Stop, or the progress of the command in flight.
private struct ControlPanel: View {
  let store: PadStore

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      primaryButton
        .controlSize(.extraLarge)
        .frame(maxWidth: .infinity)
      if let error = store.commandError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder private var primaryButton: some View {
    if store.command == .start {
      progress("Starting — the belt ramps up")
    } else if store.command == .stop || store.phase == .stopping {
      progress("Stopping")
    } else if store.canStop {
      Button(role: .destructive) {
        Task { await store.stop() }
      } label: {
        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .keyboardShortcut(.space, modifiers: [])
    } else {
      Button {
        Task { await store.start() }
      } label: {
        Label("Start at \(PadFormat.speed(store.startSpeed)) km/h", systemImage: "play.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!store.canStart)
      .keyboardShortcut(.space, modifiers: [])
    }
  }

  private func progress(_ text: String) -> some View {
    Button {
    } label: {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(text)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .disabled(true)
  }
}

/// No pad to control: what is wrong and the one action that helps.
private struct PhaseNotice: View {
  let store: PadStore

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let advice = store.phase.advice {
        Text(advice)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      switch store.phase {
      case .unconfigured, .unauthorized:
        SettingsButton(label: "Open Settings", systemImage: "gearshape")
          .buttonStyle(.borderedProminent)
      case .hostUnreachable, .padDisconnected:
        Button("Try Again") { Task { await store.refresh() } }
          .buttonStyle(.bordered)
      default:
        ProgressView().controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct PopoverFooter: View {
  var body: some View {
    HStack(spacing: 8) {
      HistoryButton()
      SettingsButton(label: "Settings", systemImage: "gearshape")
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
  }
}

/// Opens the Settings window and brings the accessory app forward, so the window is not left
/// behind the frontmost app.
struct SettingsButton: View {
  let label: String
  let systemImage: String
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: SettingsView.windowID)
      NSApplication.shared.activate()
    } label: {
      Label(label, systemImage: systemImage)
    }
  }
}
