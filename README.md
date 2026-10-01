# Gemini ↔ Kindle (KOReader)

Converse com a IA do Google **Gemini** direto do Kindle, em **tela dividida**: o livro em cima e o painel embaixo.

```
┌──────────────────────────┐
│  texto do livro          │  ← toques aqui continuam virando a página
│  (EPUB se reorganiza     │     e selecionando texto
│   para caber aqui)       │
├──────────────────────────┤
│ ☰ Dom Casmurro        ✕  │
│ P: Quem é Capitu?        │  ← painel do assistente
│ Capitu é ...             │     (toque no texto para rolar)
│ [Perguntar] [Resumir cap]│
│ [Destaques] [Mais…]      │
└──────────────────────────┘
```

Sem login de navegador e sem cookies: a ponte usa a **API oficial do Gemini**, com uma **chave de API** que fica só no computador da ponte. Você cola a chave uma vez e pronto — ela não expira em semanas como uma sessão e o Kindle nunca a vê.

- **Abrir o painel**: **segure o canto inferior direito da tela**, um gesto que já vem configurado. Também dá pelo menu **Ferramentas → Gemini → Painel**. Para trocar o gesto, vá em *Configurações → Gestos* e use a ação "Painel do Gemini".
- **O livro aberto vira fonte**: na primeira vez, o painel oferece:
  - **Criar caderno com este livro**: cria um caderno com o nome do livro e usa o texto do arquivo (EPUB/PDF/TXT) como fonte;
  - **Escolher caderno existente**: usa um caderno seu e, se você quiser, adiciona o livro a ele.

  A escolha fica salva **por livro**: ao reabrir o livro, o painel já usa o caderno certo. Reenviar o mesmo livro reaproveita a fonte em vez de duplicá-la.
- **Perguntar sobre um trecho**: selecione um texto → **Gemini** → "Explicar este trecho" ou "Perguntar sobre o trecho…". A resposta aparece no painel, e as perguntas seguintes continuam a mesma conversa.
- **Resumir capítulo**: resume o capítulo em que você está.
- **Enviar destaques**: manda seus destaques e notas como uma fonte do caderno. Reenviar **substitui** a versão anterior.
- **Mais…**: trocar de caderno, ver a conversa completa, começar uma nova conversa, tamanho do painel (40–70%), fechar.
- **Gerar guia de estudo / briefing**: o Gemini gera o documento, a ponte converte para HTML e o Kindle baixa para `Gemini/` na pasta inicial, pronto para ler.

Em **EPUB/FB2/MOBI**, o texto do livro se reorganiza para caber acima do painel. Isso leva alguns segundos a cada abertura e fechamento do painel; dá para desligar em **Mais…**.
Em **PDF**, o painel apenas cobre a parte de baixo da página.

MOBI/AZW3/FB2 são convertidos para texto automaticamente se o **Calibre** estiver instalado no computador da ponte.

## Como funciona

```
Kindle (KOReader + plugin)  ──Wi-Fi/HTTP──▶  Ponte (PC, Python)  ──API──▶  Gemini (Google)
   notebooklm.koplugin                         bridge/server.py       google-genai
```

A ponte guarda os **cadernos** e suas **fontes** (o texto extraído dos seus livros e destaques) localmente, no computador. A cada pergunta, ela manda a pergunta junto do texto das fontes para o Gemini e devolve a resposta ao Kindle. O Kindle fala só com a ponte, usando um token; a **chave da API nunca sai do computador**.

## Requisitos

- Kindle com **KOReader** instalado (exige jailbreak).
- Um computador na **mesma rede Wi-Fi** do Kindle, com Python 3.10+.
- Uma **chave da API do Gemini** (gratuita): pegue em <https://aistudio.google.com/apikey>.

## 1. Ponte (no computador)

```bash
cd notebooklm-kindle/bridge
python -m venv .venv
.venv\Scripts\activate          # no Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt
```

Informe a chave da API do Gemini de uma destas formas (ela fica só aqui):

```bash
# opção A: variável de ambiente
set GEMINI_API_KEY=sua-chave-aqui        # Windows (PowerShell: $env:GEMINI_API_KEY="...")
export GEMINI_API_KEY=sua-chave-aqui     # Linux/macOS

# opção B: arquivo (a ponte lê bridge/data/gemini_key.txt)
echo sua-chave-aqui > data\gemini_key.txt
```

Depois rode a ponte:

```bash
python server.py
```

Ao iniciar, a ponte mostra o **endereço**, o **token** e se a chave foi encontrada:

