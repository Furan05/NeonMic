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

Drop your first song into `_INBOX - drop your first song here/` (or just
create its own `Artist - Title/` folder right away).
