# AI Buddy — full-power iPad build (Xcode via GitHub Actions) 🚀

This folder is the **Xcode version** of AI Buddy. Unlike the Swift Playgrounds
version, it can include things Playgrounds forbids — starting with the
**on-device GGUF brain**: download Qwen2.5/Qwen3, Gemma 2/3, or any GGUF model
and run it **on the iPad's GPU (Metal)**, no PC, no cloud. Everything else
(voice, avatars, web search, screenshot-peeking, proactive chat) is identical.

No Mac needed: **GitHub's free cloud Macs build it**, and you install the result
from Windows with a sideloading tool.

---

## One-time setup (~30 minutes)

### 1. Put this folder on GitHub

1. Create a free account at <https://github.com> (if you don't have one).
2. Install **GitHub Desktop** on this PC: <https://desktop.github.com>.
3. GitHub Desktop → *File → Add local repository* → choose this `xcode` folder →
   it offers to *create a repository* here — accept the defaults.
4. Commit everything ("first build"), then **Publish repository**.
   **Untick "Keep this code private"** — public repos get *unlimited* free build
   minutes (private ones only ~200 macOS-minutes/month). There are no secrets in
   the code: API keys live only on the iPad.

### 2. Build the .ipa in the cloud

1. Open your repo on github.com → **Actions** tab.
   (First time: click "I understand my workflows, enable them" if asked.)
2. The **Build AI Buddy IPA** workflow starts automatically on push — or start it
   with *Run workflow*. It takes ~5–10 minutes.
3. Click the finished run → **Artifacts** → download **AIBuddy-ipa** (a zip).
   Unzip it → you have **AIBuddy.ipa**.

### 3. Install on the iPad (from Windows)

First, **delete the Playgrounds version of AI Buddy** from the iPad (same app
identity — they'd conflict). Then either tool works:

**Quick start — Sideloadly** (easiest first install):
1. Install <https://sideloadly.io> on this PC (it needs iTunes + iCloud from
   Apple's website, *not* the Microsoft Store versions — Sideloadly's site explains).
2. Connect the iPad by USB cable, drag `AIBuddy.ipa` in, enter your Apple ID,
   click Start. (Your Apple ID is used only to sign the app for *your* device;
   use an app-specific password if you have 2FA: <https://account.apple.com>.)
3. On the iPad: Settings → General → VPN & Device Management → trust your
   developer profile. Launch AI Buddy.

**Long-term — SideStore** (refreshes itself on the iPad, no PC needed after setup):
- Follow <https://docs.sidestore.io> for the one-time install (it uses a pairing
  file made with the PC, then lives on the iPad). Afterwards you install/update
  `.ipa` files and refresh the 7-day signature entirely on-device.

### ⚠️ The 7-day rule (free Apple ID)

Apps signed with a free Apple ID expire after **7 days** — the icon stays but
won't launch until re-signed. SideStore refreshes this on-device (open it
weekly-ish); Sideloadly requires re-doing step 3 (data is kept). A paid Apple
Developer account ($99/yr) extends this to **1 year** — worth it if the buddy
becomes a daily thing. Your chats/settings/models survive re-signing and
updates; they're only lost if you *delete* the app.

---

## Using the local models

⚙️ → Brain → **Local GGUF model (downloaded)** → *Manage / download models*:

| Model | Size | Notes |
|---|---|---|
| Qwen3.5 0.8B | 0.5 GB | Tiny & fastest; good first test |
| Qwen3.5 2B | 1.3 GB | Fast everyday pick |
| **Qwen3.5 4B** | 2.7 GB | Same model the PC runs; recommended (thinks before replying) |
| Gemma 4 E2B | 3.1 GB | Google's newest efficient model |
| Gemma 4 E4B | 5.0 GB | ⚠️ borderline on 8 GB RAM — try E2B first |

> **These are text-only** (like almost all local GGUF models). They can't see
> images/screen — for that you need a vision brain (Gemini/OpenAI/Claude, or a 👁
> Ollama model). See "Why can't the local model see my screen?" below.

Runs on the M3's GPU via Metal — expect roughly 15–35 words/s (2B–4B models),
with a few seconds of load time on the first message after switching models.

