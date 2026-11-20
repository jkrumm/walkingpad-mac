import Foundation

/// The belt's speed range and the steps the stepper and the hotkeys move in.
public enum SpeedRange {
  public static let minimum = 0.5
  public static let maximum = 6.0
  public static let step = 0.5
  /// The quick picks in the popover.
  public static let presets: [Double] = [2.0, 3.0, 4.0, 5.0]
  public static let defaultStartSpeed = 3.0

  /// Into the range, rounded to 0.1 as the host rounds.
  public static func clamp(_ kmh: Double) -> Double {
    min(max((kmh * 10).rounded() / 10, minimum), maximum)
  }

  /// The next grid speed above (`steps` > 0) or below the current one: 3.2 goes up to 3.5 and
  /// down to 3.0, so a speed set on the pad's remote snaps onto the grid on the first press.
  public static func stepped(from kmh: Double, by steps: Int) -> Double {
    guard steps != 0 else { return clamp(kmh) }
    let position = kmh / step
    let tolerance = 1e-6
    let grid =
      steps > 0
      ? (position + tolerance).rounded(.down) + Double(steps)
      : (position - tolerance).rounded(.up) + Double(steps)
    return clamp(grid * step)
  }
}
