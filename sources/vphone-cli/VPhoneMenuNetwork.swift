import AppKit
import OSLog

private let networkLogger = Logger(subsystem: "vphone-cli", category: "network")

// MARK: - Network Menu

extension VPhoneMenuController {
  enum NetworkProfile: Int, CaseIterable {
    case direct = 0
    case threeG = 1
    case edge = 2
    case lte = 3
    case loss100 = 4

    var title: String {
      switch self {
      case .direct: return "100% Direct (No Limits)"
      case .threeG: return "3G (780 Kbps down, 330 Kbps up, 100ms)"
      case .edge: return "Edge (240 Kbps down, 200 Kbps up, 400ms)"
      case .lte: return "LTE (15 Mbps down, 2 Mbps up)"
      case .loss100: return "100% Packet Loss"
      }
    }
  }

  func buildNetworkMenu() -> NSMenuItem {
    let item = NSMenuItem()
    let menu = NSMenu(title: "Network")

    for profile in NetworkProfile.allCases {
      let mi = makeItem(profile.title, action: #selector(setNetworkProfile(_:)))
      mi.tag = profile.rawValue
      mi.state = profile == .direct ? .on : .off
      menu.addItem(mi)
    }

    item.submenu = menu
    return item
  }

  @objc func setNetworkProfile(_ sender: NSMenuItem) {
    guard let menu = sender.menu else { return }
    for mi in menu.items {
      mi.state = mi === sender ? .on : .off
    }
    guard let profile = NetworkProfile(rawValue: sender.tag) else { return }

    networkLogger.info(
      "[network] Applying profile: \(profile.title)... (requires administrator privileges)")

    applyNetworkProfile(profile)
  }

  private func applyNetworkProfile(_ profile: NetworkProfile) {
    // We use AppleScript to elevate privileges via `do shell script ... with administrator privileges`.
    // The script sets up a custom pfctl anchor "vphone_nlc" and uses dummynet (dnctl) pipes
    // to throttle traffic over `bridge100` (which Virtualization.framework NAT uses).

    let pfAnchor = "vphone_nlc"
    var scriptLines: [String] = []

    // Common cleanup first
    scriptLines.append("dnctl -q flush")
    scriptLines.append("pfctl -a \(pfAnchor) -F all 2>/dev/null || true")

    switch profile {
    case .direct:
      // Already flushed, nothing more to do
      break

    case .threeG:
      // Pipe 1 (Downstream): 780 Kbps, 100ms delay, queue 50
      // Pipe 2 (Upstream): 330 Kbps, 100ms delay, queue 50
      scriptLines.append("dnctl pipe 1 config bw 780Kbit/s delay 100 queue 50")
      scriptLines.append("dnctl pipe 2 config bw 330Kbit/s delay 100 queue 50")
      scriptLines.append(
        "echo 'dummynet out on bridge100 all pipe 1\\ndummynet in on bridge100 all pipe 2' | pfctl -a \(pfAnchor) -f -"
      )

    case .edge:
      // Pipe 1 (Downstream): 240 Kbps, 400ms delay, queue 50
      // Pipe 2 (Upstream): 200 Kbps, 400ms delay, queue 50
      scriptLines.append("dnctl pipe 1 config bw 240Kbit/s delay 400 queue 50")
      scriptLines.append("dnctl pipe 2 config bw 200Kbit/s delay 400 queue 50")
      scriptLines.append(
        "echo 'dummynet out on bridge100 all pipe 1\\ndummynet in on bridge100 all pipe 2' | pfctl -a \(pfAnchor) -f -"
      )

    case .lte:
      // Pipe 1 (Downstream): 15 Mbps, queue 50
      // Pipe 2 (Upstream): 2 Mbps, queue 50
      scriptLines.append("dnctl pipe 1 config bw 15Mbit/s queue 50")
      scriptLines.append("dnctl pipe 2 config bw 2Mbit/s queue 50")
      scriptLines.append(
        "echo 'dummynet out on bridge100 all pipe 1\\ndummynet in on bridge100 all pipe 2' | pfctl -a \(pfAnchor) -f -"
      )

    case .loss100:
      // Drop everything explicitly using dummynet with 1.0 plr (probability of packet loss 100%)
      scriptLines.append("dnctl pipe 1 config plr 1.0")
      scriptLines.append("echo 'dummynet on bridge100 all pipe 1' | pfctl -a \(pfAnchor) -f -")
    }

    // Enable dummynet if not already enabled and reload pf to ensure rules are active
    if profile != .direct {
      scriptLines.append("sysctl -w net.inet.ip.dummynet.expire=1")  // optional cleanup optimization
      scriptLines.append("pfctl -E 2>/dev/null || true")  // ensure pf is globally enabled
    }

    let shScript = scriptLines.joined(separator: " ; ")
    let appleScript = "do shell script \"\(shScript)\" with administrator privileges"

    DispatchQueue.global(qos: .userInitiated).async {
      var error: NSDictionary?
      if let scriptObject = NSAppleScript(source: appleScript) {
        scriptObject.executeAndReturnError(&error)
        if let error = error {
          networkLogger.error("[network] Failed to apply network link conditioner: \(error)")
        } else {
          networkLogger.info("[network] Profile applied successfully.")
        }
      }
    }
  }

  // Allows VPhoneAppDelegate to flush network on termination
  func flushNetworkRules() {
    let pfAnchor = "vphone_nlc"
    let shScript = "dnctl -q flush ; pfctl -a \(pfAnchor) -F all 2>/dev/null || true"
    let appleScript = "do shell script \"\(shScript)\" with administrator privileges"

    networkLogger.info("[network] Flushing custom rules on exit...")
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: appleScript) {
      scriptObject.executeAndReturnError(&error)
    }
  }
}