**Downloads come from [ModelScope](https://modelscope.cn), not Hugging Face.**
In 2026 Hugging Face moved to "Xet" storage, which blocks plain downloads without
an account (you'd get an HTTP 403). ModelScope mirrors the same GGUF files over an
ordinary CDN, so they just work. Any direct ModelScope `.gguf` link works in the
Custom box (≤ ~3 GB, Q4 recommended) — repo → Files → long-press a file's download
icon → Copy Link.

## Why can't the local model see my screen? 👁

Screen viewing (broadcast or screenshot) hands the buddy an **image**, and
whether it can actually *see* that image depends entirely on the **brain**:

| Brain | Sees images? |
|---|---|
| Gemini / OpenAI / Claude (cloud) | ✅ yes |
| Ollama with a 👁 vision model | ✅ yes |
| **Downloaded local GGUF** (Qwen3.5, Gemma 4, …) | ❌ **text-only** |
| Apple on-device | ❌ text-only |

GGUF chat models are text-only *by default* — but local vision now works with a
**vision pack**: download **"Gemma 4 vision pack (mmproj)"** in Manage models
(~1 GB), then ⚙️ → Brain → **Vision pack 👁** → select it, with a **Gemma 4**
model as your main model. The buddy can then see attached photos, screenshots,
and the live screen broadcast — fully on-device. (The pack only works with the
model family it belongs to; expect image replies to take several extra seconds.)
Cloud brains (Gemini/OpenAI/Claude) remain the fastest/most accurate option.

## Voice cloning 🎙️ (build 6)

The buddy can speak in a **cloned voice**. ⚙️ → Voice output → **Voice engine →
Cloned voice** → **Cloned voices**:

1. **Download the voice model** (ZipVoice, ~110 MB, one time — it downloads, then
   unpacks on-device).
2. **Import a voice clip** — a clean 5–15 s recording of one speaker (no music/
   noise). The app resamples it and **auto-transcribes** it; fix the transcript
   with ✏️ if it's off (accuracy matters for the clone).
3. **Select** the clip (tap its circle) and hit **Hear the cloned voice**.

Notes & limits:
- The engine is **sherpa-onnx + ZipVoice**, running on the **CPU** — so cloned
  voice also works in the **background** (unlike the GPU-bound local LLM). If
  the model/clip aren't ready or generation fails, it falls back to the **system
  voice**, so replies are never silent.
- Generation is a bit slower than real-time, so expect a short delay before each
  spoken sentence versus the instant system voice.
- **Only clone voices you have permission to use.**
- *Why not Qwen3-TTS (the model we first tried)?* Its MLX dependency chain
  (`swift-transformers` + Jinja) doesn't compile on Xcode 26.6 right now. That
  code is kept dormant behind `#if canImport(Qwen3TTS)` in `CloneEngine.swift`
  with re-enable notes, in case it becomes buildable later.

## Rolling back voice cloning

Voice cloning links sherpa-onnx and pulls in SWCompression. If it ever breaks
the build, everything else keeps working (the app falls back to the system
voice): in `project.yml`, remove the two sherpa `- framework: vendor/…` deps,
the `- package: SWCompression` dep, the `packages:` block, and the
`SWIFT_OBJC_BRIDGING_HEADER` / `-lc++` settings; delete the sherpa download step
from the workflow. Then set `CloneTTSAvailability.isCompiledIn` to `false`. (The
`VoiceClone.swift` etc. files can stay.)

## Updating the app

Ask Claude on the PC to change the code → commit & push in GitHub Desktop →
Actions builds a fresh ipa → sideload it over the old one (data persists).

## Live screen watching (build 2) 📺

Tap the **record button** in the app header → pick **AI Buddy Screen** → *Start
Broadcast*. iPadOS shows the red status-bar pill (that's the system consent
indicator — required by Apple), and from then on the buddy has a **live view of
whatever you do on the iPad**, in any app:

- Ask *"what am I looking at?"* — it sees the current screen instantly, no
  screenshots needed. (Vision brains only: Gemini/OpenAI/Claude/vision-Ollama.)
- Proactive comments react to what you're actually doing, like the PC version.
- **The magic combo:** turn the mic on 🎤, start the broadcast, then go use other
  apps — the buddy keeps running in the background (mic = background audio),
  watches your screen, and you can talk to it from anywhere.
- Stop it from the same button or the red pill. Frames go only from the
  broadcast extension to the app over localhost — nothing is recorded or stored.

**Sideloading note:** the broadcast feature ships as an app *extension* inside
the ipa. In **Sideloadly**, make sure *Advanced → "Remove Plug-Ins"* is
**unchecked**; SideStore keeps extensions by default. (Each extension uses one
of the free Apple ID's ~10 App IDs per week — you have plenty.)

## Background behavior (build 2)

- A reply that's underway **finishes and speaks** even if you switch apps
  (~30 s grace + it keeps running while audio plays).
- With the **mic armed**, the app stays alive in the background indefinitely
  (it's recording — iPadOS shows the orange mic indicator) — full voice chat
  while you're in other apps.
- With mic off and nothing speaking, iPadOS suspends the app as usual and the
  notification nudges take over.
- **Local models in the background:** iOS blocks the GPU while backgrounded, so
  when you switch away the app automatically **reloads the local model on the CPU**
  and keeps answering (a little slower). This only kicks in while the **mic is
  armed** (that's what keeps the app alive in the background); with the mic off,
  a backgrounded local model will ask you to come back or use a cloud brain.
  Cloud and Apple brains work in the background regardless.

## Audio / earbuds

Output follows your earbuds (wired, Bluetooth, AirPods) like other media apps,
whether or not the mic is on. One deliberate trade-off: **while the buddy is
speaking through earbuds, voice barge-in is paused** (tap 🎤 or start typing to
interrupt instead). This is because iOS can't stream high-quality Bluetooth
output *and* record at the same time — so during replies we prioritize good
earbud audio, and listen again the moment it stops talking. On the built-in
speaker, barge-in works normally throughout.

## Troubleshooting

- **Workflow fails at "Build"**: open the failed step's log, copy the first
  `error:` lines, and paste them to Claude — same drill as the Playgrounds rounds.
- **"Apple on-device" says it was built without FoundationModels**: the runner's
  default Xcode was too old. The workflow now selects the newest Xcode
  automatically — just re-run it (Actions → Run workflow) and reinstall.
- **"Unable to install" / signature errors on the iPad**: make sure the
  Playgrounds copy of the app is deleted; reboot the iPad; retry.
- **App won't open after a week**: that's the 7-day rule — refresh in SideStore
  or re-run Sideloadly.
- **Model download fails**: check free space (Settings → General → iPad Storage)
  and Wi-Fi; the download resumes from scratch on retry.

## Folder layout

```
xcode/
├─ project.yml                  ← XcodeGen spec (targets, Info.plist, framework)
├─ .github/workflows/build-ipa.yml ← the cloud build recipe
├─ AIBuddy/                     ← all Swift sources (shared with the Playgrounds version)
│  ├─ LlamaBrain.swift          ← GGUF engine wrapper (llama.cpp, Metal)
│  ├─ LocalModels.swift         ← model downloads + picker
│  └─ … (everything else identical to ../AIBuddy.swiftpm)
└─ vendor/llama.xcframework     ← downloaded by CI, not committed
```
