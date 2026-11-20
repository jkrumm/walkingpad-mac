import Foundation
import Observation
import PadKit

/// What the Settings window edits: the host connection (URL in UserDefaults, token in the
/// Keychain), the default start speed and launch at login.
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

  let store: PadStore
  @ObservationIgnored private let preferences: HostPreferences
  @ObservationIgnored private let tokens: any TokenStore
  @ObservationIgnored private let loginItems: any LoginItemControlling
  @ObservationIgnored private var savedHostURL: String
  @ObservationIgnored private var savedToken: String
  @ObservationIgnored private var startSpeedSave: Task<Void, Never>?

  init(
    store: PadStore, preferences: HostPreferences, tokens: any TokenStore,
    loginItem: any LoginItemControlling
  ) {
    self.store = store
    self.preferences = preferences
    self.tokens = tokens
    loginItems = loginItem
    let token = (try? tokens.read()) ?? ""
    hostURL = preferences.hostURL
    self.token = token
    savedHostURL = preferences.hostURL
    savedToken = token
    startSpeed = preferences.startSpeed
    self.loginItem = loginItem.state()
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
      token.isEmpty ? try tokens.delete() : try tokens.save(token)
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

  func setLaunchAtLogin(_ enabled: Bool) {
    loginItemError = nil
    do {
      loginItem = try loginItems.setEnabled(enabled)
    } catch {
      loginItemError = error.localizedDescription
      loginItem = loginItems.state()
    }
  }
}
