# Bach Editor

Bach Editor is a notation-editor integration for Nzumari Bach AI. The initial integration targets MuseScore 4 and preserves the original score-editing engine from the AiHud Notation Copilot project.

## Interface

Bach Editor uses Nzumari's forest-green, warm-neutral and brass visual identity. The interface includes a persistent connection state, active-score context, a readable conversation view, starter actions and a dedicated message composer. The plugin remains usable in MuseScore 4's floating sidebar-style window.

## Current architecture

- MuseScore exports the active score to MusicXML locally.
- The bundled Python helper parses the score and builds a compact, tick-addressable notation snapshot.
- The helper sends the score context and instruction directly to DeepSeek's OpenAI-compatible API.
- DeepSeek returns a structured edit report; the helper validates the JSON and the plugin applies the operations locally in MuseScore.
- Nzumari's web backend, account sign-in, device pairing and cloud context retrieval are not involved in score generation.
- The original MusicXML and score snapshot are sent directly to DeepSeek for the requested edit. Score edits remain local to MuseScore.

## Install (MuseScore 4)

1. Download the latest **Bach Editor** ZIP from the repository's `feature/nzumari-bach-auth` branch.
2. Extract the `bach-editor-feature-nzumari-bach-auth` folder into your MuseScore 4 `Plugins` directory. Keep `NotationCopilot.qml` and `copilot.py` together in the same folder.
3. Ensure Python 3 is installed and available as `python` in your PATH. The plugin locates `copilot.py` relative to its own folder.
4. Copy `bach-editor-config.example.json` to `bach-editor-config.json` in the same plugin folder.
5. Add your DeepSeek API key to `bach-editor-config.json` (see the example below). Never paste the key into chat or commit the real config file.
6. Enable **Bach AI** in MuseScore's Plugin Manager and restart MuseScore.
7. Open a score and run **Plugins → Composing/arranging tools → Bach AI**.

Example local config:

```json
{
  "deepseek_api_key": "YOUR_DEEPSEEK_API_KEY",
  "model": "deepseek-v4-pro"
}
```

You can alternatively set the `DEEPSEEK_API_KEY` environment variable. The environment variable takes precedence over the local config.

## Local API credentials

The plugin reads `bach-editor-config.json` beside `copilot.py`. This file is excluded by `.gitignore`; do not commit or share it. Protect access to your Windows user account and plugin directory. The key is sent only to `https://api.deepseek.com` over HTTPS and is never sent to Nzumari. OS credential-store integration is a follow-up hardening task.

## Data handling

The score snapshot, original MusicXML, editing instruction and response are exchanged directly with DeepSeek over HTTPS. Nzumari does not receive these local plugin requests. Conversation memory and cloud personalisation are not currently part of this local inference path.

## Editing behaviour

The existing MuseScore editing engine is retained. It supports note/rest entry, pitch changes, articulations, slurs, dynamics, hairpins, chord symbols, key signatures, lyrics, text and layout operations. Each request is applied as a single MuseScore command so one undo reverses the request. The plugin performs local structural checks and rolls back failed operations.

## Original work and licence

This repository is derived from AiHud's Notation Copilot for MuseScore 4. The original copyright and GPL-3.0 notices are retained in `LICENSE` and the source. Modifications for Nzumari Bach Editor are made under the terms of GPL-3.0-or-later. The AiHud hosted service is not part of this project.
