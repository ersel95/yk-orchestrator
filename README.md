# YK iOS Daily Orchestrator

Yapı Kredi'de iOS Developer olarak günlük rutinini AI agent'larla otomatize eden lokal dashboard.

```
┌──────────────────────────────────────────────────────────────┐
│  Bugün │ PR'lar │ Daily Geçmişi │ Transkript │ Chat │ TF     │
├──────────────────────────────────────────────────────────────┤
│  Next.js + shadcn/ui (lokal)                                 │
└──────────────────────┬───────────────────────────────────────┘
                       │ HTTP/SSE
┌──────────────────────▼───────────────────────────────────────┐
│  FastAPI + LangGraph orkestratör                              │
│   Jira · Yesterday · Standup · PRAuthor · PRReviewer ·        │
│   TranscriptIngest · Chat (RAG) · TestFlight                  │
└─────┬─────────────────┬──────────────────┬───────────────────┘
      │                 │                  │
   LM Studio         SQLite + Chroma    Jira / Bitbucket / Git / Fastlane
   (Qwen2.5 72B)     (lokal)            (VPN üzerinden)
```

## Ne yapar?

- **Bugün**: Jira'dan açık işlerini çeker, dün ne yaptığını (Jira+PR+commit) toplar, daily standup metnini Türkçe üretir
- **PR'lar**: Sana atanmış PR'ları listeler, AI ile diff özeti çıkarır; kendi branch'inden tek tıkla PR açıklaması üretip Bitbucket'a push eder (manuel onay)
- **Daily Geçmişi**: Tüm geçmiş daily metinleri arşivler
- **Transkriptler**: Daily konuşmasının metnini yapıştır → konuşmacı bazlı özet + aksiyon listesi
- **Chat**: Tüm geçmiş veriye RAG ile sorgu (Türkçe, lokal LLM)
- **TestFlight**: Manuel onay sonrası Fastlane ile build + upload

## Kurulum (son kullanıcı — `.dmg`)

> En kolay yol. Dev gerektirmez. Apple Silicon (M1+) macOS 13+.

