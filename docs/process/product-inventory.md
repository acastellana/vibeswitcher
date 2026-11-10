# Product inventory

What VibeSwitcher already does for the user, generated from `Sources/VibeSwitcher/` by `scripts/product-inventory.sh`, and regenerated with the lead's records after a merge that changes them: don't edit it by hand. Before proposing a feature or asking the user, check here (and the code): what's listed exists.

## Menu bar

The main window's menus (`MainMenu.build`); standard items go to the first responder.

### VibeSwitcher
- VibeSwitcher › About VibeSwitcher — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- VibeSwitcher › Settings… ⌘, — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- VibeSwitcher › Restart Session Host — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- VibeSwitcher › Hide VibeSwitcher ⌘H — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- VibeSwitcher › Hide Others ⌥⌘H — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- VibeSwitcher › Show All — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- VibeSwitcher › Quit VibeSwitcher ⌘Q — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

### File
- File › New Session ⌘N — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- File › New Shell ⌥⌘N — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- File › Close Window ⌘W — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- File › End Session… ⇧⌘⌫ — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

### Edit
- Edit › Undo ⌘Z — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Redo ⇧⌘Z — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Cut ⌘X — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Copy ⌘C — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Paste ⌘V — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Paste and Match Style ⌥⇧⌘V — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Delete — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Select All ⌘A — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Find › Find… ⌘F — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Find › Find Next ⌘G — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Find › Find Previous ⇧⌘G — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Edit › Find › Use Selection for Find ⌘E — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

### View
- View › Terminal ⌥⌘1 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Chat ⌥⌘2 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Group by Attention ⌃⌘1 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Group by Project ⌃⌘2 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Filter Sessions ⌥⌘F — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Toggle Sidebar ⌃⌘S — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Toggle Inspector ⌥⌘0 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Focus Terminal ⇧⌘↩ — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Bigger ⌘= — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Smaller ⌘- — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Default Size ⌘0 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- View › Clear Scrollback ⇧⌘K — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

### Session
- Session › Command Palette… ⌘K — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Next Session ⌥⌘↓ — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Previous Session ⌥⌘↑ — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Next Needing You ⌘J — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Open in Terminal ⌘O — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Stop ⌘. — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Export Chat… ⇧⌘E — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Start Page ⇧⌘H — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Brief Me ⇧⌘B — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Brief Me on Project ⌥⇧⌘B — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Session › Session 1–9 ⌘1–9 — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

### Window
- Window › Minimize ⌘M — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Window › Zoom — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Window › Statistics… ⌥⌘S — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`
- Window › Bring All to Front — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

### Help
- Help: filled by AppKit — `Sources/VibeSwitcher/MainWindow/MainMenu.swift`

## Command palette (⌘K)

Sessions in attention order, then these commands, then New <preset> in <recent project>.
- Next Session Needing You ⌘J — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- New Session in … / Start Project Lead in Folder… ⌘N — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- New Shell in … / New Shell… ⌥⌘N — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Start Page ⇧⌘H — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Group by Attention ⌃⌘1 — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Group by Project ⌃⌘2 — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Filter Sessions ⌥⌘F — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Toggle Inspector ⌥⌘0 — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Toggle Sidebar ⌃⌘S — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Focus Terminal ⇧⌘↩ — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Open in Terminal ⌘O — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Statistics… ⌥⌘S — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Settings… ⌘, — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Start Project Lead in … — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- New … in … — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Brief Me ⇧⌘B — `Sources/VibeSwitcher/MainWindow/CommandPalette.swift`
- Brief Me on … ⌥⇧⌘B — `Sources/VibeSwitcher/MainWindow/CommandPalette.swift`

## Context menus

Right-click menus, by where they are. The chat's message text adds Copy and Select All to its own items.
- Chat: Copy Summary — `Sources/VibeSwitcher/MainWindow/Chat/AllDoneCard.swift`
- Chat: Copy — `Sources/VibeSwitcher/MainWindow/Chat/ChatMessageText.swift`
- Chat: Select All — `Sources/VibeSwitcher/MainWindow/Chat/ChatMessageText.swift`
- Chat: Copy — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Chat: Copy as Markdown — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Chat: Copy Message — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Chat: Edit in Composer — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Chat: Send Again — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Chat: Copy — `Sources/VibeSwitcher/MainWindow/Chat/TeamMessageCard.swift`
- Chat, shell request card: Copy Command — `Sources/VibeSwitcher/Shell/ShellCard.swift`
- Chat, wallet card: Copy Request — `Sources/VibeSwitcher/Wallet/WalletCard.swift`
- Menu bar popover, session row: Switch to Session — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Resume — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Pause › Until I Resume It — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Pause › For 1 Hour — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Pause › Until Tomorrow Morning — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Pause › For 1 Week — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Rename… — `Sources/VibeSwitcher/PopoverView.swift`
- Menu bar popover, session row: Reset Name to “…” — `Sources/VibeSwitcher/PopoverView.swift`
- Sidebar session row: Close Finished Shells… — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Rename… — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Resume Notifications — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Pause › Until I Resume It — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Pause › For 1 Hour — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Pause › Until Tomorrow Morning — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Pause › For 1 Week — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Open in Terminal — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Move to Window… — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: End Session… — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Resume — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Remove — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Copy Session ID — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Copy Resume Command — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Sidebar session row: Reveal in Finder — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`

