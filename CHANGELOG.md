# Changelog

## Public source preparation — unreleased

- Publish the native macOS and iPhone/iPad implementation with current macOS 27 / iOS 27 targets.
- Include dictation, writing tools, Reader with Kokoro narration, local assistant backends, optional MCP connections, memory and Mac agent monitoring.
- Vendor the pinned Atlas SDK with its license and reproducibility manifest.
- Document experimental status, permissions, network boundaries and independent device/distribution validation requirements.

This is source availability, not a signed binary release or a certification that all features are production-ready. See [README](README.md) and the [development guide](docs/public/development.md).

## Earlier fork milestones

The fork added Codex monitoring alongside Claude Code, Gemini CLI and Antigravity, retained the hook relay and notch interaction, and removed the original Windows application and hosted integration pills. It subsequently grew a new assistant, explicit MCP connections and an iOS implementation. Earlier descriptions of a Mac-only, network-free monitor no longer describe the current application.

Reader initially used system speech; the current Reader and assistant speech paths use Kokoro. Historical build numbers and local installation results are not verification evidence for this public checkout.

The app is named OmniFlow and the assistant Omni. Historical `Coucou`, `NotchBuddy`, `NotchLee` and `coucou_agent` names remain in compatibility identifiers. Upstream work and contributors remain credited below; those entries describe the upstream project at the time, not current OmniFlow capabilities or available downloads.

## Historical upstream development

- Compact island on screens without a notch (#22) — thanks @Kamasoutra
- Only web links (http/https) open from the notch; other kinds of links from Claude or integrations are ignored (#16) — thanks @Cris1670
- Hook socket limited to your own user account, with size and time limits; logs no longer keep commands, n8n data or full URLs, and stay under 1 MB (#16) — thanks @Cris1670 and @Vignesh-Thangamariappan
- The island always reopens after folding, and Settings opens below it, resizable — thanks @rouderz
- Choose the Claude model for the chat in Settings; the list comes from your Anthropic account, and Claude Sonnet 4.6 stays the default — thanks @rouderz
- Windows build artifacts are now downloadable from a manual CI run — thanks @MysJofR
- Any agent can talk to Mochi: tag a hook payload with `coucou_agent` (e.g. `nb-hook --agent my-agent`) and it gets its own pill in the island (#7, #9) — thanks @lacatu5
- Gemini CLI and Antigravity (agy) hook support on macOS: install from Settings and their sessions show up in the island — thanks @corefusiion
