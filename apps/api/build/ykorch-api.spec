# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec — YK Orchestrator API binary.

Build:
    pyinstaller apps/api/build/ykorch-api.spec --noconfirm

Hedef: Apple Silicon (arm64) macOS tek-dosya binary.
Çıktı: dist/ykorch-api
"""

from __future__ import annotations

from pathlib import Path

from PyInstaller.utils.hooks import (
    collect_data_files,
    collect_submodules,
)

SPEC_DIR = Path(SPECPATH).resolve()
API_DIR = SPEC_DIR.parent           # apps/api
APP_DIR = API_DIR / "app"

# ---- Hidden imports ----------------------------------------------------------
# PyInstaller statik analiz dinamik importları yakalayamaz. Aşağıdakiler
# runtime'da getattr/__import__ ile çağrıldığı için explicit liste lazım.

hiddenimports: list[str] = []

# Uvicorn worker'ları + protokoller
hiddenimports += collect_submodules("uvicorn")

# FastAPI / Starlette internalleri (genelde gerekmez ama emniyet)
hiddenimports += collect_submodules("starlette")

# SQLModel + SQLAlchemy dialect/aiosqlite
hiddenimports += [
    "sqlalchemy.dialects.sqlite",
    "sqlalchemy.dialects.sqlite.aiosqlite",
    "aiosqlite",
]

# LangGraph + LangChain — dinamik provider registry kullanıyorlar
hiddenimports += collect_submodules("langgraph")
hiddenimports += collect_submodules("langchain_core")
hiddenimports += collect_submodules("langchain_openai")

# ChromaDB — telemetry, providers, default embedding fn, sqlite impl
hiddenimports += collect_submodules("chromadb")
hiddenimports += [
    "chromadb.telemetry.product.posthog",
    "chromadb.api.fastapi",
    "chromadb.db.impl.sqlite",
    "chromadb.segment.impl.manager.local",
    "chromadb.segment.impl.metadata.sqlite",
    "chromadb.segment.impl.vector.local_hnsw",
    "chromadb.segment.impl.vector.local_persistent_hnsw",
    "chromadb.utils.embedding_functions",
    "onnxruntime",
    "tokenizers",
]

# APScheduler trigger'ları
hiddenimports += [
    "apscheduler.triggers.cron",
    "apscheduler.triggers.interval",
    "apscheduler.triggers.date",
    "apscheduler.executors.asyncio",
    "apscheduler.jobstores.memory",
]

# Bizim kendi router/agent/model modüllerimiz — main.py'de explicit import var
# ama emniyet için tarama:
hiddenimports += collect_submodules("app")

# ---- Data files --------------------------------------------------------------
# ChromaDB default embedding modeli (onnx) ve tokenizer kaynakları
datas: list[tuple[str, str]] = []
try:
    datas += collect_data_files("chromadb")
except Exception:
    pass
try:
    datas += collect_data_files("langchain_core")
except Exception:
    pass

# ---- Excluded (gereksiz şişirme) ---------------------------------------------
excludes = [
    "tkinter",
    "matplotlib",
    "PIL",
    "IPython",
    "jupyter",
    "notebook",
    "pytest",
    "ruff",
]

# ---- Analysis ----------------------------------------------------------------
a = Analysis(
    [str(APP_DIR / "__main__.py")],
    pathex=[str(API_DIR)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    runtime_hooks=[],
    excludes=excludes,
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure, a.zipped_data)

# --onedir modu: tek binary yerine bir klasör üretiyoruz. .app bundle içine
# Contents/Resources/backend/ altına gömülecek. Cold start --onefile'a göre
# ~10x daha hızlı (self-extract yok).
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="ykorch-api",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,           # backend stdout/stderr Swift sidecar'a aksın
    disable_windowed_traceback=False,
    target_arch="arm64",
    codesign_identity=None, # imzayı sign-notarize-dmg.sh adımı yapacak
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="ykorch-api",
)