## Settings

Settings (⌘,), category by category: each option, under its section, with the file its row is in.

### General
- Settings › General — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Startup: Open at login — `Sources/VibeSwitcher/SettingsWindow.swift`
- Startup: Open the window when VibeSwitcher starts — `Sources/VibeSwitcher/SettingsWindow.swift`
- Startup: First-run setup — `Sources/VibeSwitcher/SettingsWindow.swift`
- Projects: Projects folder — `Sources/VibeSwitcher/SettingsWindow.swift`

### Notifications
- Settings › Notifications — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Banners and sounds: Permission — `Sources/VibeSwitcher/SettingsWindow.swift`
- Banners and sounds: Notify when a session needs input — `Sources/VibeSwitcher/SettingsWindow.swift`
- Banners and sounds: Notify when a session finishes — `Sources/VibeSwitcher/SettingsWindow.swift`
- Banners and sounds: Play a sound when a session needs input — `Sources/VibeSwitcher/SettingsWindow.swift`
- Banners and sounds: Remind me about waiting or stuck sessions — `Sources/VibeSwitcher/SettingsWindow.swift`

### Appearance
- Settings › Appearance — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Colors: Theme — `Sources/VibeSwitcher/SettingsWindow.swift`
- Colors: Text color — `Sources/VibeSwitcher/SettingsWindow.swift`
- Colors: Background color — `Sources/VibeSwitcher/SettingsWindow.swift`
- Colors: Cursor color — `Sources/VibeSwitcher/SettingsWindow.swift`
- Colors: Selection color — `Sources/VibeSwitcher/SettingsWindow.swift`
- Colors: ANSI colors — `Sources/VibeSwitcher/SettingsWindow.swift`
- Text: Font — `Sources/VibeSwitcher/SettingsWindow.swift`
- Text: Size — `Sources/VibeSwitcher/SettingsWindow.swift`
- Behavior: Cursor — `Sources/VibeSwitcher/SettingsWindow.swift`
- Behavior: Blinking cursor — `Sources/VibeSwitcher/SettingsWindow.swift`
- Behavior: Scrollback — `Sources/VibeSwitcher/SettingsWindow.swift`
- Behavior: Use Option as Meta key — `Sources/VibeSwitcher/SettingsWindow.swift`
- Behavior: Bell — `Sources/VibeSwitcher/SettingsWindow.swift`

### Sessions & Sidebar
- Settings › Sessions & Sidebar — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Menu bar: Order sessions — `Sources/VibeSwitcher/SettingsWindow.swift`
- Menu bar: Floating dots panel — `Sources/VibeSwitcher/SettingsWindow.swift`
- Sidebar: Sidebar mode — `Sources/VibeSwitcher/SettingsWindow.swift`
- Sidebar: Auto-hide the sidebar (show it at the right edge) — `Sources/VibeSwitcher/SettingsWindow.swift`
- Sidebar: Show briefly after switching desktops — `Sources/VibeSwitcher/SettingsWindow.swift`
- Sidebar: Minimize a session's window when pausing it — `Sources/VibeSwitcher/SettingsWindow.swift`

