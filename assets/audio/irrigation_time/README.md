# MP3 irrigation-time assets

The source archive was inspected and validated: 76 MP3 files, all parseable by ffprobe. Total playback length is about 173 seconds.

Expected original names:
- `n_1.mp3` to `n_59.mp3`
- `h_1.mp3` to `h_12.mp3`
- `from.mp3`, `to.mp3`, `and.mp3`, `am.mp3`, `pm.mp3`

The prepared ZIP places them under the intended Flutter destination: `assets/audio/irrigation_time/`.

**The binaries are not yet committed in this repository and playback is not wired to the app.** Android Arabic TTS is still the current temporary fallback. See `docs/irrigation-time-voice.md` for the status and remaining steps.
