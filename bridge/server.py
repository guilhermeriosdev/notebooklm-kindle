"""Ponte HTTP entre o KOReader (Kindle) e o Google Gemini.

Diferente do NotebookLM, o Gemini tem API oficial: basta uma **chave de API**
(colada uma vez só na ponte, nunca no Kindle). Não há login de navegador nem
sessão que expira. A ponte guarda localmente os "cadernos" e suas fontes (o
texto extraído dos livros e dos destaques) e, a cada pergunta, manda a pergunta
junto das fontes para o Gemini. O Kindle conversa só com esta ponte, na rede
local, autenticando com um token compartilhado.
"""

import asyncio
import datetime as dt
import html
import json
import os
import re
import secrets
import shutil
import subprocess
import unicodedata
import uuid
import zipfile
from pathlib import Path

import markdown
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from google import genai
from google.genai import types
from pydantic import BaseModel, Field

from common import DATA_DIR, PORT, bridge_url, load_gemini_key, load_token

REPORTS_DIR = DATA_DIR / "reports"
UPLOADS_DIR = DATA_DIR / "uploads"
SOURCES_DIR = DATA_DIR / "sources"
STATE_FILE = DATA_DIR / "state.json"

LANGUAGE = os.environ.get("NOTEBOOKLM_LANGUAGE", "pt_BR")
MODEL = os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")
# Quanto do texto das fontes cabe no prompt. O Gemini aceita muito mais, mas um
# teto protege contra livros gigantes e mantém as respostas rápidas e baratas.
MAX_CONTEXT_CHARS = int(os.environ.get("GEMINI_MAX_CHARS", "400000"))

# Formatos lidos direto; os demais (MOBI, AZW3, FB2...) são convertidos para
# texto com o Calibre, se estiver instalado.
TEXT_SUFFIXES = {".txt", ".md"}
CALIBRE_PATHS = [
    r"C:\Program Files\Calibre2\ebook-convert.exe",
    "/Applications/calibre.app/Contents/MacOS/ebook-convert",
]

REPORT_KINDS = {
    "study_guide": (
        "Guia de estudo",
        "Crie um guia de estudo detalhado em Markdown: um resumo do conteúdo, os "
        "conceitos-chave explicados, uma lista de perguntas de revisão com as "
        "respostas, e um glossário dos termos importantes.",
    ),
    "briefing": (
        "Briefing",
        "Crie um documento de briefing em Markdown: visão geral, principais temas, "
        "fatos e citações mais importantes e as conclusões centrais.",
    ),
    "blog": (
        "Post",
        "Escreva um post de blog envolvente em Markdown com base no conteúdo das fontes.",
    ),
}

REPORTS_DIR.mkdir(parents=True, exist_ok=True)
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
SOURCES_DIR.mkdir(parents=True, exist_ok=True)


TOKEN = load_token()
state_lock = asyncio.Lock()
jobs: dict[str, dict] = {}
running_tasks: set[asyncio.Task] = set()

app = FastAPI(title="Gemini ↔ KOReader")


def require_token(x_bridge_token: str = Header(default="")) -> None:
    if not secrets.compare_digest(x_bridge_token, TOKEN):
        raise HTTPException(status_code=401, detail="Token inválido")


KEY_HINT = (
    "Sem chave da API do Gemini na ponte. Pegue uma em aistudio.google.com/apikey "
    "e defina a variável GEMINI_API_KEY ou crie o arquivo bridge/data/gemini_key.txt."
)


class MissingKeyError(Exception):
    """A chave da API do Gemini não foi configurada na ponte."""


class GeminiError(Exception):
    """O Gemini devolveu um erro."""


@app.exception_handler(MissingKeyError)
async def missing_key_handler(_request, _exc):
    return JSONResponse(status_code=503, content={"detail": KEY_HINT})


@app.exception_handler(GeminiError)
async def gemini_error_handler(_request, exc: GeminiError):
    return JSONResponse(status_code=502, content={"detail": f"Erro do Gemini: {exc}"})


