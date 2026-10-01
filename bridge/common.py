"""Configuração compartilhada entre a ponte (server.py) e o instalador do plugin."""

import os
import secrets
import socket
from pathlib import Path

DATA_DIR = Path(os.environ.get("BRIDGE_DATA_DIR", Path(__file__).parent / "data"))
TOKEN_FILE = DATA_DIR / "token.txt"
GEMINI_KEY_FILE = DATA_DIR / "gemini_key.txt"
PORT = int(os.environ.get("BRIDGE_PORT", "8765"))

DATA_DIR.mkdir(parents=True, exist_ok=True)


def load_gemini_key() -> str | None:
    """Chave da API do Gemini. Fica só na ponte; o Kindle nunca a vê.

    Vem de GEMINI_API_KEY ou de bridge/data/gemini_key.txt.
    """
    key = os.environ.get("GEMINI_API_KEY")
    if key:
        return key.strip()
    if GEMINI_KEY_FILE.exists():
        key = GEMINI_KEY_FILE.read_text(encoding="utf-8").strip()
        return key or None
    return None


def load_token() -> str:
    token = os.environ.get("BRIDGE_TOKEN")
    if token:
        return token
    if TOKEN_FILE.exists():
        return TOKEN_FILE.read_text(encoding="utf-8").strip()
    token = secrets.token_urlsafe(16)
    TOKEN_FILE.write_text(token, encoding="utf-8")
    return token


def local_ip() -> str | None:
    """IP deste computador na rede local (o que o Kindle deve usar)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))  # não envia nada; só escolhe a interface de saída
            return s.getsockname()[0]
    except OSError:
        return None


def bridge_url() -> str:
    return f"http://{local_ip() or 'SEU-IP'}:{PORT}"