### Launch Presets
- Settings › Launch Presets — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Presets: Presets for — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Presets — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Default — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Name — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Starts — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Command — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Keep a shell open after it exits — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Runs in — `Sources/VibeSwitcher/SettingsWindow.swift`
- Presets: Environment — `Sources/VibeSwitcher/SettingsWindow.swift`

### Agents
- Settings › Agents — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Shells: Let agents open shells without asking — `Sources/VibeSwitcher/SettingsWindow.swift`
- Hooks: Hooks — `Sources/VibeSwitcher/SettingsWindow.swift`
- Codex: Trust VibeSwitcher's hooks — `Sources/VibeSwitcher/SettingsWindow.swift`

### Project lead
- Settings › Project lead — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Team: Summarize what each agent is doing with AI — `Sources/VibeSwitcher/SettingsWindow.swift`
- Team: Start a fresh lead session — `Sources/VibeSwitcher/SettingsWindow.swift`
- Team: Let project leads message each other — `Sources/VibeSwitcher/SettingsWindow.swift`
- Working policy: Working policy — `Sources/VibeSwitcher/WorkingPolicySettings.swift`
- Review rules floor: Project — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Sensitive paths — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Strict paths — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Audit finders, at least — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Merge policy, at least — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Risk lines, at most — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Risk check's model pass — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Audit sample, at least — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Verifier — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- Review rules floor: Save or revert — `Sources/VibeSwitcher/ReviewFloorSettings.swift`

### Performance
- Settings › Performance — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Boost: Boost — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Boost: Also on battery — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Boost: Start nothing above a load of, while boosted — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Boost: Team sessions on this Mac while boosted, at most — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Boost: Workers per project while boosted, at most — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Boost: Test and build slots while boosted — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Mac-wide limits: Team sessions on this Mac, at most — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Mac-wide limits: Start nothing above a load of — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Mac-wide limits: Test and build slots at once — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Usage limits: Ignore usage limits — `Sources/VibeSwitcher/MacLimitsSettings.swift`
- Power: Keep the Mac awake while the team works — `Sources/VibeSwitcher/SettingsWindow.swift`
- Power: On battery, pause lead work below — `Sources/VibeSwitcher/SettingsWindow.swift`

### Dictation & Briefing
- Settings › Dictation & Briefing — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Dictation: OpenAI API key for dictation — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Dictation: Key in use — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Dictation: Model — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Dictation: Hold Space to dictate — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Dictation: Silence the Mac while dictating — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Spoken briefing: Language — `Sources/VibeSwitcher/SettingsWindow.swift`
- Spoken briefing: ElevenLabs API key — `Sources/VibeSwitcher/SettingsWindow.swift`
- Spoken briefing: Key in use — `Sources/VibeSwitcher/SettingsWindow.swift`
- Spoken briefing: Voice — `Sources/VibeSwitcher/SettingsWindow.swift`

### Phone
- Settings › Phone — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Phone access: Phone access over Tailscale — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Pair a phone — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Allow replies and key presses from the phone — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Allow opening dev pages — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Chrome access — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Phone notifications only while I'm away from the Mac — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Paired devices — `Sources/VibeSwitcher/PhoneAccessView.swift`
- Phone access: Activity log — `Sources/VibeSwitcher/PhoneAccessView.swift`

### Wallet
- Settings › Wallet — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Wallet Manager's Mac: Wallet Manager — `Sources/VibeSwitcher/Wallet/WalletSettingsTab.swift`
- Passage: Command path — `Sources/VibeSwitcher/Wallet/WalletSettingsTab.swift`

### Advanced
- Settings › Advanced — `Sources/VibeSwitcher/SettingsCatalog.swift`
- Mac permissions: Control Terminal — `Sources/VibeSwitcher/SettingsWindow.swift`
- Mac permissions: Accessibility — `Sources/VibeSwitcher/SettingsWindow.swift`
- Session host: Session host — `Sources/VibeSwitcher/HostRestart.swift`

