# wave

Deezer client for iOS 5.1 (armv7), built with Theos.

## Build

    export THEOS=/home/main/theos
    make -j4
    make package

SDK: `/home/main/theos/sdks/iPhoneOS5.1.sdk` (deployment 5.1).

## Layout

- `Core/` — Deezer transport, ARL session, quality probing, streaming, decrypt,
  downloads, artwork, PCM playback.
- `Skin/` — iOS 5.1 chrome: glossy bars, grouped paper, capsule buttons,
  Helvetica Neue typography.
- `UI/` — navigation, browsing, player, queue, lyrics, settings.
- `Vendor/` — OrigamiEngine decoders, libFLAC 1.4.3 (armv7, min 5.1), quirc.
- `Support/waIOS5Compat.h` — the few shims iOS 5 lacks (subscripts, alignment
  enums, safe `@YES` boxing).

## Playback

`waDZAPI` resolves a track token, asks `media.deezer.com/v1/get_url` for the
highest format the account grants, and wraps the signed CDN URL in
`deezer://stream/<id>.<ext>?u=...`. `HTTPSource` fetches it, decrypts
BF_CBC_STRIPE in place with one persistent Blowfish context, and writes a
plain-PCM-able cache. Seeking reuses that cache through HTTP range requests.

Quality is probed against the live account at login: FLAC first, then 320,
then 128. The preference can never exceed what the probe allows.

## Tests in the app

There is no test target on iOS 5. Build with `make` and run on the device.
