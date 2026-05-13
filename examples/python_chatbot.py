#!/usr/bin/env python3
"""Small dependency-free chat client for LLMRunner."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request


def post_json(url: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer local",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Could not reach LLMRunner: {error.reason}") from error


def chat(base_url: str, model: str, system_prompt: str) -> None:
    messages = [{"role": "system", "content": system_prompt}]
    endpoint = f"{base_url.rstrip('/')}/chat/completions"

    print(f"LLMRunner chat using model '{model}'. Type /quit to exit.")

    while True:
        try:
            user_input = input("\nYou: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return

        if not user_input:
            continue

        if user_input in {"/quit", "/exit"}:
            return

        messages.append({"role": "user", "content": user_input})
        payload = {
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "max_tokens": 256,
        }

        try:
            response = post_json(endpoint, payload)
            assistant_message = response["choices"][0]["message"]["content"].strip()
        except Exception as error:  # Keep this a friendly test client.
            print(f"\nError: {error}", file=sys.stderr)
            messages.pop()
            continue

        messages.append({"role": "assistant", "content": assistant_message})
        print(f"\nBot: {assistant_message}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Chat with a local LLMRunner model.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8080/v1")
    parser.add_argument("--model", default="smollm2-135m")
    parser.add_argument(
        "--system",
        default="You are a concise, helpful local assistant.",
        help="System prompt to start the conversation.",
    )
    args = parser.parse_args()

    chat(args.base_url, args.model, args.system)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