1. **İndir** — [Releases](../../releases/latest) sayfasından `YKOrchestrator-X.Y.Z.dmg`.
2. **Aç** — `.dmg`'yi çift tıkla → açılan pencerede `YK Orchestrator.app`'i `Applications` klasörüne sürükle.
3. **Çalıştır** — Spotlight'tan "YK Orchestrator" yaz veya `/Applications/YK Orchestrator.app`'i aç.
4. **Setup Wizard** — İlk açılışta sihirbaz açılır:
   - **Jira**: base URL + e-posta + PAT (token Keychain'e yazılır)
   - **Bitbucket**: base URL + kullanıcı + HTTP token
   - **LM Studio**: base URL + model adları
   - **Projeler**: kaç tane iOS projen varsa her biri için (slug, Jira keys, repo, lokal path)
5. Wizard biter, backend başlar, dashboard açılır.

**Güncelleme** — Otomatik (Sparkle). Yeni sürüm çıkarsa app menüden "Güncelleme Kontrol Et..." veya arka planda kendiliğinden bildirir.

### Önkoşullar (her açılışta)

- **VPN** bağlı — Jira/Bitbucket için
- **LM Studio** açık + model yüklü — daily/chat/PR özetleri için (port 1234)
- (TestFlight için) Fastlane ve Xcode projesi lokal yolu

### Veri konumları

```
~/Library/Application Support/YK Orchestrator/   ← config.json, orchestrator.db, chroma/
~/Library/Logs/YK Orchestrator/                   ← api.log, app.log
~/Library/Keychains (varsayılan)                  ← token'lar (com.yapikredi.ykorchestrator)
```

İçeriği temizlemek istersen bu klasörleri sil; Wizard tekrar açılır.

---

## Geliştirici kurulumu (kaynaktan)

### 1. Ön koşullar

- macOS 13+ (Apple Silicon önerilir)
- Python 3.12 (PyInstaller paketleme için)
- Node.js 20+
- [LM Studio](https://lmstudio.ai/) (veya Ollama)
- Xcode 15+ + Xcode CLT
- `xcodegen`: `brew install xcodegen`

### 2. LLM modellerini indir

LM Studio'yu aç, şu modelleri indir:

| Model | Boyut | Rol |
|---|---|---|
| `qwen/qwen3.6-35b-a3b` (MoE, 3B aktif) | ~22 GB | Genel + kod |
| `text-embedding-nomic-embed-text-v1.5` | ~250 MB | Embedding (RAG) |

LM Studio'da **Local Server** sekmesinden modelleri yüklü tutarak başlat (port 1234).

### 3. Backend / dashboard dev modu

```bash
cd "Automated Report"
./scripts/setup.sh        # venv + npm install
cp .env.example .env      # değerleri doldur
./scripts/run-dev.sh      # backend (8765) + dashboard (3000)
```

`.env`'i kullanmak için repo içinden çalışmak gerekir. `.app` çalıştırırken `~/Library/Application Support/.../config.json` öncelik kazanır.

### 4. Yerel `.app` build (imzasız test)

```bash
SKIP_NOTARIZE=1 bash build/build-app.sh
open build/release/export/"YK Orchestrator.app"
```

Üretim sırası: backend (PyInstaller onedir) → dashboard (next export) → resources kopya → xcodebuild archive → codesign → hdiutil dmg.

---

## Dağıtım pipeline'ı

### Lokal release (`.dmg`)

```bash
# Tek seferlik: notarytool credential profile'ı kur (app-specific password gerek)
xcrun notarytool store-credentials ykorch \
  --apple-id ersel@example.com \
  --team-id XZAJKFLEF8 \
  --password <app-specific-password>

# Full pipeline (backend + dashboard + .app + sign + notarize + .dmg)
NOTARYTOOL_PROFILE=ykorch bash build/build-app.sh

# Çıktı:
#   build/release/YKOrchestrator-X.Y.Z.dmg     (imzalı + notarized + stapled)
#   build/release/export/YK Orchestrator.app   (test için)
```

ENV override'lar:

| Değişken | Default | Açıklama |
|---|---|---|
| `VERSION` | `project.yml`'den | Üretilecek dmg sürümü |
| `SIGNING_IDENTITY` | `Developer ID Application: Ersel Tarhan (XZAJKFLEF8)` | codesign identity |
| `TEAM_ID` | `XZAJKFLEF8` | Apple Team ID |
| `NOTARYTOOL_PROFILE` | (yoksa atlanır) | Yukarıda kurulan profile adı |
| `SKIP_BACKEND/DASHBOARD/NOTARIZE/DMG` | `0` | Debug için adım atla |

### GitHub Actions (otomatik release)

`v0.2.0` formatında tag push'ladığında `.github/workflows/release.yml` tetiklenir, `macos-14` runner'da:

1. Sertifikayı içe aktarır (`apple-actions/import-codesign-certs`)
2. notarytool profile kurar
3. `build-app.sh` çalıştırır
4. Sparkle EdDSA ile appcast.xml imzalar
5. GitHub Release'e `.dmg` + `appcast.xml` yükler

Gerekli secrets:

| Secret | Açıklama |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | `.p12` sertifikası base64'lü |
| `DEVELOPER_ID_P12_PASSWORD` | `.p12` parolası |
| `APPLE_ID` | Notarization için Apple ID e-postası |
| `APPLE_TEAM_ID` | `XZAJKFLEF8` |
| `APPLE_APP_PASSWORD` | App-specific password |
| `SIGNING_IDENTITY` | Tam identity string |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Sparkle `sign_update --generate-keys` çıktısı |

Sparkle public key'i `desktop/project.yml` → `SUPublicEDKey`'e yerleştirilmeli. URL `SUFeedURL` GitHub Releases path'i.

---

## Klasör Yapısı

```
.
├── apps/
│   ├── api/                    FastAPI backend (Python)
│   │   ├── app/
│   │   │   ├── __main__.py     PyInstaller entry point (--port arg)
│   │   │   ├── agents/         8 AI agent (yesterday, standup, pr, chat, transcript, …)
│   │   │   ├── integrations/   LLM, Jira, Bitbucket, Git, Fastlane, RAG
│   │   │   ├── routers/        REST + SSE endpoint'leri
│   │   │   ├── models/         SQLModel tabloları
│   │   │   └── core/
│   │   │       ├── paths.py    runtime path resolver (dev / bundled)
│   │   │       ├── config.py   ENV > config.json > default
│   │   │       ├── db.py       SQLite + WAL + ensure default project
│   │   │       └── logging.py
│   │   └── build/
│   │       └── ykorch-api.spec PyInstaller spec
│   └── dashboard/              Next.js 15 (static export)
│       ├── next.config.mjs     output: 'export', trailingSlash, file:// uyumlu
│       └── src/
│           ├── app/            Sayfa rotaları (8 sayfa)
│           ├── components/
│           └── lib/
│               └── utils.ts    window.__YKORCH_API_BASE__ runtime injection
├── desktop/                    Native macOS app
│   ├── project.yml             xcodegen spec (Sparkle SPM, entitlements, Info.plist)
│   └── YKOrchestrator/
│       ├── Sources/
│       │   ├── AppMain.swift           SwiftUI @main + Sparkle updater
│       │   ├── RootView.swift          Wizard | Splash | Dashboard router
│       │   ├── SidecarManager.swift    ykorch-api Process + dinamik port + /health polling
│       │   ├── DashboardView.swift     WKWebView + atDocumentStart API base injection
│       │   ├── SetupWizardView.swift   5 adımlı kurulum
│       │   ├── ConfigStore.swift       config.json read/write
│       │   ├── KeychainStore.swift     Token'lar Keychain'de
│       │   └── LogPaths.swift          ~/Library/Logs, Application Support
│       ├── Info.plist
│       └── YKOrchestrator.entitlements
├── build/                      Paketleme pipeline'ı
│   ├── build-backend.sh        → dist/ykorch-api/
│   ├── build-dashboard.sh      → dist/dashboard/
│   ├── build-app.sh            → release/YKOrchestrator-X.Y.Z.dmg
│   ├── dist/                   Ara çıktılar (gitignore)
│   └── release/                .app + .dmg + appcast.xml (gitignore)
├── scripts/                    Dev mod + CI (setup, run-dev, release.sh, update_appcast.py)
├── launcher/                   Eski dev launcher'ları (.app uygulaması gelince gereksiz)
└── .github/workflows/
    └── release.yml             Tag push → macos-14 build + sign + notarize + release
```

## Günlük Akış

```
Gün içi  →  PR aç (draft → AI açıklama → manuel onay → Bitbucket'a push)
            PR review et (AI özet ile diff'i hızlı kavra)
            Chat'te geçmişe sor: "geçen Salı IOS-1234 için ne demiştik?"
18:00    →  TestFlight sayfasına gel, "Anladım, devam et" → "TestFlight'a Yükle"
            Fastlane çıktısı canlı stream olur.
```

## Mimari Notlar

- **Multi-LLM router** (v0.3+): rol bazlı (provider, model) atama. Provider'lar: LM Studio, Anthropic API, Claude Code (subscription via CLI), OpenAI.
- **RAG**: ChromaDB lokal olarak persist olur, chat sorgulamada kullanılır.
- **Veri akışı**: SQLite (kalıcı kayıt) + Chroma (vektör arama) çift katmanlı.
- **Streaming**: Chat ve TestFlight çıktısı SSE ile gerçek zamanlı dashboard'a düşer.
- **Human-in-the-loop**: PR açıklaması, TestFlight upload — hepsi onay ister.

## Sorun Giderme

| Belirti | Çözüm |
|---|---|
| Health badge'de LLM kırmızı | LM Studio Local Server'ı başlat (Start Server, port 1234) |
| Jira/Bitbucket kırmızı | VPN bağlı mı? Token doğru mu? |
| `Fastlane bulunamadı` | `.env` içindeki `FASTLANE_PROJECT_DIR` doğru mu? `fastlane/` klasörü var mı? |
| Daily üretimi çok yavaş | Model çok büyükse `LLM_MODEL_GENERAL=qwen2.5-32b-instruct` ile küçült |
| Embedding hatası | `nomic-embed-text` modelini de yüklü tut (LM Studio'da yan yana çalışabilir) |

## Geliştirme

```bash
# Backend
cd apps/api
uvicorn app.main:app --reload

# Frontend
cd apps/dashboard
npm run dev

# Ruff (linter)
ruff check apps/api
```

## Lisans

İç kullanım. Yapı Kredi A.Ş.