def gemini_client() -> genai.Client:
    key = load_gemini_key()
    if not key:
        raise MissingKeyError()
    return genai.Client(api_key=key)


async def gemini_generate(system: str, history: list[dict], user_text: str) -> str:
    """Gera uma resposta do Gemini com um prompt de sistema e um histórico."""
    client = gemini_client()
    contents = [
        types.Content(role=m["role"], parts=[types.Part(text=m["text"])]) for m in history
    ]
    contents.append(types.Content(role="user", parts=[types.Part(text=user_text)]))
    try:
        resp = await client.aio.models.generate_content(
            model=MODEL,
            contents=contents,
            config=types.GenerateContentConfig(system_instruction=system, temperature=0.4),
        )
    except Exception as exc:  # noqa: BLE001 - devolvido ao Kindle como 502
        raise GeminiError(str(exc) or exc.__class__.__name__) from exc
    return resp.text or ""


# --------------------------------------------------------------------------- #
# Estado local (cadernos, fontes, conversas)

def slugify(text: str, limit: int = 60) -> str:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-")
    return text[:limit] or "documento"


def read_state() -> dict:
    if STATE_FILE.exists():
        state = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    else:
        state = {}
    state.setdefault("notebooks", {})
    state.setdefault("conversations", {})
    return state


def write_state(state: dict) -> None:
    STATE_FILE.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def get_notebook(state: dict, notebook_id: str) -> dict:
    nb = state["notebooks"].get(notebook_id)
    if nb is None:
        raise HTTPException(status_code=404, detail="Caderno não encontrado na ponte.")
    return nb


def source_path(notebook_id: str, source_id: str) -> Path:
    folder = SOURCES_DIR / notebook_id
    folder.mkdir(parents=True, exist_ok=True)
    return folder / f"{source_id}.txt"


def notebook_context(notebook_id: str, nb: dict) -> str:
    """Junta o texto de todas as fontes do caderno, respeitando o teto."""
    parts: list[str] = []
    remaining = MAX_CONTEXT_CHARS
    for source_id, meta in nb.get("sources", {}).items():
        path = source_path(notebook_id, source_id)
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if len(text) > remaining:
            text = text[:remaining] + "\n\n[... fonte truncada ...]"
        parts.append(f"### Fonte: {meta.get('title') or source_id}\n{text}")
        remaining -= len(text)
        if remaining <= 0:
            break
    return "\n\n".join(parts)


# --------------------------------------------------------------------------- #
# Cadernos

class NewNotebook(BaseModel):
    title: str


@app.get("/health")
async def health():
    return {"ok": True}


@app.get("/notebooks", dependencies=[Depends(require_token)])
async def list_notebooks():
    state = read_state()
    return [
        {"id": nid, "title": nb.get("title", ""), "sources": len(nb.get("sources", {}))}
        for nid, nb in state["notebooks"].items()
    ]


@app.post("/notebooks", dependencies=[Depends(require_token)])
async def create_notebook(body: NewNotebook):
    notebook_id = uuid.uuid4().hex[:12]
    async with state_lock:
        state = read_state()
        state["notebooks"][notebook_id] = {
            "title": body.title,
            "created": dt.datetime.now().isoformat(timespec="seconds"),
            "sources": {},
        }
        write_state(state)
    return {"id": notebook_id, "title": body.title, "sources": 0}


# --------------------------------------------------------------------------- #
# Perguntas

class AskRequest(BaseModel):
    notebook_id: str
    question: str
    passage: str | None = None
    book_title: str | None = None
    conversation_id: str | None = None


def ask_system_prompt(context: str) -> str:
    base = (
        f"Você é um assistente de leitura. Responda sempre no idioma {LANGUAGE}. "
        "Baseie-se somente nas fontes do caderno abaixo; se a resposta não estiver "
        "nelas, diga isso com clareza em vez de inventar. Seja direto e organizado."
    )
    if context:
        return f"{base}\n\n=== FONTES DO CADERNO ===\n{context}"
    return f"{base}\n\n(O caderno ainda não tem fontes anexadas.)"


