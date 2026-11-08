# Bach Editor

Bach Editor is a notation-editor integration for Nzumari Bach AI. The initial integration targets MuseScore 4 and preserves the original score-editing engine from the AiHud Notation Copilot project.

## Interface

Bach Editor uses Nzumari's forest-green, warm-neutral and brass visual identity. The interface includes a persistent connection state, active-score context, a readable conversation view, starter actions and a dedicated message composer. The plugin remains usable in MuseScore 4's floating sidebar-style window.

## Current architecture

- MuseScore exports the active score to MusicXML locally.
- The bundled Python helper parses the score and builds a compact notation snapshot.
- Bach Editor authenticates to Nzumari using a device-pairing flow.
- The snapshot and editing instruction are sent to Nzumari's Bach Editor API over HTTPS.
- Nzumari assembles the same composer profile, confirmed memories, conversation history and authorised work context used by Bach.
- Bach returns a structured edit report; the plugin validates and applies the operations locally in MuseScore.
- Score edits remain local to MuseScore. The API receives the compact score snapshot needed for the requested edit, not the original MusicXML file.

## Install (MuseScore 4)

1. Download the latest **Bach Editor** ZIP from the repository's `feature/nzumari-bach-auth` branch.
2. Extract the `bach-editor-feature-nzumari-bach-auth` folder into your MuseScore 4 `Plugins` directory. Keep `NotationCopilot.qml` and `copilot.py` together in the same folder.
3. Ensure Python 3 is installed and available as `python` in your PATH. The plugin locates `copilot.py` relative to its own folder; no user-specific path edit is needed.
4. Enable **Bach AI** in MuseScore's Plugin Manager and restart MuseScore.
5. Open a score and run **Plugins → Composing/arranging tools → Bach AI**.
6. On first launch, use the **Connect to Nzumari** panel in Bach Editor.
7. Sign in to Nzumari in the browser window and approve this MuseScore installation. If prompted, confirm the pairing code shown in the plugin.
8. Return to MuseScore. Bach Editor will show the connected state when pairing completes. Future launches reuse the saved device credential until it expires or is revoked.

No Dahl, MiniMax, DeepSeek or other AI-provider API key is required on the local machine. Provider credentials remain on the Nzumari server.

## Authentication

The plugin uses a scoped Nzumari device credential rather than a copied browser session or provider API key. Pairing codes expire after 10 minutes. Device credentials currently expire after 90 days and can be revoked server-side. If a credential is lost or expires, pair the plugin again.

The current MuseScore plugin stores its device credential in `bach-editor-token.txt` beside the plugin. The file is excluded by `.gitignore`; do not commit or share it. Protect access to your Windows user account and plugin directory. OS credential-store integration is a follow-up hardening task.

## Data handling

The score snapshot, editing instruction and Bach response are sent to Nzumari over HTTPS. The editing request is stored in the user's Bach conversation so the same Bach history and context can be used across Nzumari and the notation editor. The plugin does not upload the original MusicXML file as a persistent asset. Existing Nzumari personalisation settings govern the context Bach may use.

## Editing behaviour

The existing MuseScore editing engine is retained. It supports note/rest entry, pitch changes, articulations, slurs, dynamics, hairpins, chord symbols, key signatures, lyrics, text and layout operations. Each request is applied as a single MuseScore command so one undo reverses the request. The plugin performs local structural checks and rolls back failed operations.

## Original work and licence

This repository is derived from AiHud's Notation Copilot for MuseScore 4. The original copyright and GPL-3.0 notices are retained in `LICENSE` and the source. Modifications for Nzumari Bach Editor are made under the terms of GPL-3.0-or-later. The AiHud hosted service is not part of this project.
