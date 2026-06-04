#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request


def load_env_file(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def load_env() -> None:
    here = Path(__file__).resolve().parent
    load_env_file(here / ".env")
    load_env_file(Path.cwd() / ".env")


def folder_id_from_env() -> str:
    folder_id = os.getenv("YANDEX_FOLDER_ID", "").strip()
    if folder_id:
        return folder_id

    model_uri = os.getenv("YANDEX_MODEL_URI", "").strip()
    if model_uri.startswith("gpt://"):
        parts = model_uri.split("/")
        if len(parts) >= 3:
            return parts[2]
    return ""


def find_binary(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found

    for candidate in (
        Path("/opt/homebrew/bin") / name,
        Path("/usr/local/bin") / name,
        Path("/usr/bin") / name,
    ):
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)

    raise FileNotFoundError(
        f"{name} не найден. Установи ffmpeg или добавь путь к нему в PATH."
    )


def record_audio(path: Path, duration: float, device: str) -> None:
    command = [
        find_binary("ffmpeg"),
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "avfoundation",
        "-i",
        device,
        "-t",
        str(duration),
        "-ac",
        "1",
        "-ar",
        "48000",
        "-c:a",
        "libopus",
        str(path),
    ]
    subprocess.run(command, check=True)


def audio_duration(path: Path) -> float:
    command = [
        find_binary("ffprobe"),
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return float(result.stdout.strip() or "0")


def extract_chunk(source: Path, target: Path, start: float, duration: float) -> None:
    command = [
        find_binary("ffmpeg"),
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        str(start),
        "-t",
        str(duration),
        "-i",
        str(source),
        "-ac",
        "1",
        "-ar",
        "48000",
        "-c:a",
        "libopus",
        str(target),
    ]
    subprocess.run(command, check=True)


def recognize(path: Path) -> str:
    api_key = os.getenv("YANDEX_API_KEY", "").strip()
    iam_token = os.getenv("YANDEX_IAM_TOKEN", "").strip()
    folder_id = folder_id_from_env()
    if not api_key and not iam_token:
        raise RuntimeError("YANDEX_API_KEY or YANDEX_IAM_TOKEN is not set")
    if not folder_id:
        raise RuntimeError("YANDEX_FOLDER_ID is not set and cannot be inferred")

    params = urllib.parse.urlencode(
        {
            "lang": os.getenv("YANDEX_STT_LANG", "ru-RU"),
            "topic": os.getenv("YANDEX_STT_TOPIC", "general"),
            "format": "oggopus",
            "folderId": folder_id,
        }
    )
    url = f"https://stt.api.cloud.yandex.net/speech/v1/stt:recognize?{params}"

    headers = {"Content-Type": "audio/ogg"}
    if api_key:
        headers["Authorization"] = f"Api-Key {api_key}"
    else:
        headers["Authorization"] = f"Bearer {iam_token}"

    request = urllib.request.Request(
        url,
        data=path.read_bytes(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))

    return (data.get("result") or "").strip()


def recognize_long(path: Path, chunk_seconds=25.0) -> str:
    duration = audio_duration(path)
    if duration <= 30:
        return recognize(path)

    parts = []
    chunk_paths = []
    start = 0.0
    try:
        while start < duration:
            with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as tmp:
                chunk_path = Path(tmp.name)
            chunk_paths.append(chunk_path)
            extract_chunk(path, chunk_path, start, min(chunk_seconds, duration - start))
            text = recognize(chunk_path)
            if text:
                parts.append(text)
            start += chunk_seconds
    finally:
        for chunk_path in chunk_paths:
            try:
                chunk_path.unlink()
            except FileNotFoundError:
                pass

    return " ".join(parts).strip()


def main() -> int:
    load_env()
    parser = argparse.ArgumentParser(description="Record voice and recognize it with Yandex SpeechKit")
    parser.add_argument("--duration", type=float, default=float(os.getenv("REAPER_AGENT_VOICE_SECONDS", "60")))
    parser.add_argument("--device", default=os.getenv("REAPER_AGENT_AUDIO_DEVICE", ":1"))
    args = parser.parse_args()

    with tempfile.NamedTemporaryFile(suffix=".ogg", delete=False) as tmp:
        audio_path = Path(tmp.name)

    try:
        record_audio(audio_path, args.duration, args.device)
        text = recognize_long(audio_path)
        sys.stdout.write("@@VOICE_TEXT_START@@\n")
        sys.stdout.write(text)
        sys.stdout.write("\n@@VOICE_TEXT_END@@\n")
        return 0
    except Exception as exc:  # noqa: BLE001
        sys.stdout.write("@@VOICE_ERROR_START@@\n")
        sys.stdout.write(str(exc))
        sys.stdout.write("\n@@VOICE_ERROR_END@@\n")
        return 1
    finally:
        try:
            audio_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
