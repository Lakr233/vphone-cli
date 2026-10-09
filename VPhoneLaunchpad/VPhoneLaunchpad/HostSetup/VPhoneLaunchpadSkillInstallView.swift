import AppKit
import SwiftUI

/// Hands the vphone skill to the user's own coding agent. Agents keep skills in
/// different places, so Launchpad installs nothing itself: it shows a prompt
/// that names the skill folder inside this app, and the agent copies it.
struct VPhoneLaunchpadSkillInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// The skill folder the build copies into Contents/Resources/Skills.
    static var skillURL: URL? {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent("vphone-guest-control", isDirectory: true)
        guard let url, FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) else {
            return nil
        }
        return url
    }

    private var prompt: String? {
        Self.skillURL.map { url in
            """
            Install the vphone skill so you can use it in later sessions.

            The skill is the folder:
            \(url.path)

            Read SKILL.md there, then copy the whole folder, with its references/ folder beside SKILL.md, into the place where you load skills from. Check that place for your own agent first, and ask me if you are not sure. Do not change anything inside the app bundle.
            """
        }
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Install Skill")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Give this to your coding agent, such as Claude Code, Codex or Grok. It reads the vphone skill from this Mac and installs it where that agent expects skills.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let prompt {
                    ScrollView {
                        Text(prompt)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("This copy of Launchpad does not contain the skill.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        } accessory: {
            Button("Show in Finder") {
                if let url = Self.skillURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .disabled(prompt == nil)
        } actions: {
            Button(copied ? "Copied" : "Copy Prompt") {
                guard let prompt else {
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                copied = true
            }
            .disabled(prompt == nil)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 460)
    }
}