## Sheets, popovers and dialogs

- BriefingViews: popover — BriefingPanel — `Sources/VibeSwitcher/Briefing/BriefingViews.swift`
- DictationViews: confirmationDialog — Import … into your Keychain for dictation? — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Chat: sheet — ImageViewer — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Project lead: alert — A project lead needs a git repository. — `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift`
- Project lead: alert — The repository has no commits yet. — `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift`
- Project lead: alert — “…” couldn't get a first commit. — `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift`
- Project lead: alert — The lead didn't start. — `Sources/VibeSwitcher/MainWindow/Lead/LeadController.swift`
- Window: alert — The project couldn't be made — `Sources/VibeSwitcher/MainWindow/NewProject/NewProjectSheet.swift`
- Sidebar session row: popover — ToolchainNoteView — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- Window: sheet — NewProjectSheet — `Sources/VibeSwitcher/MainWindow/StartPage.swift`

## Chat

- Search the conversation: ⌘F opens the search bar, ⌘G / ⇧⌘G step through the matches — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Export Chat… (⇧⌘E): the conversation as a Markdown file — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Latest button: jumps to the end while it's off screen — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Code block header: the language, Copy, and Run when the session takes it — `Sources/VibeSwitcher/MainWindow/Chat/ChatMessageText.swift`
- Code block Run: types a shell block into the session after you confirm; says Sent or why Not run — `Sources/VibeSwitcher/MainWindow/Chat/ChatRunner.swift`
- Tool calls folded into groups; open a group, then a tool, for its input and output — `Sources/VibeSwitcher/MainWindow/Chat/ToolViews.swift`
- The to-do list or plan steps, pinned above the conversation while any is open — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Answer card: a question or permission prompt on the session's screen as buttons (⌘1–⌘9, ↩, ↑ / ↓) — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Show N earlier: long chats open at their end, earlier messages a page at a time — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- New since you looked: a marker with a summary where you left off — `Sources/VibeSwitcher/MainWindow/Chat/ChatView.swift`
- Selecting across messages and copying it (plain text and rich text) — `Sources/VibeSwitcher/MainWindow/Chat/ChatMessageText.swift`
- Image viewer for attached and tool images — `Sources/VibeSwitcher/MainWindow/Chat/ToolViews.swift`
- Composer: ↩ sends, ⇧↩ adds a line, ↑ / ↓ walk earlier prompts, / commands, @ files, pasted or dropped images, ⌘. stops — `Sources/VibeSwitcher/MainWindow/Chat/ComposerView.swift`
- Push-to-talk dictation in the composer — `Sources/VibeSwitcher/Dictation/DictationViews.swift`
- Chat text size: ⌘+, ⌘−, ⌘0 while the chat is shown — `Sources/VibeSwitcher/MainWindow/Chat/MarkdownView.swift`
- Team messages between the lead and its workers, as cards — `Sources/VibeSwitcher/MainWindow/Chat/TeamMessageCard.swift`
- All-done card: a batch's summary and receipts — `Sources/VibeSwitcher/MainWindow/Chat/AllDoneCard.swift`
- Shell request cards: an agent asks for a shell; Run or Decline — `Sources/VibeSwitcher/Shell/ShellCard.swift`
- Wallet request cards: an agent's transaction request; Send to Wallet Manager or sign in a browser wallet — `Sources/VibeSwitcher/Wallet/WalletCard.swift`

## Terminal

