import Foundation
import Observation
import PadKit

/// What the Settings window edits: the host connection (URL in UserDefaults, token in the
/// Keychain), the default start speed, what the menu bar shows and launch at login.
@MainActor
@Observable
final class SettingsModel {
  var hostURL: String
  var token: String
  private(set) var startSpeed: Double
  /// Why Connect refused, or why the token could not be stored.
  private(set) var connectError: String?
  /// Whether the pad took the start speed.
  private(set) var startSpeedNote: String?
  private(set) var loginItem: LoginItemState
  private(set) var loginItemError: String?
  private(set) var menuBarValues: MenuBarValues

  let store: PadStore
  @ObservationIgnored private let preferences: HostPreferences
  @ObservationIgnored private let tokens: any TokenStore
  @ObservationIgnored private let loginItems: any LoginItemControlling
  @ObservationIgnored private var savedHostURL: String
  @ObservationIgnored private var savedToken: String
  @ObservationIgnored private var startSpeedSave: Task<Void, Never>?
  /// The Keychain refused the read (a rebuilt binary it does not trust yet): an empty field then
  /// means "unknown", and Connect must not delete the stored token.
  @ObservationIgnored private let tokenUnreadable: Bool

  init(
    store: PadStore, preferences: HostPreferences, tokens: any TokenStore,
    loginItem: any LoginItemControlling
  ) {
    self.store = store
    self.preferences = preferences
    self.tokens = tokens
    loginItems = loginItem
    var token = ""
    var readError: String?
    do {
      token = try tokens.read() ?? ""
    } catch {
      readError = "The stored token could not be read: \(error.localizedDescription)"
    }
    tokenUnreadable = readError != nil
    connectError = readError
    hostURL = preferences.hostURL
    self.token = token
    savedHostURL = preferences.hostURL
    savedToken = token
    startSpeed = preferences.startSpeed
    self.loginItem = loginItem.state()
    menuBarValues = preferences.menuBarValues
  }

  /// The URL or the token differ from what the store uses.
  var hasChanges: Bool { hostURL != savedHostURL || token != savedToken }

  /// Points the store at the saved host, or leaves it unconfigured. Called once at launch.
  func connectSaved() {
    store.startSpeed = startSpeed
    store.configure(
      HostAddress.parse(savedHostURL).map { PadClient(baseURL: $0, token: savedToken) })
  }

  /// Saves the URL and the token and points the store at them.
  func connect() {
    connectError = nil
    let trimmed = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, HostAddress.parse(trimmed) == nil {
      connectError = "Not an http or https URL."
      return
    }
    do {
      if !token.isEmpty {
        try tokens.save(token)
      } else if !tokenUnreadable {
        try tokens.delete()
      }
    } catch {
      connectError = "The token could not be stored: \(error.localizedDescription)"
      return
    }
    preferences.hostURL = trimmed
    hostURL = trimmed
    savedHostURL = trimmed
    savedToken = token
    connectSaved()
  }

  /// Keeps the speed for the Start button and, after a short pause, stores it on the pad as the
  /// speed its own remote starts with (`POST /pref/start-speed`).
  func setStartSpeed(_ kmh: Double) {
    let speed = SpeedRange.clamp(kmh)
    guard speed != startSpeed else { return }
    startSpeed = speed
    preferences.startSpeed = speed
    store.startSpeed = speed
    startSpeedNote = nil
    startSpeedSave?.cancel()
    let store = store
    startSpeedSave = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      guard !Task.isCancelled else { return }
      do {
        try await store.saveStartSpeedOnPad(speed)
        self?.startSpeedNote = "Saved on the pad."
      } catch {
        self?.startSpeedNote = "Not saved on the pad: \(PadPhase.describe(error))."
      }
    }
  }

  /// Shows or hides one value in the menu bar title.
  func setMenuBar(_ value: MenuBarValues, shown: Bool) {
    if shown {
      menuBarValues.insert(value)
    } else {
      menuBarValues.remove(value)
    }
    preferences.menuBarValues = menuBarValues
  }

  /// Always tries: macOS answers `notFound` for an app that has not registered yet, so the state
  /// read before the click says nothing. The toggle then shows what macOS reports, and a refusal
  /// is written under it.
  func setLaunchAtLogin(_ enabled: Bool) {
    loginItemError = nil
    do {
      loginItem = try loginItems.setEnabled(enabled)
      if enabled, !loginItem.isOn {
        loginItemError = "macOS did not register WalkingPad as a login item."
      }
    } catch {
      let verb = enabled ? "switch on" : "switch off"
      loginItemError = "Could not \(verb) launch at login: \(error.localizedDescription)"
      loginItem = loginItems.state()
    }
  }
}