@app.post("/ask", dependencies=[Depends(require_token)])
async def ask(body: AskRequest):
    async with state_lock:
        state = read_state()
        nb = get_notebook(state, body.notebook_id)
        conv_id = body.conversation_id or uuid.uuid4().hex[:12]
        history = list(state["conversations"].get(conv_id, []))

    question = body.question
    if body.passage:
        origin = f' do livro "{body.book_title}"' if body.book_title else ""
        question = f'Trecho{origin}:\n"""\n{body.passage}\n"""\n\n{body.question}'

    context = notebook_context(body.notebook_id, nb)
    answer = await gemini_generate(ask_system_prompt(context), history, question)

    async with state_lock:
        state = read_state()
        convo = state["conversations"].setdefault(conv_id, [])
        convo.append({"role": "user", "text": question})
        convo.append({"role": "model", "text": answer})
        write_state(state)
    return {"answer": answer, "conversation_id": conv_id}


# --------------------------------------------------------------------------- #
# Livro aberto no Kindle -> fonte (texto extraído) do caderno

def find_ebook_convert() -> str | None:
    found = shutil.which("ebook-convert")
    if found:
        return found
    return next((p for p in CALIBRE_PATHS if Path(p).exists()), None)


def html_to_text(raw: str) -> str:
    raw = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", raw)
    raw = re.sub(r"(?s)<[^>]+>", " ", raw)
    raw = html.unescape(raw)
    raw = re.sub(r"[ \t\r\f]+", " ", raw)
    raw = re.sub(r"\n\s*\n\s*\n+", "\n\n", raw)
    return raw.strip()


def extract_epub(path: Path) -> str:
    parts = []
    with zipfile.ZipFile(path) as zf:
        names = sorted(n for n in zf.namelist() if n.lower().endswith((".xhtml", ".html", ".htm")))
        for name in names:
            try:
                raw = zf.read(name).decode("utf-8", "ignore")
            except (OSError, zipfile.BadZipFile):
                continue
            text = html_to_text(raw)
            if text:
                parts.append(text)
    return "\n\n".join(parts)


def extract_pdf(path: Path) -> str:
    from pypdf import PdfReader

    reader = PdfReader(str(path))
    return "\n\n".join((page.extract_text() or "") for page in reader.pages)


def extract_via_calibre(path: Path) -> str:
    converter = find_ebook_convert()
    if not converter:
        raise HTTPException(
            status_code=415,
            detail=f"Não sei ler {path.suffix}. Instale o Calibre no computador da ponte "
            "para converter automaticamente, ou use EPUB/PDF/TXT.",
        )
    txt = path.with_suffix(".txt")
    result = subprocess.run([converter, str(path), str(txt)], capture_output=True, timeout=900)
    if result.returncode != 0 or not txt.exists():
        raise HTTPException(status_code=422, detail=f"Falha ao converter {path.suffix} com o Calibre.")
    return txt.read_text(encoding="utf-8", errors="ignore")


