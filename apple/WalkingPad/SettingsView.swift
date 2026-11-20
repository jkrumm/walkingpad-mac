import KeyboardShortcuts
import PadKit
import SwiftUI

/// The Settings window: host connection, start speed, hotkeys, launch at login.
struct SettingsView: View {
  static let windowID = "settings"

  @Bindable var model: SettingsModel

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
      Section("Hotkeys") {
        KeyboardShortcuts.Recorder("Start or stop", name: .toggleBelt)
        KeyboardShortcuts.Recorder("Faster", name: .speedUp)
        KeyboardShortcuts.Recorder("Slower", name: .speedDown)
      }
      Section("General") {
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { model.loginItem == .enabled || model.loginItem == .requiresApproval },
            set: { model.setLaunchAtLogin($0) })
        )
        .disabled(model.loginItem == .unavailable)
        if model.loginItem == .requiresApproval {
          Text("Allow WalkingPad in System Settings › General › Login Items.")
            .font(.caption).foregroundStyle(.secondary)
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
