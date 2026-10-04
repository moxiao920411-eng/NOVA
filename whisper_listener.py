"""Local microphone listener for NOVA.

The worker deliberately does not execute commands. It captures short speech
segments, transcribes them with Whisper small, and emits JSON lines to the
PowerShell backend. NOVA remains responsible for wake-word checks, security,
memory, and all computer operations.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import time
import urllib.request
import unicodedata
from collections import deque
from typing import Any


def emit(kind: str, **data: Any) -> None:
    payload = {"type": kind, "timestamp": time.time(), **data}
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    endpoint = os.environ.get("NOVA_VOICE_ENDPOINT", "").strip()
    if endpoint:
        try:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            request = urllib.request.Request(
                endpoint,
                data=body,
                headers={"Content-Type": "application/json; charset=utf-8"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=1.5):
                pass
        except Exception:
            # The microphone worker must remain alive if the UI/backend is
            # briefly restarting or the local endpoint is unavailable.
            pass


def get_cache_dir() -> str:
    local_app_data = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
    path = os.environ.get(
        "NOVA_WHISPER_CACHE",
        os.path.join(local_app_data, "NOVA", "whisper"),
    )
    os.makedirs(path, exist_ok=True)
    return path


def transcribe(model: Any, audio: Any, language: str) -> str:
    segments, _info = model.transcribe(
        audio,
        language=language,
        task="transcribe",
        beam_size=3,
        best_of=3,
        temperature=0.0,
        condition_on_previous_text=False,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 450, "speech_pad_ms": 180},
        without_timestamps=True,
        no_speech_threshold=0.6,
        log_prob_threshold=-1.0,
        compression_ratio_threshold=2.4,
        initial_prompt="嘿 NOVA。嘿諾瓦。開啟。關閉。播放。搜尋。",
    )
    return " ".join(segment.text.strip() for segment in segments).strip()


def has_meaningful_text(text: str) -> bool:
    """Return False for Whisper's silence artefacts such as `。` or `...`."""
    normalized = "".join(
        char for char in text.strip()
        if not char.isspace()
        and unicodedata.category(char)[0] not in {"P", "S"}
    )
    return bool(normalized)


def compact_text(text: str) -> str:
    return "".join(
        char.casefold() for char in text.strip()
        if not char.isspace()
        and unicodedata.category(char)[0] not in {"P", "S"}
    )


def run() -> int:
    # The regular Hugging Face HTTP transfer is more reliable on this Windows
    # setup than the optional Xet helper, especially when a large model is
    # resumed after a connection reset.
    os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
    try:
        import numpy as np
        import sounddevice as sd
        from faster_whisper import WhisperModel
    except Exception as exc:
        emit("error", message=f"Whisper 套件載入失敗：{exc}")
        return 2

    model_name = os.environ.get("NOVA_WHISPER_MODEL", "small")
    language = os.environ.get("NOVA_WHISPER_LANGUAGE", "zh")
    device = os.environ.get("NOVA_WHISPER_DEVICE", "cpu")
    compute_type = os.environ.get(
        "NOVA_WHISPER_COMPUTE_TYPE",
        "int8" if device == "cpu" else "float16",
    )
    emit("status", message=f"正在載入 Whisper {model_name}…")
    try:
        model = WhisperModel(
            model_name,
            device=device,
            compute_type=compute_type,
            download_root=get_cache_dir(),
            cpu_threads=max(1, int(os.environ.get("NOVA_WHISPER_CPU_THREADS", "4"))),
        )
    except Exception as exc:
        emit("error", message=f"Whisper {model_name} 載入失敗：{exc}")
        return 3

    sample_rate = 16000
    block_seconds = 0.5
    block_size = int(sample_rate * block_seconds)
    audio_queue: queue.Queue[Any] = queue.Queue(maxsize=32)
    last_audio_status_time = 0.0

    def callback(indata: Any, frames: int, stream_time: Any, status: Any) -> None:
        nonlocal last_audio_status_time
        if status:
            now = time.monotonic()
            if now - last_audio_status_time >= 5.0:
                emit("audio_status", message=str(status))
                last_audio_status_time = now
        try:
            audio_queue.put_nowait(indata.copy())
        except queue.Full:
            # Dropping the oldest audio is preferable to growing latency.
            try:
                audio_queue.get_nowait()
                audio_queue.put_nowait(indata.copy())
            except queue.Empty:
                pass

    try:
        stream = sd.InputStream(
            samplerate=sample_rate,
            blocksize=block_size,
            channels=1,
            dtype="float32",
            callback=callback,
        )
        stream.start()
    except Exception as exc:
        emit("error", message=f"麥克風啟動失敗：{exc}")
        return 4

    emit(
        "ready",
        message=f"Whisper {model_name} 已就緒，等待「嘿 NOVA」。",
        model=model_name,
        sampleRate=sample_rate,
    )
    pre_roll: deque[Any] = deque(maxlen=2)
    buffer: list[Any] = []
    speech_started = False
    speech_activity_seconds = 0.0
    silence_seconds = 0.0
    last_text_key = ""
    last_text_time = 0.0
    noise_floor = 0.003
    threshold = 0.008

    try:
        while True:
            block = audio_queue.get()
            mono = np.asarray(block, dtype=np.float32).reshape(-1)
            if mono.size == 0:
                continue
            rms = float(np.sqrt(np.mean(np.square(mono))) + 1e-9)
            if not speech_started:
                noise_floor = min(noise_floor * 0.98 + rms * 0.02, 0.05)
                threshold = max(0.006, noise_floor * 2.8)
            is_speech = rms >= threshold

            if not speech_started:
                pre_roll.append(mono)
                if not is_speech:
                    continue
                speech_started = True
                buffer = list(pre_roll)
                speech_activity_seconds = block_seconds
                silence_seconds = 0.0
                emit("speech_start", message="正在收音…")
            else:
                buffer.append(mono)
                if is_speech:
                    speech_activity_seconds += block_seconds
                if is_speech or rms >= threshold * 0.75:
                    silence_seconds = 0.0
                else:
                    silence_seconds += block_seconds

            duration = sum(part.size for part in buffer) / sample_rate
            if silence_seconds < 0.9 and duration < 6.0:
                continue
            if duration < 0.25 or speech_activity_seconds < 0.30:
                speech_started = False
                buffer = []
                pre_roll.clear()
                speech_activity_seconds = 0.0
                continue

            audio = np.concatenate(buffer)
            emit("transcribing", message="正在辨識語音…")
            try:
                text = transcribe(model, audio, language)
                # Whisper can emit punctuation for silence/noise. Never send
                # those artefacts to NOVA, otherwise they may be mistaken for
                # a browser-search command.
                if text and has_meaningful_text(text):
                    text_key = compact_text(text)
                    now = time.monotonic()
                    # Avoid sending the same recognition repeatedly while the
                    # microphone is settling; NOVA may otherwise repeat a
                    # browser/app action.
                    if text_key and not (
                        text_key == last_text_key and now - last_text_time < 4.0
                    ):
                        emit("text", text=text)
                        last_text_key = text_key
                        last_text_time = now
            except Exception as exc:
                emit("error", message=f"Whisper 辨識失敗：{exc}")
            speech_started = False
            buffer = []
            pre_roll.clear()
            speech_activity_seconds = 0.0
            silence_seconds = 0.0
    except KeyboardInterrupt:
        return 0
    finally:
        stream.stop()
        stream.close()


if __name__ == "__main__":
    raise SystemExit(run())