def extract_text(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in TEXT_SUFFIXES:
        return path.read_text(encoding="utf-8", errors="ignore")
    if suffix == ".epub":
        return extract_epub(path)
    if suffix == ".pdf":
        return extract_pdf(path)
    return extract_via_calibre(path)


@app.post("/notebooks/{notebook_id}/book", dependencies=[Depends(require_token)])
async def upload_book(notebook_id: str, request: Request, filename: str, title: str, book_key: str):
    """Recebe o arquivo do livro (corpo cru), extrai o texto e o guarda como fonte."""
    state = read_state()
    nb = get_notebook(state, notebook_id)

    # Mesmo livro já enviado para este caderno: reaproveita a fonte.
    for source_id, meta in nb.get("sources", {}).items():
        if meta.get("book_key") == book_key:
            return {"source_id": source_id, "ready": True, "reused": True}

    work_dir = UPLOADS_DIR / uuid.uuid4().hex[:12]
    work_dir.mkdir()
    try:
        raw = work_dir / f"livro{Path(filename).suffix.lower()}"
        with raw.open("wb") as fh:
            async for chunk in request.stream():
                fh.write(chunk)
        if raw.stat().st_size == 0:
            raise HTTPException(status_code=400, detail="Arquivo do livro chegou vazio.")
        text = await asyncio.to_thread(extract_text, raw)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    if not text.strip():
        raise HTTPException(status_code=422, detail="Não consegui extrair texto deste arquivo.")

    source_id = uuid.uuid4().hex[:12]
    source_path(notebook_id, source_id).write_text(text, encoding="utf-8")
    async with state_lock:
        state = read_state()
        nb = get_notebook(state, notebook_id)
        nb.setdefault("sources", {})[source_id] = {
            "title": title,
            "kind": "book",
            "book_key": book_key,
            "chars": len(text),
        }
        write_state(state)
    return {"source_id": source_id, "ready": True, "reused": False}


@app.get("/notebooks/{notebook_id}/sources/{source_id}", dependencies=[Depends(require_token)])
async def source_status(notebook_id: str, source_id: str):
    state = read_state()
    nb = get_notebook(state, notebook_id)
    meta = nb.get("sources", {}).get(source_id)
    if meta is None:
        raise HTTPException(status_code=404, detail="Fonte não encontrada no caderno.")
    # A extração é feita no upload, então a fonte já nasce pronta.
    return {"ready": True, "error": False, "title": meta.get("title")}


# --------------------------------------------------------------------------- #
# Destaques do Kindle -> fonte do caderno

class Highlight(BaseModel):
    text: str
    note: str | None = None
    chapter: str | None = None
    page: str | int | None = None
    datetime: str | None = None


class HighlightsRequest(BaseModel):
    notebook_id: str
    book_title: str
    authors: str | None = None
    highlights: list[Highlight] = Field(default_factory=list)


def highlights_markdown(body: HighlightsRequest) -> str:
    lines = [f"# Destaques de leitura: {body.book_title}"]
    if body.authors:
        lines.append(f"Autor(es): {body.authors}")
    lines.append(f"Exportado do Kindle (KOReader) em {dt.date.today():%d/%m/%Y}.")
    lines.append("")
    current_chapter = None
    for h in body.highlights:
        if h.chapter and h.chapter != current_chapter:
            current_chapter = h.chapter
            lines += ["", f"## {h.chapter}", ""]
        where = f" (pág. {h.page})" if h.page not in (None, "") else ""
        lines.append(f"> {h.text.strip()}{where}")
        if h.note:
            lines.append(f"\nMinha nota: {h.note.strip()}")
        lines.append("")
    return "\n".join(lines)


@app.post("/highlights", dependencies=[Depends(require_token)])
async def send_highlights(body: HighlightsRequest):
    if not body.highlights:
        raise HTTPException(status_code=400, detail="Este livro não tem destaques.")
    book_key = f"highlights::{body.book_title}"
    title = f"Destaques – {body.book_title}"
    text = highlights_markdown(body)
    async with state_lock:
        state = read_state()
        nb = get_notebook(state, body.notebook_id)
        sources = nb.setdefault("sources", {})
        # Substitui a fonte de destaques enviada antes para o mesmo livro.
        old = next((sid for sid, m in sources.items() if m.get("book_key") == book_key), None)
        if old:
            sources.pop(old, None)
            source_path(body.notebook_id, old).unlink(missing_ok=True)
        source_id = uuid.uuid4().hex[:12]
        source_path(body.notebook_id, source_id).write_text(text, encoding="utf-8")
        sources[source_id] = {
            "title": title,
            "kind": "highlights",
            "book_key": book_key,
            "chars": len(text),
        }
        write_state(state)
    return {"source_id": source_id, "count": len(body.highlights), "replaced": bool(old)}


# --------------------------------------------------------------------------- #
# Documentos gerados (guia de estudo, briefing, post) -> HTML para o Kindle

class ReportRequest(BaseModel):
    notebook_id: str
    kind: str = "study_guide"
    notebook_title: str | None = None
    custom_prompt: str | None = None


HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>{title}</title>
<style>body{{font-family:serif;line-height:1.4}} h1,h2,h3{{font-family:sans-serif}}
blockquote{{margin-left:1em;padding-left:.6em;border-left:3px solid #000}}
table{{border-collapse:collapse}} td,th{{border:1px solid #000;padding:.2em .4em}}</style>
</head><body>
{body}
</body></html>
"""


async def run_report(job_id: str, body: ReportRequest) -> None:
    job = jobs[job_id]
    label, instruction = REPORT_KINDS[body.kind]
    try:
        state = read_state()
        nb = get_notebook(state, body.notebook_id)
        context = notebook_context(body.notebook_id, nb)
        if not context:
            raise RuntimeError("o caderno ainda não tem fontes para gerar o documento")
        system = (
            f"Você gera documentos de estudo no idioma {LANGUAGE}, formatados em Markdown, "
            "com base somente nas fontes fornecidas."
        )
        prompt = instruction
        if body.custom_prompt:
            prompt += f"\n\nInstrução adicional do usuário: {body.custom_prompt}"
        prompt += f"\n\n=== FONTES ===\n{context}"
        md_text = await gemini_generate(system, [], prompt)

        title = f"{label} - {body.notebook_title or 'Gemini'}"
        html_body = markdown.markdown(md_text, extensions=["tables"])
        filename = f"{dt.datetime.now():%Y%m%d-%H%M}-{slugify(title)}.html"
        (REPORTS_DIR / filename).write_text(
            HTML_TEMPLATE.format(title=html.escape(title), body=html_body), encoding="utf-8"
        )
        job.update(status="done", filename=filename)
    except MissingKeyError:
        job.update(status="error", error=KEY_HINT)
    except Exception as exc:  # noqa: BLE001 - o erro é devolvido ao Kindle
        job.update(status="error", error=str(exc) or exc.__class__.__name__)


@app.post("/reports", dependencies=[Depends(require_token)])
async def create_report(body: ReportRequest):
    if body.kind not in REPORT_KINDS:
        raise HTTPException(status_code=400, detail=f"Tipo inválido. Use: {', '.join(REPORT_KINDS)}")
    job_id = uuid.uuid4().hex[:12]
    jobs[job_id] = {"status": "running"}
    task = asyncio.create_task(run_report(job_id, body))
    running_tasks.add(task)
    task.add_done_callback(running_tasks.discard)
    return {"job_id": job_id}


@app.get("/reports", dependencies=[Depends(require_token)])
async def list_reports():
    files = sorted(REPORTS_DIR.glob("*.html"), reverse=True)
    return [{"filename": f.name, "size": f.stat().st_size} for f in files[:30]]


@app.get("/reports/{job_id}", dependencies=[Depends(require_token)])
async def report_status(job_id: str):
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Tarefa não encontrada (a ponte foi reiniciada?)")
    return jobs[job_id]


@app.get("/files/{filename}", dependencies=[Depends(require_token)])
async def download_file(filename: str):
    path = (REPORTS_DIR / filename).resolve()
    if path.parent != REPORTS_DIR.resolve() or not path.is_file():
        raise HTTPException(status_code=404, detail="Arquivo não encontrado")
    return FileResponse(path, media_type="text/html; charset=utf-8", filename=filename)


if __name__ == "__main__":
    import uvicorn

    print("=" * 60)
    print(f"  Endereço para o KOReader: {bridge_url()}")
    print(f"  Token:                    {TOKEN}")
    print(f"  Modelo Gemini:            {MODEL}")
    if load_gemini_key():
        print("  Chave da API:             configurada ✓")
    else:
        print("  Chave da API:             FALTANDO — veja abaixo")
        print("  " + KEY_HINT)
    print("  (ou rode `python install_plugin.py` com o Kindle no USB")
    print("   para instalar o plugin já configurado)")
    print("=" * 60)
    uvicorn.run(app, host="0.0.0.0", port=PORT)