```
  Endereço para o KOReader: http://192.168.0.10:8765
  Token:                    Xy3...
  Modelo Gemini:            gemini-2.5-flash
  Chave da API:             configurada ✓
```

O token fica salvo em `bridge/data/token.txt`. Para escolher outro, defina `BRIDGE_TOKEN`.

**Firewall do Windows**: libere a porta para redes privadas (PowerShell como administrador):

```powershell
New-NetFirewallRule -DisplayName "Gemini Kindle" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Private
```

Variáveis opcionais:

| Variável              | Padrão             | Uso                                         |
|-----------------------|--------------------|---------------------------------------------|
| `GEMINI_API_KEY`      | —                  | Chave da API (ou use `data/gemini_key.txt`) |
| `GEMINI_MODEL`        | `gemini-2.5-flash` | Modelo do Gemini                            |
| `GEMINI_MAX_CHARS`    | `400000`           | Teto de texto das fontes enviado por pergunta |
| `BRIDGE_PORT`         | `8765`             | Porta HTTP                                  |
| `BRIDGE_TOKEN`        | gerado             | Token exigido pelo Kindle                   |
| `BRIDGE_DATA_DIR`     | `bridge/data`      | Cadernos, fontes e documentos gerados       |
| `NOTEBOOKLM_LANGUAGE` | `pt_BR`            | Idioma das respostas e dos documentos       |

## 2. Plugin (no Kindle): instalação automática

Conecte o Kindle por USB e, na pasta `bridge`, rode:

```bash
python install_plugin.py
```

O instalador acha o Kindle, copia o plugin para `koreader/plugins/` e grava o arquivo `notebooklm_config.lua`, que contém:
- o **endereço** e o **token** desta ponte, para não precisar digitar nada no Kindle;
- o **gesto** para abrir e fechar o painel: por padrão, **segurar o canto inferior direito da tela**;
- a altura do painel.

A chave da API **não** vai para o Kindle — ela fica só na ponte.

Depois, ejete o Kindle e abra um livro no KOReader. Na primeira vez, o plugin aplica a configuração e cadastra o gesto. Ele **não sobrescreve** um gesto que você já usa: se o canto estiver ocupado, ele avisa e não muda nada. Em seguida, use o gesto e toque em **Criar caderno com este livro**.

Opções:

```bash
python install_plugin.py --gesto dois-dedos      # canto | dois-dedos | toque-duplo | nenhum
python install_plugin.py --painel 0.6            # painel ocupando 60% da tela
python install_plugin.py --url http://100.64.0.2:8765   # outro endereço (ex.: Tailscale)
python install_plugin.py --kindle E:\            # se a detecção automática falhar
```

Sem Kindle conectado, o instalador gera a pasta pronta em `dist/notebooklm.koplugin` para você copiar à mão.
Se o IP do computador mudar, é só rodar o instalador de novo: o plugin percebe a configuração nova e atualiza.

### Instalação manual

1. Copie a pasta `notebooklm.koplugin` para `koreader/plugins/` no Kindle e reinicie o KOReader.
2. Abra **Ferramentas (ícone de chave) → Gemini → Configurar servidor** e informe o endereço e o token.
3. O gesto padrão é cadastrado da mesma forma ao abrir o primeiro livro.

## Problemas comuns

| Mensagem no Kindle                         | Solução                                                    |
|--------------------------------------------|------------------------------------------------------------|
| "Não foi possível falar com a ponte"       | Confira o IP, se `server.py` está rodando e o firewall.    |
| "Erro 401: Token inválido"                 | Redigite o token mostrado pela ponte.                      |
| "Sem chave da API do Gemini"               | Defina `GEMINI_API_KEY` ou crie `bridge/data/gemini_key.txt` e reinicie a ponte. |
| "Erro do Gemini: ..."                      | Chave inválida, sem cota, ou modelo indisponível. Veja o console da ponte. |
| O documento está demorando                 | Use **Baixar documentos gerados** mais tarde.              |

## Avisos

- A API do Gemini tem uma **camada gratuita** generosa; acima dela, há cobrança. Veja os limites e preços no Google AI Studio.
- O texto das fontes (livros, destaques) é enviado ao Gemini a cada pergunta. Não use material confidencial que você não queira mandar para a API do Google.
- Se um modelo não estiver disponível para a sua chave, defina outro em `GEMINI_MODEL`.
- A ponte usa HTTP sem criptografia. Rode-a só em redes confiáveis, como a de casa.
