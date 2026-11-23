#!/usr/bin/env python3
"""
Sushi.GS ("Gas Station Sushi") headless Python worker bridge.

Bundled inside Sushi.GS.app/Contents/Resources/worker.py and executed using the
app-managed uv Python 3.13 virtual environment under:
    ~/Library/Application Support/Sushi.GS/venv/

This bridge delegates subtitle retiming, stream probing, pre-merge audio encoding,
subtitle resampling, and MKV merging to upstream `sushi-batch` and `sushi-sub-next`
without duplicating their internals, while streaming newline-delimited JSON (NDJSON)
events over stdout and keeping execution strictly headless (no PyQt6 / no Dock icon).
"""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import math
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Force headless environment before any package import.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM", "1")
os.environ.setdefault("PYTHONUNBUFFERED", "1")
os.environ.setdefault("MPLBACKEND", "Agg")

# Track active child subprocesses so SIGTERM/SIGINT terminates cleanly.
_ACTIVE_PROCS: list[subprocess.Popen[Any]] = []
_CANCELLED = False
_TEMP_SHIM_DIR: str | None = None
_LOG_LINE_INDEX = 0


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def emit(event_type: str, **payload: Any) -> None:
    record: dict[str, Any] = {"type": event_type, "timestamp": _now_iso()}
    record.update(payload)
    sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_log(source: str, line: str, level: str = "info") -> int:
    global _LOG_LINE_INDEX
    idx = _LOG_LINE_INDEX
    _LOG_LINE_INDEX += 1
    emit("log", source=source, level=level, line=line, lineIndex=idx)
    return idx


def _handle_signal(signum: int, _frame: Any) -> None:
    global _CANCELLED
    _CANCELLED = True
    for proc in list(_ACTIVE_PROCS):
        try:
            proc.terminate()
        except OSError:
            pass
    time.sleep(0.15)
    for proc in list(_ACTIVE_PROCS):
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
    emit("error", code="cancelled", message="Operation cancelled by user.")
    sys.exit(130)


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def configure_binary_path(
    bin_dirs: list[str] | None = None,
    tool_overrides: dict[str, str] | None = None,
) -> list[str]:
    """
    Prepend app-managed binary dirs and custom tool override shims to PATH *before*
    importing sushi_batch, because upstream evaluates `is_installed` at import time.
    """
    global _TEMP_SHIM_DIR
    ordered_dirs: list[str] = []

    if tool_overrides:
        valid_overrides = {
            name: path
            for name, path in tool_overrides.items()
            if path and os.path.isfile(path) and os.access(path, os.X_OK)
        }
        if valid_overrides:
            _TEMP_SHIM_DIR = tempfile.mkdtemp(prefix="sushigs-shims-")
            for tool_name, target_path in valid_overrides.items():
                link_path = Path(_TEMP_SHIM_DIR) / tool_name
                try:
                    os.symlink(target_path, link_path)
                except OSError:
                    pass
            ordered_dirs.append(_TEMP_SHIM_DIR)

    # Ensure venv bin dir (where `sushi` script lives) is on PATH.
    venv_bin = str(Path(sys.executable).resolve().parent)
    ordered_dirs.append(venv_bin)

    for d in bin_dirs or []:
        if d and os.path.isdir(d) and d not in ordered_dirs:
            ordered_dirs.append(d)

    for default_dir in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"):
        if os.path.isdir(default_dir) and default_dir not in ordered_dirs:
            ordered_dirs.append(default_dir)

    existing = os.environ.get("PATH", "")
    for segment in existing.split(os.pathsep):
        if segment and segment not in ordered_dirs:
            ordered_dirs.append(segment)

    os.environ["PATH"] = os.pathsep.join(ordered_dirs)
    return ordered_dirs


def _cleanup_shims() -> None:
    global _TEMP_SHIM_DIR
    if _TEMP_SHIM_DIR and os.path.isdir(_TEMP_SHIM_DIR):
        shutil.rmtree(_TEMP_SHIM_DIR, ignore_errors=True)
        _TEMP_SHIM_DIR = None


def _pkg_version(name: str) -> str | None:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return None


def cmd_self_check(bin_dirs: list[str], tool_overrides: dict[str, str]) -> int:
    configure_binary_path(bin_dirs, tool_overrides)
    try:
        py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
        if sys.version_info < (3, 13):
            emit("error", code="python_version", message=f"Python 3.13+ required, found {py_ver}")
            return 1

        # Import headless core modules only — never sushi_batch.ui.file_dialogs (PyQt6).
        import numpy as np
        import scipy
        import cv2
        import sushi
        import sushi_batch.models.settings as sb_settings
        import sushi_batch.models.enums as sb_enums
        import sushi_batch.models.stream as sb_stream
        import sushi_batch.external.ffprobe as sb_ffprobe
        import sushi_batch.external.ffmpeg as sb_ffmpeg
        import sushi_batch.external.sub_sync as sb_sub_sync
        import sushi_batch.external.mkv_merge as sb_mkv_merge
        import sushi_batch.external.opusenc as sb_opusenc
        import sushi_batch.external.sub_resample as sb_sub_resample
        import sushi_batch.services.stream_service as sb_stream_service

        # Verify OpenCV template matching works headlessly without GUI initialization.
        haystack = np.zeros((1, 64), dtype=np.uint8)
        needle = np.zeros((1, 16), dtype=np.uint8)
        res = cv2.matchTemplate(haystack, needle, cv2.TM_SQDIFF_NORMED)
        _min_val, _, _min_loc, _ = cv2.minMaxLoc(res)

        # Verify expected upstream symbols exist so upstream updates are validated cleanly.
        required_attrs = [
            (sb_settings, "config"),
            (sb_enums, "AudioEncodeCodec"),
            (sb_stream, "AudioStream"),
            (sb_ffprobe, "FFprobe"),
            (sb_ffmpeg, "FFmpeg"),
            (sb_sub_sync, "Sushi"),
            (sb_mkv_merge, "MKVMerge"),
            (sb_opusenc, "XiphOpusEncoder"),
            (sb_sub_resample, "SubResampler"),
            (sb_stream_service, "StreamService"),
        ]
        missing = [f"{mod.__name__}.{attr}" for mod, attr in required_attrs if not hasattr(mod, attr)]
        if missing:
            emit("error", code="api_incompatible", message=f"Missing upstream APIs: {', '.join(missing)}")
            return 1

        # Confirm PyQt6 was NOT imported by any headless module.
        pyqt_loaded = any(k.startswith("PyQt6") for k in sys.modules)

        versions = {
            "python": py_ver,
            "sushi_batch": _pkg_version("sushi-batch") or "unknown",
            "sushi_sub_next": _pkg_version("sushi-sub-next") or getattr(sushi, "VERSION", "unknown"),
            "numpy": _pkg_version("numpy") or getattr(np, "__version__", "unknown"),
            "scipy": _pkg_version("scipy") or getattr(scipy, "__version__", "unknown"),
            "opencv": _pkg_version("opencv-python-headless")
            or _pkg_version("opencv-python")
            or getattr(cv2, "__version__", "unknown"),
        }
        tools = {
            "ffmpeg": shutil.which("ffmpeg"),
            "ffprobe": shutil.which("ffprobe"),
            "mkvmerge": shutil.which("mkvmerge"),
            "opusenc": shutil.which("opusenc"),
            "aegisub-cli": shutil.which("aegisub-cli"),
        }
        emit(
            "result",
            ok=True,
            versions=versions,
            tools=tools,
            headlessVerified=(not pyqt_loaded),
        )
        return 0
    except Exception as exc:
        emit("error", code="self_check_failed", message=f"{type(exc).__name__}: {exc}")
        return 1
    finally:
        _cleanup_shims()


