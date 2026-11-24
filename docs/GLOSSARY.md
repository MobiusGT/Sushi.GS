# Glossary

One consistent term per concept across UI labels, menus, tooltips, logs, and errors.

| Term | Means | Not |
| --- | --- | --- |
| Source | Original media file (video or audio) whose subtitles are being retimed | Input, origin, reference video |
| Target | Destination media file whose audio timing the subtitles will match | Dst, destination clip, output video |
| Subtitle | Embedded subtitle track from Source or external `.ass`/`.srt`/`.ssa` file | Script, subs file, captions |
| Sync | Run Sushi audio-pattern matching to generate a retimed subtitle file | Shift, align, process |
| Merge | Mux the synced subtitle (and optional encoded audio / resampled sub) into a new MKV via MKVMerge | Mux, remux, combine |
| Job | One paired Source → Target episode work unit in Auto Batch or Manual Batch | Task, item, entry |
| Auto Batch | Automated multi-tier episode pairing workspace for Embedded or External subtitles | Batch Queue, auto queue |
| Manual Batch | Column-based manual row-by-row pairing workspace with a built-in File Browser | Manual queue, launcher |
| Warning | Automated detection of a likely audio-matching or pipeline issue requiring review | Alert, caution, soft fail |
| Log Inspector | Collapsible trailing panel streaming live Sushi, FFmpeg, and MKVMerge output | Console, terminal, output drawer |
| Dependencies | Managed runtime and CLI tools (`uv`, Python 3.13, `sushi-batch`, `ffmpeg`, `ffprobe`, `mkvmerge`, `opusenc`, `aegisub-cli`) | Packages, binaries, tools |
| Preset | Saved bundle of Sync, Merge, and Audio Encode settings | Profile, template, config |
