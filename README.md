# Notation Copilot for MuseScore 4

**Notation Copilot** is a MuseScore Studio 4 plugin by [AiHud](https://aihud.net) that does arranging jobs you describe in plain English, in place, in the score you have open. One Ctrl+Z undoes the whole request.

- **Section voicing**: "voice the alto 1 melody in bars 9-16 for the saxes, drop 2". Melody on top, close or drop-2 voicings under it from your chord symbols (or the harmony in the other parts), one line per part, every note in range.
- **Pads and backgrounds**: "write a sustained string pad under bars 17-24", "brass hits on 2 and 4 in bars 25-28". Chord tones with smooth voice leading.
- **Easier parts**: "make an easier version of the trumpet 1 part in bars 33-40 for beginners". Fewer fast notes, smaller range, same shape.
- **Bass lines**: "add a walking bass line in the contrabass, bars 1-16".
- Small edits too: doubling, transposing, slurs and articulations.

The editing is powered by the hosted **AiHud Notation Copilot** service at https://copilot.aihud.net, where you can get a free key.

Demo video: https://copilot.aihud.net/demo.mp4

## Install (MuseScore Studio 4.x)

1. Copy the `NotationCopilot` folder from this zip into your MuseScore plugins folder:
   - Windows: `Documents\MuseScore4\Plugins\`
   - macOS / Linux: `~/Documents/MuseScore4/Plugins/`
2. Restart MuseScore.
3. Go to **Home > Plugins**, find **Notation Copilot**, and click **Enable**.
4. Open a score and run **Plugins > Composing/arranging tools > Notation Copilot**.

## Get a free key

If you downloaded this zip right after signing up on copilot.aihud.net, your key is already inside (`NotationCopilot/copilot-key.txt`) and you can skip this section.

1. Sign up at https://copilot.aihud.net
2. Copy your key (it starts with `nc_live_`).
3. The first time you open the plugin it asks for the key; paste it into the chat. It is saved next to the plugin in `copilot-key.txt`, so you only do this once.

If a request is ambiguous (which bars? which part has the melody?), or the target bars already have music (replace it, or add a second voice?), the copilot asks with clickable options instead of guessing.

Free plan: a free trial of 100 applied edits, then 10 free edits every month (resets on the 1st, UTC). Your key works right away for the first few edits; after that, click the activation link in the signup email (check spam) to keep using the free plan.

Monthly plans: Pro is $19 a month for 200 applied edits; Composer is $99 a month for 1,000 applied edits (fair use). Questions and replies that change nothing never count. Edits reset on the 1st of each month (UTC).

Credit packs (AiHud credits, 1 credit = $0.001): a typical edit uses about 150 to 450 credits, depending on how much music you ask for; big full-band requests can use 750. Clarifying questions are billed like a request; requests that change nothing are not charged. $10 (10,000 credits) is roughly 25 to 65 edits.

Plans and packs: https://copilot.aihud.net/buy

## What it can't do (yet)

- Dock as a real panel in MuseScore 4.7.x (the window positions itself as a sidebar instead)
- Edit dynamics, lyrics, chord symbols, layout or playback settings
- Write idiomatic counter-melodies or full orchestrations from scratch (it voices, pads, simplifies and writes bass lines from the harmony that is there)
- Guarantee musically perfect results. Always review the change; Ctrl+Z undoes it in one step.
- Work offline: it needs an internet connection to the AiHud service.

## Privacy

To compute an edit, the plugin exports your **open score as MusicXML** and sends it, with your request, to AiHud's server (`https://copilot.aihud.net`) over HTTPS. The edit list comes back and the plugin applies it locally. Nothing is sent until you submit a request. Your score is sent to AiHud only to make the edit and is not stored. We keep the text of your requests and our replies to improve the service, and look up the approximate location of visitor IP addresses.

## License

GPL-3.0, Copyright (C) 2026 AiHud. See `LICENSE`. The hosted service is operated by AiHud and is not part of this package.

Made by [AiHud](https://aihud.net). Questions: hi@aihud.net