def cmd_probe(filepath: str, bin_dirs: list[str], tool_overrides: dict[str, str]) -> int:
    configure_binary_path(bin_dirs, tool_overrides)
    try:
        target = Path(filepath)
        if not target.is_file():
            emit("error", code="file_not_found", message=f"File not found: {filepath}")
            return 1

        ffprobe_bin = shutil.which("ffprobe")
        if not ffprobe_bin:
            emit("error", code="ffprobe_missing", message="ffprobe is not installed.")
            return 1

        # Probe streams, format duration, and chapters with ffprobe JSON.
        proc = subprocess.run(
            [
                ffprobe_bin,
                "-v",
                "quiet",
                "-print_format",
                "json=compact=1",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                filepath,
            ],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            emit(
                "error",
                code="probe_failed",
                message=proc.stderr.strip() or f"ffprobe failed for {target.name}",
            )
            return 1

        raw = json.loads(proc.stdout)
        streams = raw.get("streams", [])
        fmt = raw.get("format", {})
        chapters = raw.get("chapters", [])

        # Enrich with mkvmerge -J when probing MKV containers and mkvmerge is installed.
        mkv_track_names: dict[int, dict[str, Any]] = {}
        mkvmerge_bin = shutil.which("mkvmerge")
        if mkvmerge_bin and target.suffix.lower() in {".mkv", ".mka", ".mks", ".webm"}:
            mkv_proc = subprocess.run(
                [mkvmerge_bin, "-J", filepath],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            if mkv_proc.returncode == 0 and mkv_proc.stdout.strip():
                try:
                    mkv_json = json.loads(mkv_proc.stdout)
                    for track in mkv_json.get("tracks", []):
                        tid = track.get("id")
                        if isinstance(tid, int):
                            mkv_track_names[tid] = track.get("properties", {})
                except json.JSONDecodeError:
                    pass

        from sushi_batch.services.stream_service import SUBTITLE_CODEC_MAP

        video_tracks: list[dict[str, Any]] = []
        audio_tracks: list[dict[str, Any]] = []
        subtitle_tracks: list[dict[str, Any]] = []

        for s in streams:
            ctype = s.get("codec_type", "")
            idx = int(s.get("index", 0))
            tags = s.get("tags") or {}
            disp = s.get("disposition") or {}
            mkv_props = mkv_track_names.get(idx, {})

            title = tags.get("title") or mkv_props.get("track_name") or ""
            lang = tags.get("language") or mkv_props.get("language") or "und"
            codec = s.get("codec_name") or ""
            is_default = disp.get("default") == 1 or bool(mkv_props.get("default_track"))
            is_forced = disp.get("forced") == 1 or bool(mkv_props.get("forced_track"))

            if ctype == "video":
                video_tracks.append(
                    {
                        "id": idx,
                        "codec": codec,
                        "width": int(s.get("width") or 0),
                        "height": int(s.get("height") or 0),
                        "default": is_default,
                        "title": title,
                    }
                )
            elif ctype == "audio":
                ch_layout = s.get("channel_layout") or ""
                if not ch_layout and s.get("channels"):
                    ch_map = {1: "mono", 2: "stereo", 6: "5.1", 8: "7.1"}
                    ch_layout = ch_map.get(int(s["channels"]), f"{s['channels']}ch")
                sample_rate = int(s["sample_rate"]) if s.get("sample_rate") else None
                bits = int(s["bits_per_raw_sample"]) if s.get("bits_per_raw_sample") else None
                audio_tracks.append(
                    {
                        "id": idx,
                        "codec": codec,
                        "lang": lang,
                        "title": title,
                        "channelLayout": ch_layout,
                        "channels": int(s.get("channels") or 0),
                        "sampleRate": sample_rate,
                        "bitDepth": bits,
                        "default": is_default,
                        "forced": is_forced,
                    }
                )
            elif ctype == "subtitle":
                ext = SUBTITLE_CODEC_MAP.get(codec)
                subtitle_tracks.append(
                    {
                        "id": idx,
                        "codec": codec,
                        "lang": lang,
                        "title": title,
                        "extension": ext or "",
                        "supported": ext is not None,
                        "default": is_default,
                        "forced": is_forced,
                    }
                )

        duration = None
        if fmt.get("duration"):
            try:
                duration = float(fmt["duration"])
            except ValueError:
                duration = None

        emit(
            "result",
            ok=True,
            probe={
                "filepath": filepath,
                "filename": target.name,
                "formatName": fmt.get("format_name", ""),
                "durationSeconds": duration,
                "chapterCount": len(chapters),
                "videoTracks": video_tracks,
                "audioTracks": audio_tracks,
                "subtitleTracks": subtitle_tracks,
            },
        )
        return 0
    except Exception as exc:
        emit("error", code="probe_exception", message=f"{type(exc).__name__}: {exc}")
        return 1
    finally:
        _cleanup_shims()


def _apply_upstream_settings(cfg: dict[str, Any], runtime_data_dir: str) -> None:
    """Apply Swift UI job settings onto upstream sushi_batch.models.settings.config."""
    from sushi_batch.models import settings as sb_settings
    from sushi_batch.models.enums import (
        AudioChannelLayout,
        AudioEncodeCodec,
        AudioEncoder,
        TracksToEncode,
    )

    s = sb_settings.config
    s.data_path = runtime_data_dir
    s.file_path = str(Path(runtime_data_dir) / "settings.json")
    Path(runtime_data_dir).mkdir(parents=True, exist_ok=True)

    sync_cfg = cfg.get("sync", {})
    merge_cfg = cfg.get("merge", {})
    encode_cfg = cfg.get("audioEncode", {})
    general_cfg = cfg.get("general", {})

    s.general["save_sushi_logs"] = bool(general_cfg.get("saveSushiLogs", True))
    s.general["save_merge_logs"] = bool(general_cfg.get("saveMergeLogs", True))

    s.sync_workflow["use_high_quality_resample"] = bool(sync_cfg.get("useHighQualityResample", True))
    s.sync_workflow["enable_sushi_advanced_args"] = bool(sync_cfg.get("enableAdvancedArgs", False))
    adv = sync_cfg.get("advancedArgs", {})
    s.sync_workflow["sushi_advanced_args"] = {
        "window": adv.get("window"),
        "max_window": adv.get("maxWindow"),
        "rewind_thresh": adv.get("rewindThresh"),
        "smooth_radius": adv.get("smoothRadius"),
        "max_ts_duration": adv.get("maxTsDuration"),
        "max_ts_distance": adv.get("maxTsDistance"),
    }

    s.merge_workflow["merge_files_after_execution"] = bool(merge_cfg.get("autoMergeOnSync", False))
    s.merge_workflow["encode_lossless_audio_before_merging"] = bool(encode_cfg.get("enabled", False))
    tracks_scope = encode_cfg.get("tracksScope", "syncTargetOnly")
    s.merge_workflow["tracks_to_encode_before_merging"] = (
        TracksToEncode.ALL if tracks_scope == "all" else TracksToEncode.SYNC_TARGET_ONLY
    )

    codec_map = {
        "opus": AudioEncodeCodec.OPUS,
        "aac": AudioEncodeCodec.AAC,
        "eac3": AudioEncodeCodec.EAC3,
    }
    chosen_codec = codec_map.get(str(encode_cfg.get("codec", "opus")).lower(), AudioEncodeCodec.OPUS)
    s.merge_workflow["encode_codec"] = chosen_codec

    # Map per-codec profiles & bitrates cleanly into upstream encode_codec_settings
    profiles = encode_cfg.get("profiles", {})
    for codec_key, codec_enum in codec_map.items():
        profile = profiles.get(codec_key)
        if not profile:
            continue
        target_profile = s.merge_workflow["encode_codec_settings"][codec_enum.name]
        enc_name = str(profile.get("encoder", "")).lower()
        if codec_enum == AudioEncodeCodec.OPUS:
            target_profile["encoder"] = (
                AudioEncoder.XIPH_OPUSENC if enc_name == "opusenc" else AudioEncoder.LIBOPUS_FFMPEG
            )
        elif codec_enum == AudioEncodeCodec.AAC:
            target_profile["encoder"] = AudioEncoder.AAC_FFMPEG
        elif codec_enum == AudioEncodeCodec.EAC3:
            target_profile["encoder"] = AudioEncoder.EAC3_FFMPEG

        bitrates = profile.get("bitrates", {})
        layout_map = {
            "mono": AudioChannelLayout.MONO.name,
            "stereo": AudioChannelLayout.STEREO.name,
            "surround51": AudioChannelLayout.SURROUND_5_1.name,
            "surround71": AudioChannelLayout.SURROUND_7_1.name,
        }
        for ui_key, sb_key in layout_map.items():
            val = bitrates.get(ui_key)
            if val:
                target_profile["bitrates"][sb_key] = str(val)

    s.merge_workflow["resample_subs_on_merge"] = bool(merge_cfg.get("resampleSubsBeforeMerge", False))
    s.merge_workflow["delete_generated_files_after_merge"] = bool(
        merge_cfg.get("deleteGeneratedFilesAfterMerge", False)
    )

    src_merge = merge_cfg.get("source", {})
    s.merge_src_file["copy_attachments"] = bool(src_merge.get("copyAttachments", True))
    s.merge_src_file["copy_chapters"] = bool(src_merge.get("copyChapters", False))
    s.merge_src_file["copy_global_tags"] = bool(src_merge.get("copyGlobalTags", False))
    s.merge_src_file["copy_track_tags"] = bool(src_merge.get("copyTrackTags", False))

    dst_merge = merge_cfg.get("target", {})
    s.merge_dst_file["copy_only_selected_sync_audio_track"] = bool(
        dst_merge.get("onlyIncludeSyncAudioTrack", False)
    )
    s.merge_dst_file["copy_attachments"] = bool(dst_merge.get("copyAttachments", True))
    s.merge_dst_file["copy_chapters"] = bool(dst_merge.get("copyChapters", True))
    s.merge_dst_file["copy_subtitle_tracks"] = bool(dst_merge.get("copySubtitles", True))
    s.merge_dst_file["copy_global_tags"] = bool(dst_merge.get("copyGlobalTags", True))
    s.merge_dst_file["copy_track_tags"] = bool(dst_merge.get("copyTrackTags", True))

    sub_merge = merge_cfg.get("syncedSubtitle", {})
    s.merge_synced_sub_file["default_flag"] = bool(sub_merge.get("setDefaultFlag", True))
    s.merge_synced_sub_file["forced_flag"] = bool(sub_merge.get("setForcedFlag", False))
    s.merge_synced_sub_file["custom_trackname"] = bool(sub_merge.get("overrideTrackTitle", False))
    s.merge_synced_sub_file["trackname"] = str(sub_merge.get("customTrackTitle", "Synced Sub"))


# Regex patterns derived directly from C1fer/sushi-next (`sushi/__init__.py` & `sushi/demux.py`).
_RE_SHIFT_LINE = re.compile(
    r"^(\d+:\d{2}:\d{2}\.\d+)-(\d+:\d{2}:\d{2}\.\d+):\s*shift:\s*([+-]?\d+(?:\.\d+)?),\s*diff:\s*([+-]?\d+(?:\.\d+)?)"
)
_RE_AVG_SHIFT = re.compile(r"^Total average shift:\s*([+-]?\d+(?:\.\d+)?)s?")
_RE_GROUP_LINE = re.compile(
    r"^Group \(start:\s*[^,]+,\s*end:\s*[^,]+,\s*lines:\s*(\d+)\),\s*shifts \(start:\s*([+-]?\d+(?:\.\d+)?),\s*end:\s*([+-]?\d+(?:\.\d+)?),\s*average:\s*([+-]?\d+(?:\.\d+)?)\)"
)
_RE_WAV_PROGRESS = re.compile(r"WAV loading:.*?\((\d+)%\)")
_RE_MKV_PROGRESS = re.compile(r"Progress:\s*(\d+)%")


class ShiftTelemetryTracker:
    """Tracks real-time Sushi audio-matching telemetry and warning diagnostics."""

    def __init__(self, max_safe_avg_shift: float = 5.0) -> None:
        self.max_safe_avg_shift = max_safe_avg_shift
        self.shifts: list[tuple[int, str, float, float]] = []  # (line_idx, timestamp, shift, diff)
        self.group_avgs: list[tuple[int, float]] = []
        self.avg_shift: float | None = None
        self.broken_segments = 0
        self.max_window_hits = 0
        self.out_of_range_count = 0
        self.border_fixes = 0
        self.keyframe_warnings = 0
        self.warnings: list[dict[str, Any]] = []

    def add_warning(self, code: str, summary: str, line_index: int) -> None:
        item = {"code": code, "summary": summary, "lineIndex": line_index}
        self.warnings.append(item)
        emit("warning", **item)

    def feed_line(self, line: str, line_idx: int) -> None:
        stripped = line.strip()
        if not stripped:
            return

        m_shift = _RE_SHIFT_LINE.match(stripped)
        if m_shift:
            ts = m_shift.group(1)
            shift_val = float(m_shift.group(3))
            diff_val = float(m_shift.group(4))
            if self.shifts:
                prev_shift = self.shifts[-1][2]
                jump = abs(shift_val - prev_shift)
                if jump > 0.75:
                    self.add_warning(
                        "shift_jump",
                        f"Large shift jump ({jump:.2f}s) detected at {ts}.",
                        line_idx,
                    )
            self.shifts.append((line_idx, ts, shift_val, diff_val))
            return

        m_avg = _RE_AVG_SHIFT.match(stripped)
        if m_avg:
            self.avg_shift = float(m_avg.group(1))
            if abs(self.avg_shift) > self.max_safe_avg_shift:
                self.add_warning(
                    "large_avg_shift",
                    f"Average shift ({self.avg_shift:+.3f}s) exceeds ±{self.max_safe_avg_shift:.1f}s threshold.",
                    line_idx,
                )
            return

        m_grp = _RE_GROUP_LINE.match(stripped)
        if m_grp:
            self.group_avgs.append((line_idx, float(m_grp.group(4))))
            return

        lower = stripped.lower()
        if "increasing the window from" in lower:
            self.max_window_hits += 1
            self.add_warning("max_window_fallback", stripped.replace("Warning: ", ""), line_idx)
        elif "will most likely be broken" in lower:
            self.broken_segments += 1
            self.add_warning("broken_segment", stripped.replace("Warning: ", ""), line_idx)
        elif "shift is not consistent between" in lower:
            self.broken_segments += 1
            self.add_warning("inconsistent_group", stripped.replace("Warning: ", ""), line_idx)
        elif "typesetting group at" in lower and "different shift" in lower:
            self.keyframe_warnings += 1
            self.add_warning("keyframe_mismatch", stripped.replace("Warning: ", ""), line_idx)
        elif "outside of audio range" in lower:
            self.out_of_range_count += 1
            if self.out_of_range_count == 1:
                self.add_warning(
                    "outside_audio_range",
                    "One or more subtitle events fell outside the audio duration.",
                    line_idx,
                )
        elif "fixing" in lower and "border events" in lower:
            self.border_fixes += 1
        elif stripped.startswith("Warning:") or stripped.startswith("WARNING:"):
            self.add_warning("sushi_warning", stripped.split(":", 1)[1].strip(), line_idx)

    def finalize_metrics(self) -> dict[str, Any]:
        diffs = [d for _, _, _, d in self.shifts if math.isfinite(d)]
        median_diff = statistics.median(diffs) if diffs else None
        max_diff = max(diffs) if diffs else None
        max_jump = 0.0
        for i in range(1, len(self.shifts)):
            jump = abs(self.shifts[i][2] - self.shifts[i - 1][2])
            if jump > max_jump:
                max_jump = jump

        # Flag statistical high-diff anomalies (poor audio correlation).
        if median_diff is not None and diffs:
            high_diff_events = [
                (idx, ts, d)
                for idx, ts, _, d in self.shifts
                if d > 0.30 or (median_diff > 0 and d > max(0.18, median_diff * 5.0))
            ]
            if high_diff_events:
                worst_idx, worst_ts, worst_d = max(high_diff_events, key=lambda x: x[2])
                self.add_warning(
                    "high_audio_diff",
                    f"{len(high_diff_events)} event(s) showed weak audio match (worst diff {worst_d:.3f} at {worst_ts}, median {median_diff:.3f}).",
                    worst_idx,
                )

        metrics = {
            "avgShiftSeconds": self.avg_shift,
            "medianDiff": median_diff,
            "maxDiff": max_diff,
            "maxShiftJumpSeconds": max_jump if self.shifts else None,
            "eventCount": len(self.shifts),
            "groupCount": len(self.group_avgs),
            "brokenSegments": self.broken_segments,
            "maxWindowHits": self.max_window_hits,
            "outOfRangeEvents": self.out_of_range_count,
            "borderFixes": self.border_fixes,
            "warningCount": len(self.warnings),
        }
        emit("metrics", metrics=metrics)
        return metrics


def _build_job_objects(payload: dict[str, Any], subtitle_target: dict[str, Any]):
    """Construct upstream VideoSyncJob or AudioSyncJob from payload + probe info."""
    from sushi_batch.external.ffprobe import FFprobe
    from sushi_batch.models.enums import Task
    from sushi_batch.models.job.audio_sync_job import AudioSyncJob
    from sushi_batch.models.job.base_job import JobSync
    from sushi_batch.models.job.video_sync_job import JobMediaStreams, JobMerge, VideoSyncJob
    from sushi_batch.services.stream_service import StreamService

    src_path = payload["srcFilepath"]
    dst_path = payload["dstFilepath"]
    src_audio_id = payload.get("srcAudioStreamId")
    dst_audio_id = payload.get("dstAudioStreamId")

    if subtitle_target["kind"] == "external" and src_audio_id is None and dst_audio_id is None:
        return AudioSyncJob(
            id=int(payload.get("jobIndex", 1)),
            sync=JobSync(task=Task.AUDIO_SYNC_FIL),
            src_filepath=src_path,
            dst_filepath=dst_path,
            sub_filepath=subtitle_target["filepath"],
        )

    src_probe = FFprobe.get_parsed_output(src_path)
    dst_probe = FFprobe.get_parsed_output(dst_path)

    src_audio = StreamService.get_audio_streams_from_probe(src_probe["audio"])
    src_subs = StreamService.get_sub_streams_from_probe(src_probe["subtitle"])
    dst_video = StreamService.get_video_streams_from_probe(dst_probe["video"])
    dst_audio = StreamService.get_audio_streams_from_probe(dst_probe["audio"])

    # Mark selected audio tracks.
    if src_audio:
        chosen = next((a for a in src_audio if a.id == src_audio_id), src_audio[0])
        chosen.selected = True
    if dst_audio:
        chosen = next((a for a in dst_audio if a.id == dst_audio_id), dst_audio[0])
        chosen.selected = True

    if subtitle_target["kind"] == "embedded" and src_subs:
        sub_id = subtitle_target.get("streamId")
        chosen_sub = next((st for st in src_subs if st.id == sub_id), src_subs[0])
        chosen_sub.selected = True

    return VideoSyncJob(
        id=int(payload.get("jobIndex", 1)),
        src_filepath=src_path,
        dst_filepath=dst_path,
        sync=JobSync(task=Task.VIDEO_SYNC_FIL),
        src_streams=JobMediaStreams(video=[], audio=src_audio, subtitle=src_subs),
        dst_streams=JobMediaStreams(video=dst_video, audio=dst_audio, subtitle=[]),
        merge=JobMerge(),
    )


def _compute_synced_sub_path(
    dst_filepath: str,
    subtitle_target: dict[str, Any],
    total_sub_targets: int,
    output_dir: str | None,
) -> str:
    ext = subtitle_target.get("extension") or ""
    if not ext and subtitle_target["kind"] == "external":
        ext = Path(subtitle_target["filepath"]).suffix.lower()
    if ext == ".ssa":
        ext = ".ass"
    if ext not in {".ass", ".srt"}:
        ext = ".ass"

    dst = Path(dst_filepath)
    base_dir = Path(output_dir) if output_dir else dst.parent
    base_dir.mkdir(parents=True, exist_ok=True)

    if total_sub_targets <= 1 and not output_dir:
        # Exact upstream sushi-batch default: `<dst_filepath>.sushi<ext>`
        return f"{dst_filepath}.sushi{ext}"

    if total_sub_targets <= 1:
        return str(base_dir / f"{dst.name}.sushi{ext}")

    # Distinct filenames when syncing multiple embedded subtitle tracks for one episode.
    if subtitle_target["kind"] == "embedded":
        tid = subtitle_target.get("streamId", 0)
        lang = subtitle_target.get("lang") or "und"
        return str(base_dir / f"{dst.name}.track{tid}.{lang}.sushi{ext}")
    stem = Path(subtitle_target["filepath"]).stem
    return str(base_dir / f"{dst.name}.{stem}.sushi{ext}")


def _build_sushi_command(
    payload: dict[str, Any],
    job: Any,
    subtitle_target: dict[str, Any],
    output_sub_path: str,
    use_explicit_output: bool,
) -> list[str]:
    from sushi_batch.external.sub_sync import Sushi
    from sushi_batch.models import settings as sb_settings

    sync_cfg = payload.get("settings", {}).get("sync", {})
    use_advanced = bool(sync_cfg.get("enableAdvancedArgs", False))

    if subtitle_target["kind"] == "external":
        # External subtitle (supports both video and audio containers!).
        args = [
            sys.executable,
            "-u",
            "-m",
            "sushi",
            "--src",
            payload["srcFilepath"],
            "--dst",
            payload["dstFilepath"],
            "--script",
            subtitle_target["filepath"],
        ]
        if payload.get("srcAudioStreamId") is not None:
            args.extend(["--src-audio", str(payload["srcAudioStreamId"])])
        if payload.get("dstAudioStreamId") is not None:
            args.extend(["--dst-audio", str(payload["dstAudioStreamId"])])
        if sb_settings.config.sync_workflow["use_high_quality_resample"]:
            args.extend(["--sample-rate", "24000"])
        if use_advanced:
            Sushi._add_advanced_args(args)
    else:
        upstream_args = Sushi._get_args(job, use_advanced_args=use_advanced)
        # Replace bare `sushi` script name with current venv python -m sushi for zero PATH ambiguity.
        args = [sys.executable, "-u", "-m", "sushi", *upstream_args[1:]]

    # Extended sushi-next options supported cleanly.
    custom_sr = sync_cfg.get("customSampleRate")
    if custom_sr and "--sample-rate" not in args:
        args.extend(["--sample-rate", str(custom_sr)])

    if sync_cfg.get("grouping", True) is False:
        args.append("--no-grouping")

    chapters_mode = sync_cfg.get("chaptersMode", "auto")
    if chapters_mode == "none":
        args.extend(["--chapters", "none"])
    elif chapters_mode == "file" and sync_cfg.get("chaptersFile"):
        args.extend(["--chapters", sync_cfg["chaptersFile"]])

    kf_mode_setting = sync_cfg.get("keyframesSource", "none")
    if kf_mode_setting in {"auto", "make"}:
        args.extend(["--src-keyframes", kf_mode_setting, "--dst-keyframes", kf_mode_setting])
    elif kf_mode_setting == "files":
        if sync_cfg.get("srcKeyframesFile") and sync_cfg.get("dstKeyframesFile"):
            args.extend(
                [
                    "--src-keyframes",
                    sync_cfg["srcKeyframesFile"],
                    "--dst-keyframes",
                    sync_cfg["dstKeyframesFile"],
                ]
            )

    if kf_mode_setting != "none":
        if sync_cfg.get("maxKfDistance") is not None:
            args.extend(["--max-kf-distance", str(sync_cfg["maxKfDistance"])])
        if sync_cfg.get("kfMode") in {"all", "shift", "snap"}:
            args.extend(["--kf-mode", str(sync_cfg["kfMode"])])
        if sync_cfg.get("srcFps"):
            args.extend(["--src-fps", str(sync_cfg["srcFps"])])
        if sync_cfg.get("dstFps"):
            args.extend(["--dst-fps", str(sync_cfg["dstFps"])])

    if use_explicit_output:
        args.extend(["-o", output_sub_path])

    if sync_cfg.get("verboseLogging", False):
        args.append("-v")

    return args


def _stream_subprocess(
    args: list[str],
    source: str,
    on_line: Any = None,
) -> tuple[int, list[str]]:
    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )
    _ACTIVE_PROCS.append(proc)
    lines: list[str] = []
    try:
        assert proc.stdout is not None
        for raw_line in proc.stdout:
            line = raw_line.rstrip("\r\n")
            lines.append(line)
            if on_line is not None:
                on_line(line)
        proc.wait()
        return proc.returncode, lines
    finally:
        if proc in _ACTIVE_PROCS:
            _ACTIVE_PROCS.remove(proc)


def _encode_audio_tracks(
    job: Any,
    tracker: ShiftTelemetryTracker,
    log_accumulator: list[str],
) -> list[str]:
    """Encode lossless destination audio tracks using upstream sushi_batch codec profiles."""
    from sushi_batch.external.ffmpeg import FFmpeg
    from sushi_batch.external.opusenc import XiphOpusEncoder
    from sushi_batch.models import settings as sb_settings
    from sushi_batch.models.enums import AudioChannelLayout, AudioEncodeCodec, AudioEncoder, TracksToEncode
    from sushi_batch.utils.constants import FFPROBE_CHANNEL_LAYOUT_MAP

    merge_wf = sb_settings.config.merge_workflow
    if not merge_wf["encode_lossless_audio_before_merging"]:
        return []

    selected_codec: AudioEncodeCodec = merge_wf["encode_codec"]
    selected_encoder: AudioEncoder = merge_wf["encode_codec_settings"][selected_codec.name]["encoder"]
    stream_list = (
        job.dst_streams.audio
        if merge_wf["tracks_to_encode_before_merging"] == TracksToEncode.ALL
        else [job.dst_streams.get_selected_audio_stream()]
    )

    encoded_files: list[str] = []
    for stream in stream_list:
        if not FFmpeg.is_audio_encode_needed(stream, spinner=None, log_path=None):
            continue

        emit("stage", stage="encoding_audio", detail=f"Encoding {stream.short_display_label} to {selected_codec.value}")
        use_opusenc = selected_encoder == AudioEncoder.XIPH_OPUSENC and shutil.which("opusenc") is not None

        if selected_encoder == AudioEncoder.XIPH_OPUSENC and not use_opusenc:
            idx = emit_log(
                "audio_encode",
                "opusenc not found; falling back to FFmpeg libopus.",
                level="warning",
            )
            tracker.add_warning("opusenc_fallback", "opusenc not installed; used FFmpeg libopus instead.", idx)

        if use_opusenc:
            layout_enum = next(
                (
                    layout
                    for layout, aliases in FFPROBE_CHANNEL_LAYOUT_MAP.items()
                    if stream.channel_layout in aliases
                ),
                AudioChannelLayout.STEREO,
            )
            bitrate = merge_wf["encode_codec_settings"][AudioEncodeCodec.OPUS.name]["bitrates"][layout_enum.name]
            out_path = f"{job.dst_filepath}_track{stream.id}_encode.opus"
            pipe_args = FFmpeg.get_pcm_pipe_args(job.dst_filepath, stream.id)
            enc_args = ["opusenc", "--bitrate", bitrate.replace("k", ""), "--vbr", "-", out_path]
            emit_log("opusenc", f"Running: {' '.join(pipe_args)} | {' '.join(enc_args)}", level="info")

            # Use binary pipes for raw WAV PCM streaming into opusenc.
            ff_proc = subprocess.Popen(pipe_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            op_proc = subprocess.Popen(
                enc_args,
                stdin=ff_proc.stdout,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            _ACTIVE_PROCS.extend([ff_proc, op_proc])
            try:
                assert ff_proc.stdout is not None
                ff_proc.stdout.close()
                out_bytes, _ = op_proc.communicate()
                ff_proc.wait()
                text_out = out_bytes.decode("utf-8", errors="replace") if out_bytes else ""
                for l in text_out.splitlines():
                    log_accumulator.append(l)
                    emit_log("opusenc", l, level="info")
                if op_proc.returncode == 0 and Path(out_path).is_file():
                    stream.encoded = True
                    stream.encode_path = out_path
                    stream.encode_bitrate = bitrate.replace("k", " kbps")
                    job.merge.audio_encode_done = True
                    job.merge.audio_encode_codec = AudioEncodeCodec.OPUS.name
                    job.merge.audio_encode_encoder = AudioEncoder.XIPH_OPUSENC.name
                    encoded_files.append(out_path)
                else:
                    idx = emit_log("opusenc", f"opusenc exited with code {op_proc.returncode}; keeping original audio.", level="warning")
                    tracker.add_warning("audio_encode_failed", f"Audio encode failed for track {stream.id}; kept original track.", idx)
            finally:
                for p in (ff_proc, op_proc):
                    if p in _ACTIVE_PROCS:
                        _ACTIVE_PROCS.remove(p)
        else:
            effective_encoder = (
                AudioEncoder.LIBOPUS_FFMPEG
                if selected_encoder == AudioEncoder.XIPH_OPUSENC
                else selected_encoder
            )
            args, out_path, selected_bitrate = FFmpeg._get_audio_encode_args(
                job.dst_filepath, stream, selected_codec, effective_encoder, "[FFmpeg]"
            )
            emit_log("ffmpeg", f"Running: {' '.join(args)}", level="info")
            rc, enc_lines = _stream_subprocess(
                args,
                "ffmpeg",
                on_line=lambda line: (log_accumulator.append(line), emit_log("ffmpeg", line, level="info")),
            )
            if rc == 0 and Path(out_path).is_file():
                stream.encoded = True
                stream.encode_path = out_path
                stream.encode_bitrate = selected_bitrate.replace("k", " kbps")
                job.merge.audio_encode_done = True
                job.merge.audio_encode_codec = selected_codec.name
                job.merge.audio_encode_encoder = effective_encoder.name
                encoded_files.append(out_path)
            else:
                idx = emit_log("ffmpeg", f"FFmpeg audio encode failed (exit {rc}); keeping original audio.", level="warning")
                tracker.add_warning("audio_encode_failed", f"Audio encode failed for track {stream.id}; kept original track.", idx)

    return encoded_files


def _resample_subtitles(
    job: Any,
    synced_outputs: list[dict[str, Any]],
    tracker: ShiftTelemetryTracker,
    log_accumulator: list[str],
) -> list[str]:
    """Resample synced ASS/SSA subtitles to match target video resolution when Aegisub-CLI is available."""
    from sushi_batch.external.sub_resample import SubResampler
    from sushi_batch.models import settings as sb_settings

    if not sb_settings.config.merge_workflow["resample_subs_on_merge"]:
        return []

    if not shutil.which("aegisub-cli"):
        idx = emit_log("aegisub", "aegisub-cli not installed; skipping subtitle resampling.", level="warning")
        tracker.add_warning("aegisub_missing", "Aegisub-CLI is not installed; skipped subtitle resampling.", idx)
        return []

    dst_video = next((v for v in job.dst_streams.video if v.default), None) or (
        job.dst_streams.video[0] if job.dst_streams.video else None
    )
    if not dst_video or dst_video.width <= 0 or dst_video.height <= 0:
        return []

    target_res = (dst_video.width, dst_video.height)
    generated_resampled: list[str] = []

    for item in synced_outputs:
        sub_path = item["syncedPath"]
        ext = Path(sub_path).suffix.lower()
        if ext not in {".ass", ".ssa"}:
            continue
        try:
            script_res = SubResampler._get_script_resolution(sub_path)
        except Exception as exc:
            idx = emit_log("aegisub", f"Could not inspect script resolution: {exc}", level="warning")
            tracker.add_warning("resample_probe_failed", str(exc), idx)
            continue

        if None in script_res or script_res == target_res:
            emit_log("aegisub", f"Resample not needed for {Path(sub_path).name} ({script_res} == {target_res}).", level="info")
            continue

        emit("stage", stage="resampling_subs", detail=f"Resampling {Path(sub_path).name} to {target_res[0]}x{target_res[1]}")
        resampled_path = str(Path(sub_path).with_suffix("")) + "_resampled" + ext
        args = [
            "aegisub-cli",
            sub_path,
            resampled_path,
            "tool/resampleres",
            "--video",
            job.dst_filepath,
        ]
        emit_log("aegisub", f"Running: {' '.join(args)}", level="info")
        rc, _ = _stream_subprocess(
            args,
            "aegisub",
            on_line=lambda line: (log_accumulator.append(line), emit_log("aegisub", line, level="info")),
        )
        if rc == 0 and Path(resampled_path).is_file():
            item["resampledPath"] = resampled_path
            generated_resampled.append(resampled_path)
        else:
            idx = emit_log("aegisub", f"aegisub-cli failed (exit {rc}); merging unresampled subtitle.", level="warning")
            tracker.add_warning("resample_failed", f"Subtitle resampling failed for {Path(sub_path).name}.", idx)

    return generated_resampled


def _run_mkvmerge(
    payload: dict[str, Any],
    job: Any,
    synced_outputs: list[dict[str, Any]],
    tracker: ShiftTelemetryTracker,
    log_accumulator: list[str],
) -> tuple[str | None, bool]:
    """Build MKVMerge arguments via upstream sushi_batch helpers and execute with live progress."""
    from sushi_batch.external.mkv_merge import MKVMerge
    from sushi_batch.models import settings as sb_settings

    if not shutil.which("mkvmerge"):
        idx = emit_log("mkvmerge", "mkvmerge is not installed; skipping merge.", level="warning")
        tracker.add_warning("mkvmerge_missing", "MKVMerge is not installed; synced subtitle saved without merging.", idx)
        return None, False

    output_dir_override = payload.get("outputDir")
    if output_dir_override:
        dst_path = Path(job.dst_filepath)
        out_dir = Path(output_dir_override) / "Merged Files"
        out_dir.mkdir(parents=True, exist_ok=True)
        candidate = out_dir / f"{dst_path.stem}.mkv"
        counter = 1
        while candidate.exists():
            candidate = out_dir / f"{dst_path.stem} ({counter}).mkv"
            counter += 1
        output_file = str(candidate)
    else:
        output_file = MKVMerge._get_out_filepath(job.dst_filepath)
        # Ensure .mkv output container if target was e.g. .mp4
        if Path(output_file).suffix.lower() != ".mkv":
            output_file = str(Path(output_file).with_suffix(".mkv"))

    args: list[str] = ["mkvmerge", "--output", output_file]
    MKVMerge._add_source_file_args(args, job.src_filepath)
    MKVMerge._add_dst_audio_tracks(args, job)
    MKVMerge._add_destination_file_args(args, job.dst_filepath)

    sub_cfg = sb_settings.config.merge_synced_sub_file
    for item in synced_outputs:
        sub_path = item.get("resampledPath") or item["syncedPath"]
        lang = item.get("lang") or "und"
        default_flag = True if sub_cfg["default_flag"] else bool(item.get("default", False))
        forced_flag = True if sub_cfg["forced_flag"] else bool(item.get("forced", False))
        if sub_cfg["custom_trackname"]:
            trackname = sub_cfg["trackname"]
        else:
            trackname = item.get("title") or "Synced Sub"
        args.extend(
            [
                "--language",
                f"0:{lang}",
                "--track-name",
                f"0:{trackname}",
                *(["--default-track-flag", "0:1"] if default_flag else ["--default-track-flag", "0:0"]),
                *(["--forced-display-flag", "0:1"] if forced_flag else []),
                sub_path,
            ]
        )

    emit("stage", stage="merging", detail=f"Merging into {Path(output_file).name}")
    emit("progress", fraction=0.80, stage="merging")
    emit_log("mkvmerge", f"Running: {' '.join(args)}", level="info")

    def _on_mkv_line(line: str) -> None:
        log_accumulator.append(line)
        m_prog = _RE_MKV_PROGRESS.search(line)
        if m_prog:
            pct = int(m_prog.group(1))
            emit("progress", fraction=0.80 + (pct / 100.0) * 0.18, stage="merging")
            return
        lvl = "info"
        if line.startswith("Warning:"):
            lvl = "warning"
        elif line.startswith("Error:"):
            lvl = "error"
        idx = emit_log("mkvmerge", line, level=lvl)
        if lvl == "warning":
            tracker.add_warning("mkvmerge_warning", line.replace("Warning:", "").strip(), idx)

    rc, mkv_lines = _stream_subprocess(args, "mkvmerge", on_line=_on_mkv_line)
    if rc == 0:
        return output_file, True
    if rc == 1:
        idx = emit_log("mkvmerge", "MKVMerge completed with warnings (exit code 1).", level="warning")
        if not any(w["code"] == "mkvmerge_warning" for w in tracker.warnings):
            tracker.add_warning("mkvmerge_warning", "MKVMerge completed with warnings.", idx)
        return output_file, True

    err_lines = [l for l in mkv_lines if l.startswith("Error:")]
    err_msg = err_lines[0] if err_lines else f"MKVMerge failed with exit code {rc}."
    emit_log("mkvmerge", err_msg, level="error")
    return None, False


def _save_text_log(logs_dir: str, category: str, src_or_dst: str, lines: list[str]) -> str | None:
    try:
        folder = Path(logs_dir) / category
        folder.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y-%m-%d %H-%M-%S")
        stem = Path(src_or_dst).stem
        out = folder / f"{stamp} - {stem}.log"
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return str(out)
    except OSError:
        return None


def cmd_run_job(payload: dict[str, Any]) -> int:
    bin_dirs = payload.get("binDirs", [])
    tool_overrides = payload.get("toolOverrides", {})
    runtime_data_dir = payload.get("runtimeDataDir") or str(
        Path.home() / "Library" / "Application Support" / "Sushi.GS" / "runtime-data"
    )
    logs_dir = payload.get("logsDir") or str(
        Path.home() / "Library" / "Application Support" / "Sushi.GS" / "logs"
    )

    configure_binary_path(bin_dirs, tool_overrides)
    try:
        _apply_upstream_settings(payload.get("settings", {}), runtime_data_dir)
        from sushi_batch.external.sub_sync import Sushi
        from sushi_batch.models import settings as sb_settings

        mode = payload.get("mode", "sync")  # "sync" or "merge"
        subtitle_targets: list[dict[str, Any]] = payload.get("subtitleTargets", [])
        if not subtitle_targets:
            emit("error", code="no_subtitles", message="No subtitle track or external subtitle file selected.")
            return 1

        output_dir = payload.get("outputDir") or None
        tracker = ShiftTelemetryTracker(max_safe_avg_shift=float(Sushi.max_safe_avg_shift))
        synced_outputs: list[dict[str, Any]] = []
        sushi_log_lines: list[str] = []
        merge_log_lines: list[str] = []

        # Build primary upstream job object (VideoSyncJob / AudioSyncJob).
        primary_job = _build_job_objects(payload, subtitle_targets[0])

        if mode == "sync":
            total = len(subtitle_targets)
            for idx_sub, sub_target in enumerate(subtitle_targets):
                job = primary_job if idx_sub == 0 else _build_job_objects(payload, sub_target)
                out_sub_path = _compute_synced_sub_path(
                    payload["dstFilepath"], sub_target, total, output_dir
                )
                use_explicit_output = (total > 1) or (output_dir is not None)
                args = _build_sushi_command(payload, job, sub_target, out_sub_path, use_explicit_output)

                label = sub_target.get("title") or sub_target.get("lang") or f"Track {idx_sub + 1}"
                emit("stage", stage="demuxing", detail=f"Syncing subtitle {idx_sub + 1}/{total}: {label}")
                base_frac = idx_sub / float(max(total, 1)) * 0.72
                span_frac = 0.72 / float(max(total, 1))
                emit("progress", fraction=base_frac + 0.03 * span_frac, stage="demuxing")
                emit_log("sushi", f"Running: {' '.join(args)}", level="info")

                state = {"stage": "demuxing"}

                def _on_sushi_line(line: str) -> None:
                    sushi_log_lines.append(line)
                    lower = line.lower()
                    level = "info"
                    if "critical error" in lower or line.startswith("ERROR:"):
                        level = "error"
                    elif "warning:" in lower or line.startswith("WARNING:"):
                        level = "warning"

                    l_idx = emit_log("sushi", line, level=level)
                    tracker.feed_line(line, l_idx)

                    if "---demuxing---" in lower:
                        state["stage"] = "demuxing"
                        emit("stage", stage="demuxing", detail="Extracting audio and subtitle streams")
                        emit("progress", fraction=base_frac + 0.10 * span_frac, stage="demuxing")
                    elif "loading wav:" in lower:
                        state["stage"] = "loading_audio"
                        emit("stage", stage="loading_audio", detail="Loading and resampling audio waveforms")
                        emit("progress", fraction=base_frac + 0.25 * span_frac, stage="loading_audio")
                    elif "---calculating shifts---" in lower:
                        state["stage"] = "calculating_shifts"
                        emit("stage", stage="calculating_shifts", detail="Matching audio patterns")
                        emit("progress", fraction=base_frac + 0.45 * span_frac, stage="calculating_shifts")
                    elif "---grouping and smoothing---" in lower:
                        state["stage"] = "grouping"
                        emit("stage", stage="grouping", detail="Grouping and smoothing subtitle shifts")
                        emit("progress", fraction=base_frac + 0.85 * span_frac, stage="grouping")
                    elif line.startswith("Done in "):
                        emit("progress", fraction=base_frac + 0.98 * span_frac, stage="saving")
                    else:
                        m_wav = _RE_WAV_PROGRESS.search(line)
                        if m_wav:
                            pct = int(m_wav.group(1))
                            emit(
                                "progress",
                                fraction=base_frac + (0.25 + (pct / 100.0) * 0.20) * span_frac,
                                stage="loading_audio",
                            )

                rc, out_lines = _stream_subprocess(args, "sushi", on_line=_on_sushi_line)
                if rc != 0:
                    err_msg = Sushi._get_error_message(out_lines)
                    if sb_settings.config.general["save_sushi_logs"]:
                        _save_text_log(logs_dir, "Sushi Logs", payload["srcFilepath"], sushi_log_lines)
                    emit("error", code="sushi_failed", message=err_msg)
                    return rc

                # Locate generated subtitle file (handle .ssa -> .ass fallback).
                actual_path = out_sub_path
                if not Path(actual_path).is_file():
                    alt_ass = str(Path(out_sub_path).with_suffix(".ass"))
                    if Path(alt_ass).is_file():
                        actual_path = alt_ass

                synced_outputs.append(
                    {
                        "syncedPath": actual_path,
                        "resampledPath": None,
                        "lang": sub_target.get("lang", "und"),
                        "title": sub_target.get("title", ""),
                        "default": sub_target.get("default", False),
                        "forced": sub_target.get("forced", False),
                    }
                )

            metrics = tracker.finalize_metrics()
            sushi_log_path = None
            if sb_settings.config.general["save_sushi_logs"]:
                sushi_log_path = _save_text_log(logs_dir, "Sushi Logs", payload["srcFilepath"], sushi_log_lines)
        else:
            # Manual merge mode: reuse already-synced output paths from payload.
            metrics = {}
            sushi_log_path = None
            for existing in payload.get("existingSyncedOutputs", []):
                synced_outputs.append(
                    {
                        "syncedPath": existing["syncedPath"],
                        "resampledPath": None,
                        "lang": existing.get("lang", "und"),
                        "title": existing.get("title", ""),
                        "default": existing.get("default", False),
                        "forced": existing.get("forced", False),
                    }
                )

        # Merge step if manual merge requested OR auto-merge enabled on video target.
        should_merge = (mode == "merge") or bool(
            sb_settings.config.merge_workflow["merge_files_after_execution"]
        )
        merged_filepath: str | None = None
        merge_succeeded = False
        merge_log_path: str | None = None
        temp_generated_files: list[str] = []

        if should_merge and hasattr(primary_job, "dst_streams") and primary_job.dst_streams.video:
            emit("progress", fraction=0.74, stage="encoding_audio")
            encoded_audio = _encode_audio_tracks(primary_job, tracker, merge_log_lines)
            temp_generated_files.extend(encoded_audio)

            resampled_subs = _resample_subtitles(primary_job, synced_outputs, tracker, merge_log_lines)
            temp_generated_files.extend(resampled_subs)

            merged_filepath, merge_succeeded = _run_mkvmerge(
                payload, primary_job, synced_outputs, tracker, merge_log_lines
            )

            if sb_settings.config.general["save_merge_logs"] and merge_log_lines:
                merge_log_path = _save_text_log(logs_dir, "Merge Logs", payload["dstFilepath"], merge_log_lines)

            if merge_succeeded and sb_settings.config.merge_workflow["delete_generated_files_after_merge"]:
                emit("stage", stage="cleaning_up", detail="Removing temporary generated subtitle/audio files")
                for item in synced_outputs:
                    Path(item["syncedPath"]).unlink(missing_ok=True)
                for p in temp_generated_files:
                    Path(p).unlink(missing_ok=True)
        elif should_merge:
            emit_log("mkvmerge", "Target file has no video track; skipped MKV merge.", level="info")

        emit("progress", fraction=1.0, stage="completed")
        emit("stage", stage="completed", detail="Finished")
        emit(
            "result",
            ok=True,
            syncedFiles=[item["syncedPath"] for item in synced_outputs],
            mergedFilepath=merged_filepath,
            mergeSucceeded=merge_succeeded,
            hasWarnings=len(tracker.warnings) > 0,
            warnings=tracker.warnings,
            metrics=metrics,
            sushiLogPath=sushi_log_path,
            mergeLogPath=merge_log_path,
        )
        return 0
    except Exception as exc:
        emit("error", code="worker_exception", message=f"{type(exc).__name__}: {exc}")
        return 1
    finally:
        _cleanup_shims()


def main() -> int:
    parser = argparse.ArgumentParser(description="Sushi.GS Python Worker Bridge")
    sub = parser.add_subparsers(dest="command", required=True)

    p_check = sub.add_parser("self-check")
    p_check.add_argument("--bin-dir", action="append", default=[])
    p_check.add_argument("--tool", action="append", default=[])

    p_probe = sub.add_parser("probe")
    p_probe.add_argument("--file", required=True)
    p_probe.add_argument("--bin-dir", action="append", default=[])
    p_probe.add_argument("--tool", action="append", default=[])

    sub.add_parser("run-job")

    args = parser.parse_args()

    def _parse_tool_overrides(pairs: list[str]) -> dict[str, str]:
        out: dict[str, str] = {}
        for item in pairs:
            if "=" in item:
                k, v = item.split("=", 1)
                if k and v:
                    out[k] = v
        return out

    if args.command == "self-check":
        return cmd_self_check(args.bin_dir, _parse_tool_overrides(args.tool))
    if args.command == "probe":
        return cmd_probe(args.file, args.bin_dir, _parse_tool_overrides(args.tool))
    if args.command == "run-job":
        raw = sys.stdin.read()
        if not raw.strip():
            emit("error", code="empty_stdin", message="Expected JSON job payload on stdin.")
            return 1
        payload = json.loads(raw)
        return cmd_run_job(payload)
    return 1


if __name__ == "__main__":
    sys.exit(main())
