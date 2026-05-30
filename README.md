# Pharos

iOS-based voice AI assistant for Meta Ray-Ban Display smart glasses.

## Why This Project

Meta Ray-Ban Display glasses ship with Meta AI built in, but it's locked to Meta's own model and assistant flow. Pharos opens the glasses to any LLM you choose (Claude, GPT-4o, Gemini, etc.) while keeping the hands-free, eyes-up experience that makes the glasses useful in the first place.

The goal is a personal AI companion you can talk to anywhere — walking, cooking, driving — that uses your preferred model, supports your native language, and can see what you see through the glasses' camera.

## Architecture

```
[Glasses mic/cam/speaker] ⇄ [iPhone — Pharos]
                                  ⇅  WebSocket
                            [Mac — bridge.py]
                                  ⇅
                       [LLM API + edge-tts]
```

- **Glasses**: voice input, optional photo capture, audio output
- **iPhone (Pharos)**: wake-word detection, speech-to-text, session management, audio playback
- **Mac bridge**: LLM routing, streaming responses, text-to-speech (edge-tts)
- **Network**: WebSocket on local LAN (or Tailscale), no cloud dependency for the bridge itself

## Features

**Voice interaction**
- Wake-word detection with two modes:
  - *Brief*: single-sentence response, auto-return to listening
  - *Continuous*: extended conversation mode
- Wake words customizable from the app UI ("블루" / "라이브블루" by default)
- On-device speech recognition via Apple's `SFSpeechRecognizer`
- Language follows the iOS system language automatically (Korean, English, Japanese, Chinese, and any locale supported by `SFSpeechRecognizer`)
- Edge-TTS audio response played through the glasses' speakers

**LLM flexibility**
- Multi-model support: Claude Sonnet/Opus, GPT-4o, Gemini Flash
- Model switching from the app UI
- Streaming responses for low perceived latency

**Glasses integration (Meta Wearables DAT SDK)**
- BLE pairing and session management
- Camera capture from the glasses for visual context
- Photo streaming back to the phone

**Resilience**
- Automatic WebSocket reconnect on network drop or screen lock
- Persistent audio session for background operation
- Ping keepalive every 15s; 5-minute inactivity session timeout

## Tech Stack

- **iOS app**: Swift, SwiftUI, AVFoundation, Speech framework
- **Glasses SDK**: Meta Wearables DAT (MWDATCore, MWDATCamera)
- **Bridge server**: Python, websockets, edge-tts (separate repo)
- **AI routing**: OpenRouter-compatible API layer

## Requirements

- iOS 17.0+
- Meta Ray-Ban Display glasses (other Ray-Ban Meta / Oakley HSTN models are *not* supported by the DAT SDK)
- An Apple Developer Program membership (required for the Associated Domains capability used by Meta's registration flow)
- A Mac running the bridge server on the same LAN or Tailscale network

## Setup

This repo does not include the Meta Wearables credentials. To build:

1. Register your app in the [Meta Wearables Developer Center](https://developers.meta.com/wearables/).
2. Open `Pharos/Info.plist` and replace `YOUR_META_CLIENT_TOKEN_HERE` with your own Client Token.
3. Update `MetaAppID`, `TeamID`, and `AppLinkURLScheme` to match your registered app.
4. Add an Associated Domains capability in Xcode (`applinks:<your-aasa-host>`) — requires a paid Apple Developer Program membership.
5. Host an `apple-app-site-association` file on your HTTPS domain that references `<TeamID>.<BundleID>`.

## Status

Early personal project. Working: wake-word loop, LLM chat, TTS playback, auto-reconnect, basic camera. In progress: glasses registration flow (Universal Link callback), photo-to-LLM context, multilingual TTS sync.

## License

Personal use only. Not affiliated with Meta or Anthropic.