- Selection survives output: select and copy while a build or server prints — `Sources/VibeSwitcher/MainWindow/TerminalPane.swift`
- Option-drag selects past a program that asked for the mouse (Claude Code's fullscreen, vim, tmux); Shift-drag too — `Sources/VibeSwitcher/MainWindow/TerminalPane.swift`
- Find in the scrollback: ⌘F while the terminal is shown — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Clear Scrollback (⇧⌘K) — `Sources/VibeSwitcher/MainWindow/TerminalPane.swift`
- Terminal text size: ⌘+, ⌘−, ⌘0 while the terminal is shown — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Focus Terminal (⇧⌘↩): the terminal takes the whole window — `Sources/VibeSwitcher/MainWindow/MainWindowController.swift`
- Wallet request strip along the terminal — `Sources/VibeSwitcher/MainWindow/TerminalWalletStrip.swift`

## Window and app

- Start page: recent projects, shortcuts, ended sessions (⇧⌘H) — `Sources/VibeSwitcher/MainWindow/StartPage.swift`
- Command palette (⌘K) — `Sources/VibeSwitcher/MainWindow/CommandPalette.swift`
- Inspector (⌥⌘0): the lead's Team tab and the session's details — `Sources/VibeSwitcher/MainWindow/InspectorView.swift`
- A lead's Team tab: tasks, decisions, scorecard, messages between leads — `Sources/VibeSwitcher/MainWindow/Lead/TeamViews.swift`
- Brief Me (⇧⌘B): a spoken briefing across led projects, or one project's — `Sources/VibeSwitcher/Briefing/BriefingViews.swift`
- Statistics window — `Sources/VibeSwitcher/Statistics/StatisticsView.swift`
- Floating dots panel — `Sources/VibeSwitcher/FloatingPanel.swift`
- Menu bar popover: every session, switch, pause, rename — `Sources/VibeSwitcher/PopoverView.swift`
- Global hot key — `Sources/VibeSwitcher/HotKey.swift`
- Phone access: a web app for the phone over Tailscale — `Sources/VibeSwitcher/PhoneAccess.swift`
- New project sheet — `Sources/VibeSwitcher/MainWindow/NewProject/NewProjectSheet.swift`

## Sandbox (`scripts/sandbox-app.sh`)

`run`, `shot NAME` and `quit` (the script's own), then the sandbox's commands (`help` lists them whole).
- `status` — the sandbox's pid, host, fake sessions, windows and anything it refused — `Sources/VibeSwitcher/Sandbox.swift`
- `chat [TEXT]` — selects the fake session whose title contains TEXT (the first one) and shows its chat — `Sources/VibeSwitcher/Sandbox.swift`
- `terminal` — shows the selected session's terminal instead of its chat — `Sources/VibeSwitcher/Sandbox.swift`
- `drag [option|shift|command]…` — drags the mouse across the shown terminal's first two lines, through the window as a click does (with those… — `Sources/VibeSwitcher/Sandbox.swift`
- `copy` — presses ⌘C as the menu does (to the first responder that takes Copy): says who took it and what the… — `Sources/VibeSwitcher/Sandbox.swift`
- `paste TEXT` — puts TEXT on the sandbox's pasteboard and presses ⌘V as the menu does: says who took it and the terminal's… — `Sources/VibeSwitcher/Sandbox.swift`
- `keys TEXT` — types TEXT and Return into the shown terminal (a sandbox session's: e.g. a command for its zsh) — `Sources/VibeSwitcher/Sandbox.swift`
- `mouse on|off` — the shown session's program asks for mouse reporting (DECSET 1002 and 1006, as Claude Code's fullscreen… — `Sources/VibeSwitcher/Sandbox.swift`
- `type TEXT` — types TEXT into the chat's composer (through its text view, as the keyboard does) — `Sources/VibeSwitcher/Sandbox.swift`
- `send` — presses Return in the composer: the message goes to the fake session — `Sources/VibeSwitcher/Sandbox.swift`
- `runblock [yes]` — the shown chat's last code block with a Run: shows what Run asks first, as the sheet; with yes, runs it as… — `Sources/VibeSwitcher/Sandbox.swift`
- `tell JSON` — hands a fake Claude (the selected one, or the one labelled "to") a FakeClaude op, e.g. '{"op": "permission"… — `Sources/VibeSwitcher/Sandbox.swift`
- `notify prepare|allow|deny` — a permission prompt's banner for the selected fake session (the sandbox posts no notifications): prepare… — `Sources/VibeSwitcher/Sandbox.swift`
- `new [codex|shell|zsh] [LABEL]` — starts another fake session: a Claude, or a Codex or a plain shell (cat), or an interactive zsh on the… — `Sources/VibeSwitcher/Sandbox.swift`
- `confighold [outside|sync|diff|all|accept]` — the agents' config held for the fake lead (ConfigSeal): its team's worker bound (outside: none, so it's held… — `Sources/VibeSwitcher/Sandbox.swift`
- `push [click|decline]` — the fake lead asks to push (push_remote): its folder a scratch repository and a scratch bare remote as origin… — `Sources/VibeSwitcher/Sandbox.swift`
- `clear` — ends and removes every fake session: the sidebar is empty, with its New Session menu — `Sources/VibeSwitcher/Sandbox.swift`
- `views` — the main window's AppKit views: how many, how deep, and the most common kinds (a chat that grows them stalls… — `Sources/VibeSwitcher/Sandbox.swift`
- `scroll top|middle|bottom` — scrolls the shown chat — `Sources/VibeSwitcher/Sandbox.swift`
- `scroll settings top|middle|bottom|FRACTION` — scrolls the shown Settings tab (FRACTION: that far down, e.g. 0.4) — `Sources/VibeSwitcher/Sandbox.swift`
- `size WxH` — resizes the main window's content (e.g. 1728x1015) — `Sources/VibeSwitcher/Sandbox.swift`
- `inspector team|overview|activity|hide|show` — the inspector on that tab, or collapsed or shown, as its segmented control and Toggle Inspector do — `Sources/VibeSwitcher/Sandbox.swift`
- `board [N]` — adds N finished tasks (default 250) to the fake lead's board (start the lead first) — `Sources/VibeSwitcher/Sandbox.swift`
- `churn [N]` — changes the fake lead's board N times (default 40), 0.15 s apart, each read and shown as a real change is — `Sources/VibeSwitcher/Sandbox.swift`
- `publish [N]` — has the lead controller publish N times (default 50), each laid out and drawn, and times them — `Sources/VibeSwitcher/Sandbox.swift`
- `hangs [reset]` — the sandbox's main-thread freezes (its hang reports, as the health digest tells them) and its longest wait… — `Sources/VibeSwitcher/Sandbox.swift`
- `startlead` — starts a real project lead (LeadController.startLead, as Project Lead does: the host first if none runs, its… — `Sources/VibeSwitcher/Sandbox.swift`
- `lead [FILE]` — shows a fake project lead's chat, at its end (started the first time, on FILE's transcript if given): a board… — `Sources/VibeSwitcher/Sandbox.swift`
- `team` — starts a fake worker on the fake lead's running task, in its worktree (start the lead first); select it and… — `Sources/VibeSwitcher/Sandbox.swift`
- `team named` — starts the fake lead's worker and a verifier titled as Claude Code 2.1.311 names them (worker-<slug>… — `Sources/VibeSwitcher/Sandbox.swift`
- `ask [TEXT]` — puts an open question for you (TEXT, or a made-up one) on the fake lead's board (start the lead first): its… — `Sources/VibeSwitcher/Sandbox.swift`
- `unfold` — shows the selected lead's team under its row in the sidebar — `Sources/VibeSwitcher/Sandbox.swift`
- `rotation` — shows the scheduled rotation chat line in the selected fake session — `Sources/VibeSwitcher/Sandbox.swift`
- `replaced [N]` — shows the selected window session as a lead another session replaced, with N characters (default 200000)… — `Sources/VibeSwitcher/Sandbox.swift`
- `answer` — answers the fake lead's open questions: its row reads as its terminal does again — `Sources/VibeSwitcher/Sandbox.swift`
- `leadmail` — writes made-up messages between the fake lead and other projects' leads (start the lead first) to its private… — `Sources/VibeSwitcher/Sandbox.swift`
- `extras` — adds to the fake lead's board (start the lead first) a proposal on a timer, a revised question, a task… — `Sources/VibeSwitcher/Sandbox.swift`
- `phone-show off|notinstalled|notrunning|https|portinuse|expired|unreadable` — Settings › Phone as in that setup state, with nothing started (run phone first to have a phone listed): the… — `Sources/VibeSwitcher/Sandbox.swift`
- `phone` — serves the phone's web app for this sandbox on a port of 127.0.0.1, one phone paired: STATE/phone.json says… — `Sources/VibeSwitcher/Sandbox.swift`
- `dictation key|nokey|note|ack|press|release|letgo|cancel|turnon` — push to talk in the composer (no microphone, no OpenAI: a made-up recording and transcript): a key saved or… — `Sources/VibeSwitcher/Sandbox.swift`
- `soak [MINUTES [every SECONDS] [hour CYCLES] [worker-mb MB] [without LIST]]|stop` — a working day's actions on a timer, each cycle (every 20 s): a fake Claude started and its chat shown, a… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-ask [address] [--workspace W] [--from W] [--chain N] [--to 0x…] [--amount WEI] [--expires-in 90m] [--data 0x…] [--reason TEXT]` — the selected fake session's agent files a made-up transaction request, as vs-wallet request does: its card… — `Sources/VibeSwitcher/Sandbox.swift`
- `shell-ask [COMMAND]` — the selected fake session's agent asks for a new shell running COMMAND (a made-up program unless given) in… — `Sources/VibeSwitcher/Sandbox.swift`
- `shell-click run|decline|dismiss` — presses that button on the newest shell request card in the selected chat (run starts the shell session in… — `Sources/VibeSwitcher/Sandbox.swift`
- `shell-tidy SECONDS` — how long a handled shell card (started, declined, expired) shows before it leaves by itself, for cards… — `Sources/VibeSwitcher/Sandbox.swift`
- `shell-idle SECONDS` — how long after its command went well an untouched Run-card shell is ended by itself (600 by default), and… — `Sources/VibeSwitcher/Sandbox.swift`
- `shell-close [PROJECT]` — the sidebar's Close Finished Shells… for PROJECT (the selected session's unless given), its confirmation… — `Sources/VibeSwitcher/Sandbox.swift`
- `sidebar attention|projects [ended]` — groups the sidebar by attention or by project (a project's header has its menu), with the Ended fold open… — `Sources/VibeSwitcher/Sandbox.swift`
- `shell-fail on|off` — on: the sandbox's own host refuses to start the shells a card's Run asks for, so the Run says why it didn't… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-card` — prints the newest wallet request card in the selected chat: its id, state, line, not-picked-up hint… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-later MINUTES` — moves the wallet desk's clock MINUTES ahead (never back) and redraws the cards, e.g. for the not-picked-up… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-click send|retry|discard|browser|settings|dismiss` — presses that button on the newest wallet request card of the selected session, on its strip or not (dismiss… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-peer none|chosen|this-mac|this-mac-stopped` — no Wallet Manager peer chosen for the wallet desk (as with None in Settings › Wallet: cards offer the browser… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-page [NAME]` — draws the local Sign in browser wallet page as served (the one wallet-click browser opened, else one for a… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet-answer received|proposed|signed|submitted|rejected|failed` — the fake Wallet Manager's Mac answers the newest card's request: the card shows it, and the asking fake… — `Sources/VibeSwitcher/Sandbox.swift`
- `wallet [STATE]` — shows a made-up wallet request card as the sheet, in STATE — `Sources/VibeSwitcher/Sandbox.swift`
- `select TEXT` — selects the first row whose title, project or task contains TEXT — `Sources/VibeSwitcher/Sandbox.swift`
- `home` — shows the start page — `Sources/VibeSwitcher/Sandbox.swift`
- `boost off|on|away|present|battery|battery-on|battery-low|veto|mark` — boost mark clicks the main window's Boost mark (Settings › Performance at Boost). Otherwise Boost mode in a… — `Sources/VibeSwitcher/Sandbox.swift`
- `settings [TAB] [OPTION]` — opens Settings on a category — `Sources/VibeSwitcher/Sandbox.swift`
- `settings-help NOTE` — opens the "?" popover of a footer in the Settings category shown ("shot" draws it) — `Sources/VibeSwitcher/Sandbox.swift`
- `settings-search [TEXT]` — types TEXT in Settings' search field, opening Settings if it's closed (no TEXT clears it), and says what it… — `Sources/VibeSwitcher/Sandbox.swift`
- `settings-pick N|ID` — picks the Nth search result (from 1), or the option with that catalog id, as a click on it does — `Sources/VibeSwitcher/Sandbox.swift`
- `toolchain [dismiss]` — shows or dismisses a fake developer tools notice — `Sources/VibeSwitcher/Sandbox.swift`
- `sheet NAME` — shows a sheet on the window — `Sources/VibeSwitcher/Sandbox.swift`
- `theme [` — sets Settings › Appearance › Theme, as its picker does (none: what it is), and says the app's look: the… — `Sources/VibeSwitcher/Sandbox.swift`
- `looks` — the main window's views by what each draws in (effectiveAppearance) and how many: what a stale or forced part… — `Sources/VibeSwitcher/Sandbox.swift`
- `panes [NAME]` — what SwiftUI resolves inside the main window's sidebar and inspector, and those two views drawn again in a… — `Sources/VibeSwitcher/Sandbox.swift`
- `shot-real NAME` — draws each window in the app's own look, nothing overridden: NAME-main-real.png, NAME-settings-real.png…… — `Sources/VibeSwitcher/Sandbox.swift`
- `close settings|sheet` — closes Settings or the sheet — `Sources/VibeSwitcher/Sandbox.swift`
- `shot NAME` — draws each window, light and dark, into the shots folder, its side panes out of their glass (a drawing can't… — `Sources/VibeSwitcher/Sandbox.swift`
- `pointer rows|areas TEXT|hover TEXT|hover-beside TEXT|drag FROM TO|drag-window FROM TO|copy|menu TEXT` — the pointer over the shown chat, as made-up events through its window: rows lists its messages' text views… — `Sources/VibeSwitcher/Sandbox.swift`
- `offline on|off` — the app loses its connection to the sandbox's own host and doesn't get it back (the host and fake sessions… — `Sources/VibeSwitcher/Sandbox.swift`
- `unproved` — connects again with a key the host doesn't hold: it refuses the app's proof and shows it no sessions — `Sources/VibeSwitcher/Sandbox.swift`
- `quit` — quits (the host and fake sessions end with it) — `Sources/VibeSwitcher/Sandbox.swift`

### Sandbox sheets (`sheet NAME`)
- `review-floor` — ReviewFloorSection — `Sources/VibeSwitcher/ReviewFloorSettings.swift`
- `toolchain-note` — ToolchainNoteView — `Sources/VibeSwitcher/MainWindow/SessionListView.swift`
- `new-project` — NewProjectSheet — `Sources/VibeSwitcher/MainWindow/NewProject/NewProjectSheet.swift`
- `menu-bar` — MenuBarStrip — `Sources/VibeSwitcher/Sandbox.swift`
- `menu-bar-dots` — MenuBarStrip — `Sources/VibeSwitcher/Sandbox.swift`
- `results` — ResultsList — `Sources/VibeSwitcher/MainWindow/Lead/LeadViews.swift`
- `all-done` — AllDoneCard — `Sources/VibeSwitcher/MainWindow/Chat/AllDoneCard.swift`
- `statistics` — StatisticsView — `Sources/VibeSwitcher/Statistics/StatisticsView.swift`
- `statistics-estimate` — ComparedSectionView — `Sources/VibeSwitcher/Statistics/StatisticsQualityView.swift`
- `lead-mail` — LeadMailList — `Sources/VibeSwitcher/MainWindow/Lead/LeadMailViews.swift`
- `lead-team` — LeadTeamView — `Sources/VibeSwitcher/MainWindow/Lead/LeadViews.swift`
- `not-repository` — `Sources/VibeSwitcher/Sandbox.swift`
- `empty-repository` — `Sources/VibeSwitcher/Sandbox.swift`
- `missing-claude` — `Sources/VibeSwitcher/Sandbox.swift`
- `missing-tools` — `Sources/VibeSwitcher/Sandbox.swift`
- `installing-tools` — `Sources/VibeSwitcher/Sandbox.swift`
- `choose-folder` — `Sources/VibeSwitcher/Sandbox.swift`
- `new-session-menu` — `Sources/VibeSwitcher/Sandbox.swift`
