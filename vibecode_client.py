import json
import os
import urllib.request


def _load_env_file(path=".env"):
    if not os.path.exists(path):
        return

    with open(path, "r", encoding="utf-8") as env_file:
        for raw_line in env_file:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue

            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


_load_env_file()

VIBECODE_BASE_URL = os.getenv("VIBECODE_BASE_URL", "https://vibecode.bitrix24.tech/v1")
VIBECODE_MODEL = os.getenv("VIBECODE_MODEL", "bitrix/bitrixgpt-5.5")


def chat_completion(messages, temperature=None, response_format=None):
    api_key = os.getenv("VIBECODE_API_KEY")
    if not api_key:
        raise RuntimeError("VIBECODE_API_KEY is not set")

    payload = {
        "model": VIBECODE_MODEL,
        "messages": messages,
    }

    if temperature is not None:
        payload["temperature"] = temperature
    if response_format is not None:
        payload["response_format"] = response_format

    request = urllib.request.Request(
        f"{VIBECODE_BASE_URL}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def ask(prompt, system=None, temperature=None):
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    result = chat_completion(messages, temperature=temperature)
    return result["choices"][0]["message"]["content"]


if __name__ == "__main__":
    print(ask("Ответь одним коротким предложением: VibeCode AI Router подключен?"))
