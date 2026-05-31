# Mimari

## Veri Akışı

```
                 ┌──────────────────────────────────────┐
                 │              Dashboard                │
                 │   Next.js · React Query · TanStack    │
                 └─────────┬───────────────┬─────────────┘
                           │ REST          │ SSE
                  ┌────────▼────┐    ┌─────▼─────────┐
                  │   FastAPI   │    │ EventSource   │
                  │   routers   │    │ (chat/upload) │
                  └────────┬────┘    └───────┬───────┘
                           │                 │
                  ┌────────▼─────────────────▼──────────┐
                  │           Agent Layer               │
                  │  (LangGraph state machines)         │
                  └─────┬───────────┬───────────┬───────┘
                        │           │           │
                ┌───────▼──┐  ┌─────▼─────┐  ┌──▼─────────┐
                │ LM Studio│  │  SQLite   │  │  ChromaDB  │
                │  (LLM)   │  │  (kalıcı) │  │  (RAG)     │
                └──────────┘  └───────────┘  └────────────┘
                        │
                ┌───────▼─────────────────────────┐
                │  Jira · Bitbucket · Git · Fastlane │  (VPN)
                └─────────────────────────────────┘
```

## Agent'lar

| Agent | Tetik | Girdi | Çıktı | Manuel onay |
|---|---|---|---|---|
| JiraAgent | Sabah / manuel | — | Jira issue cache + RAG | Hayır |
| YesterdayAgent | Standup öncesi | Tarih | Done issue + merged PR + commit | Hayır |
| StandupAgent | Manuel / sabah | Yesterday + bugün açık + blocker | Daily metni | **Evet (kaydet)** |
| PRAuthorAgent.draft | Manuel | branch | Başlık + açıklama önerisi | — |
| PRAuthorAgent.open_pr | Manuel | onaylı içerik | Bitbucket PR | **Evet** |
| PRReviewerAgent.list | Otomatik | — | Atanan PR listesi | — |
| PRReviewerAgent.summarize | Tıklayınca | PR id | Diff özeti | — |
| TranscriptIngestAgent | Manuel | Yapıştırılan metin | Konuşmacı + aksiyon JSON | — |
| ChatAgent | Manuel | Soru | RAG cevabı + kaynaklar | — |
| TestFlightAgent | Manuel | Lane | Fastlane stream | **Evet** |

## Veri Tabanı

SQLite (`data/orchestrator.db`):

- `daily_standups` — günlük standup metinleri
- `daily_tasks` — alt görevler (manuel veya Jira'dan)
- `jira_issue_cache` — Jira issue cache (raw_json dahil)
- `pull_request_cache` — PR cache + AI özetleri
- `transcripts` + `transcript_utterances` — konuşma metni + parse edilmiş satırlar
- `chat_threads` + `chat_messages` — chat geçmişi
- `settings_kv` — runtime yapılandırma (opsiyonel override)

## ChromaDB Koleksiyonları

- `daily` — daily metinleri (`daily-YYYY-MM-DD`)
- `transcript` — her konuşma satırı ayrı doc (`transcript-{id}-{order}`)
- `pull_request` — PR başlık + diff özet (`{repo}:{pr_id}`)
- `jira` — issue özetleri (`{ISSUE-KEY}`)

Embedding: `nomic-embed-text` (lokal, LM Studio).

## Güvenlik & Veri Lokalliği

- **Hiçbir veri cloud'a çıkmaz**. LLM lokal LM Studio'da, embedding lokal, SQLite + Chroma lokal.
- Jira/Bitbucket erişimi sadece kullanıcı tokeniyle, sadece kullanıcı VPN'deyken.
- `.env` git ignore'da, hassas değerleri commit etme.
- Fastlane App Store Connect API key'i Fastlane'in standart konumundan okur (`~/.appstoreconnect/`).

## Genişletme

### Yeni agent ekleme

1. `apps/api/app/agents/yeni_agent.py` oluştur
2. Gerekiyorsa promptu `prompts.py`'e ekle
3. Endpoint için yeni router veya mevcut router'a fonksiyon
4. Dashboard'da sayfa veya buton

### Farklı LLM runtime'a geçiş

`.env`'de `LLM_BASE_URL`'i değiştir:
- LM Studio: `http://127.0.0.1:1234/v1`
- Ollama: `http://127.0.0.1:11434/v1` (modelleri Ollama format'ında pull et)
- vLLM: `http://127.0.0.1:8000/v1`

### Modeli değiştirme

`.env`'de `LLM_MODEL_GENERAL`, `LLM_MODEL_CODE`, `LLM_MODEL_EMBED` değiştir. Yeniden başlat.
