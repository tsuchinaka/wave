# wave

Deezer client for iOS 5.1 (armv7), built with Theos. Package `com.bytebox.wave`, version in `control`.

## Build

    export THEOS=/home/main/theos
    make -j4
    make package

SDK: `/home/main/theos/sdks/iPhoneOS5.1.sdk` (`Makefile` `TARGET := iphone:clang:5.1:5.1`). `./deploy.sh` builds and installs on the device. `./deploy.sh --clean` forces a clean build.

Docs for agents live in `docs/` and `AGENTS.md`.

## Layout

- `Core/` — Deezer gateway and public API, ARL session, quality probe, TLS 1.2, decrypt, downloads, artwork, lyrics, Last.fm, PCM playback.
- `Skin/` — iOS 5.1 chrome. Stock UIKit controls, gloss and gradient images, Helvetica Neue.
- `UI/` — four tabs (Home, Search, Library, Settings), modal player, queue, lyrics, downloads.
- `Support/waIOS5Compat.h` — subscripts, alignment enums, and `@YES` boxing the 5.1 SDK does not provide.
- `Vendor/` — OrigamiEngine (MRC), libFLAC 1.4.3, quirc, mbedTLS 2.28.

## Playback

`waDZAPI` resolves a track token, asks `media.deezer.com/v1/get_url` for the highest format the account grants, and wraps the signed CDN URL as `deezer://stream/<id>.<ext>?u=...`. `HTTPSource` fetches it, decrypts BF_CBC_STRIPE in place, and writes a cache the decoder can seek. Hosts the iOS 5.1 stack cannot negotiate go through `waTLS`.

Quality is probed at login: FLAC, then 320, then 128. The preference cannot exceed what the probe allows.

## Tests

There is no test target. Build with `make` and run on the device. Log: `Documents/wave.log`, then Caches, then `/tmp/wave.log`.
