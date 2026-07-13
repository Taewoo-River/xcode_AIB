# AI Buddy — full-power iPad build (Xcode via GitHub Actions) 🚀

This folder is the **Xcode version** of AI Buddy. Unlike the Swift Playgrounds
version, it can include things Playgrounds forbids — starting with the
**on-device GGUF brain**: download Gemma 4 E2B/E4B, Qwen3.5, or any GGUF model
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
| Qwen3.5 2B | 1.3 GB | Fastest; good first test |
| **Gemma 4 E2B (QAT)** | 2.6 GB | Recommended quality/speed balance |
| Qwen3.5 4B | 2.7 GB | Same model the PC runs; thinks before replying |
| Gemma 4 E4B (QAT) | 4.2 GB | ⚠️ borderline on 8 GB RAM — try E2B first |

Runs on the M3's GPU via Metal — expect roughly 15–35 words/s (2B–4B models),
with a few seconds of load time on the first message after switching models.
Any direct-download `.gguf` link works in the Custom box (≤ ~3 GB, Q4 files).

## Updating the app

Ask Claude on the PC to change the code → commit & push in GitHub Desktop →
Actions builds a fresh ipa → sideload it over the old one (data persists).

## What's next

**Build 2 — live screen watching** (ReplayKit broadcast extension): now possible
in this Xcode setup. You start a screen broadcast from Control Center, and the
buddy sees frames continuously — no screenshots needed. Say the word once
build 1 is running on the iPad.

## Troubleshooting

- **Workflow fails at "Build"**: open the failed step's log, copy the first
  `error:` lines, and paste them to Claude — same drill as the Playgrounds rounds.
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
