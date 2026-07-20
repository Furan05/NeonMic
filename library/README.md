# Song Library

Your personal song library. **Nothing in this folder is ever committed**:
UltraStar charts embed copyrighted lyrics and audio files are licensed
content. Git ignores everything here except this README.

## Conventions

- One folder per song, named `Artist - Title/`:

  ```
  library/
    Daft Punk - Around the World/
      Daft Punk - Around the World.txt
      Daft Punk - Around the World.mp3
      cover.jpg
  ```

- Inside each folder:
  - the UltraStar `.txt` chart
  - the audio file you own (mp3, m4a, flac, …)
  - optional `cover.jpg` and/or a background video file

- The chart's `#MP3:`/`#AUDIO:` header must match the audio filename,
  relative to the song folder.

## Background videos

- `.mp4` (preferred) or `.mov` files in a song folder are picked up
  automatically on scan — `#VIDEO:` doesn't have to name them.
- Charts carrying a `#VIDEOURL:` header or a usdb-syncer `#VIDEO:v=<id>`
  tag can download their video in-app (YouTube downloads use `yt-dlp`:
  `brew install yt-dlp`; merged 1080p additionally wants `ffmpeg`).
- Downloading someone else's video may violate the site's terms of
  service — same rule as charts: only fetch content you have rights to.

Drop your first song into `_INBOX - drop your first song here/` (or just
create its own `Artist - Title/` folder right away).
