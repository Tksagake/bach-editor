# Bach Editor

Bach Editor is a notation-editor integration for Nzumari Bach AI. The initial integration targets MuseScore 4 and preserves the original score-editing engine from the AiHud Notation Copilot project.

## Current architecture

- MuseScore exports the active score to MusicXML locally.
- The bundled Python helper parses the score and builds a compact notation snapshot.
- Bach Editor authenticates to Nzumari using a device-pairing flow.
- The snapshot and editing instruction are sent to Nzumari's Bach Editor API over HTTPS.
- Nzumari assembles the same composer profile, confirmed memories, conversation history and authorised work context used by Bach.
- Bach returns a structured edit report; the plugin validates and applies the operations locally in MuseScore.
- Score edits remain local to MuseScore. The API receives the compact score snapshot needed for the requested edit, not the original MusicXML file.

## Install (MuseScore 4)

1. Copy the plugin folder into your MuseScore 4 plugins directory.
2. Update the `copilot` property in `NotationCopilot.qml` if your Python helper is installed elsewhere.
3. Ensure Python 3 is installed and available as `python` in your PATH.
4. Enable Bach Editor in MuseScore's Plugin Manager and restart MuseScore.
5. Open a score and run **Plugins → Composing/arranging tools → Bach Editor**.
6. Select **Connect**. A browser window opens to Nzumari.
7. Sign in to Nzumari, review the pairing code and approve the MuseScore installation.
8. Return to MuseScore. Bach Editor will confirm when pairing is complete.

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
