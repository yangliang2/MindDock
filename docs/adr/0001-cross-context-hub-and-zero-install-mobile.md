# Single Native macOS App with Feishu Serverless Mailbox Bridge

MindDock must deliver a complete 24-hour Work ↔ Life user journey without asking users to deploy a cloud server, buy an HTTPS domain, or sideload and battery-whitelist a background Android APK on domestic ROMs (ColorOS, HyperOS, OriginOS).

We therefore build V0.1 as a **single standalone native Swift macOS application (`MindDock.app`)** backed by local SQLite, paired with **Feishu's outbound long-connection / message-history API (`im/v1/messages`)** as a free, zero-server cloud mailbox and mobile notification bridge:
- At the desk, `MindDock.app` captures voice/text Drops via zero-permission `Carbon RegisterEventHotKey` and on-demand `SFSpeechRecognizer` (0% idle CPU, no permanent orange mic indicator), enriches them via an OpenAI-compatible LLM endpoint, and displays up to 3 Work Berths.
- On screen lock or system sleep (`screenIsLocked` / `willSleepNotification`), `MindDock.app` pushes active Life Berths as a Feishu bot message card that rides Feishu's whitelisted push channel onto the user's Android lock screen.
- While away—even if the MacBook is closed and offline—messages or voice notes sent to the Feishu bot stay buffered in Feishu's conversation history and are automatically pulled, transcribed, Prepped, and docked when `MindDock.app` wakes (or received live over outbound WebSocket/polling when the Mac stays awake).
