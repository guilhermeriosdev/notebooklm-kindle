"""Instala o plugin Gemini no Kindle já configurado.

Com o Kindle conectado por USB:

    python install_plugin.py

Copia notebooklm.koplugin para koreader/plugins/ e grava
notebooklm_config.lua com o endereço e o token desta ponte e o gesto padrão.
Na próxima vez que o KOReader abrir um livro, o plugin aplica tudo sozinho.
Sem Kindle conectado, gera a pasta pronta em dist/ para copiar à mão.
"""

import argparse
import datetime as dt
import os
import shutil
import string
import sys
from pathlib import Path

from common import bridge_url, load_token

PLUGIN_SRC = Path(__file__).resolve().parent.parent / "notebooklm.koplugin"
PLUGIN_NAME = PLUGIN_SRC.name
CONFIG_NAME = "notebooklm_config.lua"

GESTURES = {
    "canto": "hold_bottom_right_corner",
    "dois-dedos": "two_finger_tap_bottom_right_corner",
    "toque-duplo": "double_tap_bottom_right_corner",
    "nenhum": None,
}


def safe_iterdir(path: Path) -> list[Path]:
    try:
        return [p for p in path.iterdir() if p.is_dir()]
    except OSError:
        return []


def find_kindle() -> Path | None:
    """Procura um volume montado que tenha a pasta koreader/ na raiz."""
    if os.name == "nt":
        candidates = [Path(f"{letter}:\\") for letter in string.ascii_uppercase]
    else:
        # macOS: /Volumes/Kindle; Linux: /media/<usuário>/Kindle
        candidates = []
        for base in (Path("/Volumes"), Path("/media"), Path("/run/media")):
            for level1 in safe_iterdir(base):
                candidates.append(level1)
                candidates += safe_iterdir(level1)
    for root in candidates:
        try:
            if (root / "koreader" / "plugins").is_dir():
                return root
        except OSError:  # unidade de CD vazia, sem permissão etc.
            continue
    return None


def lua_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def render_config(url: str, token: str, gesture: str | None, panel_ratio: float) -> str:
    gesture_value = lua_string(gesture) if gesture else "false"
    return (
        "-- Gerado por bridge/install_plugin.py. Aplicado automaticamente pelo plugin\n"
        "-- na próxima vez que o KOReader abrir um livro.\n"
        "return {\n"
        f"    generated_at = {lua_string(dt.datetime.now().isoformat(timespec='seconds'))},\n"
        f"    server_url = {lua_string(url)},\n"
        f"    token = {lua_string(token)},\n"
        "    -- gesto que abre/fecha o painel; false = não criar gesto\n"
        f"    gesture = {gesture_value},\n"
        f"    panel_ratio = {panel_ratio},\n"
        "}\n"
    )


def install(dest_plugins: Path, config: str) -> Path:
    target = dest_plugins / PLUGIN_NAME
    target.mkdir(parents=True, exist_ok=True)
    for file in PLUGIN_SRC.glob("*.lua"):
        if file.name != CONFIG_NAME:
            shutil.copy2(file, target / file.name)
    (target / CONFIG_NAME).write_text(config, encoding="utf-8")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--kindle", type=Path, help="raiz do Kindle montado (padrão: detectar)")
    parser.add_argument("--url", help=f"endereço da ponte visto pelo Kindle (padrão: {bridge_url()})")
    parser.add_argument("--gesto", choices=GESTURES, default="canto",
                        help="gesto para abrir o painel (padrão: segurar o canto inferior direito)")
    parser.add_argument("--painel", type=float, default=0.5, help="altura do painel, de 0.3 a 0.8 (padrão: 0.5)")
    args = parser.parse_args()

    if not 0.3 <= args.painel <= 0.8:
        parser.error("--painel deve ficar entre 0.3 e 0.8")
    url = args.url or bridge_url()
    if "SEU-IP" in url:
        parser.error("não consegui descobrir o IP deste computador; informe --url http://IP:PORTA")
    config = render_config(url, load_token(), GESTURES[args.gesto], args.painel)

    kindle = args.kindle or find_kindle()
    if kindle:
        plugins = kindle / "koreader" / "plugins"
        if not plugins.is_dir():
            print(f"Não encontrei {plugins}. O KOReader está instalado nesse Kindle?")
            return 1
        target = install(plugins, config)
        print(f"Plugin instalado em {target}")
        print("Ejete o Kindle com segurança e abra um livro no KOReader.")
    else:
        target = install(Path(__file__).resolve().parent.parent / "dist", config)
        print("Nenhum Kindle com KOReader encontrado no USB.")
        print(f"Plugin configurado gerado em {target}")
        print("Copie essa pasta para koreader/plugins/ no Kindle.")
    print(f"  ponte: {url}")
    print(f"  gesto: {args.gesto}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
