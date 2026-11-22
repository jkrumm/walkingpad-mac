import KeyboardShortcuts
import PadKit
import ServiceManagement
import SwiftUI

/// The Settings window: host connection, start speed, hotkeys, menu bar values, launch at login.
struct SettingsView: View {
  static let windowID = "settings"

  @Bindable var model: SettingsModel
  /// Whether to ask KeyboardShortcuts which shortcuts could not be registered; the snapshot build
  /// runs no hotkey listener, so it would flag every one.
  var checksHotkeys = true

  var body: some View {
    Form {
      HostSection(model: model)
      Section {
        LabeledContent("Start speed") {
          HStack(spacing: 8) {
            Text("\(PadFormat.speed(model.startSpeed)) km/h").monospacedDigit()
            Stepper(
              "Start speed",
              value: Binding(get: { model.startSpeed }, set: { model.setStartSpeed($0) }),
              in: SpeedRange.minimum...SpeedRange.maximum, step: SpeedRange.step
            )
            .labelsHidden()
          }
        }
        if let note = model.startSpeedNote {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text("Walking")
      } footer: {
        Text("Start uses this speed. It is also saved on the pad, for starts from its remote.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HotkeySection(checks: checksHotkeys)
      Section {
        MenuBarToggle(model: model, value: .speed, title: "Speed")
        MenuBarToggle(model: model, value: .time, title: "Time")
        MenuBarToggle(model: model, value: .distance, title: "Distance")
        MenuBarToggle(model: model, value: .steps, title: "Steps")
      } header: {
        Text("Menu bar")
      } footer: {
        Text(
          "Shown while walking. When the belt stands, the title shows today's distance and steps."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Section("General") {
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { model.loginItem.isOn }, set: { model.setLaunchAtLogin($0) })
        )
        if let note = model.loginItem.note {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        if model.loginItem == .requiresApproval {
          Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        if let error = model.loginItemError {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
  }
}

private struct MenuBarToggle: View {
  @Bindable var model: SettingsModel
  let value: MenuBarValues
  let title: String

  var body: some View {
    Toggle(
      title,
      isOn: Binding(
        get: { model.menuBarValues.contains(value) },
        set: { model.setMenuBar(value, shown: $0) })
    )
  }
}

/// The three global shortcuts, a warning under one that Carbon could not register, and a way back
/// to the defaults after a shortcut was cleared.
private struct HotkeySection: View {
  let checks: Bool
  @State private var blocked: Set<String> = []
  @State private var isDefault = true

  private static let rows: [(title: String, name: KeyboardShortcuts.Name)] = [
    ("Start or stop", .toggleBelt), ("Faster", .speedUp), ("Slower", .speedDown),
  ]

  var body: some View {
    Section {
      ForEach(Self.rows, id: \.name) { row in
        KeyboardShortcuts.Recorder(row.title, name: row.name)
        if blocked.contains(row.name.rawValue),
          let shortcut = KeyboardShortcuts.getShortcut(for: row.name)
        {
          Text(
            verbatim: "\(shortcut) could not be registered: another app probably holds it. "
              + "Record a different shortcut."
          )
          .font(.caption).foregroundStyle(.red)
        }
      }
      HStack {
        Spacer()
        Button("Reset to defaults") { KeyboardShortcuts.reset(KeyboardShortcuts.Name.all) }
          .disabled(isDefault)
      }
    } header: {
      Text("Hotkeys")
    } footer: {
      Text("Global: they work in every app. A shortcut another app already holds cannot be used.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .onAppear(perform: refresh)
    .onReceive(
      NotificationCenter.default.publisher(
        for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")),
      perform: { _ in refresh() })
  }

  private func refresh() {
    isDefault = KeyboardShortcuts.Name.all.allSatisfy(\.isDefault)
    blocked = checks ? Set(KeyboardShortcuts.Name.all.filter(\.isBlocked).map(\.rawValue)) : []
  }
}

private struct HostSection: View {
  @Bindable var model: SettingsModel

  var body: some View {
    Section {
      TextField("URL", text: $model.hostURL, prompt: Text(verbatim: "http://127.0.0.1:7706"))
        .textContentType(.URL)
        .autocorrectionDisabled()
      SecureField("Token", text: $model.token, prompt: Text("None"))
      HStack {
        let content = MenuBarContent(phase: model.store.phase, status: nil, speed: 0)
        Label(model.store.phase.title, systemImage: content.symbol)
          .foregroundStyle(model.store.phase.hasPad ? .primary : .secondary)
        Spacer()
        Button("Connect") { model.connect() }
          .disabled(!model.hasChanges)
          .keyboardShortcut(.defaultAction)
      }
      if let error = model.connectError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    } header: {
      Text("Host")
    } footer: {
      Text(
        "The token stays in the Keychain. The host's loopback listener needs none; the tailnet door does."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
