"""Code Agent — Claude Code subprocess'i lokal repo'da çalıştırır.

v1.5 step-by-step akış:
  1) Jira task → plan üretme (read-only, branch yaratılmadan da çalışır)
  2) Branch oluşturma + git checkout
  3) Claude'a "kod yaz" (file edit'ler interactive değil; --print mod)
  4) git diff göster, kullanıcı onaylar
  5) commit + push, bizim mevcut /api/pr/draft ile PR açıklaması

Subprocess: `claude -p "prompt" --cwd <repo> --output-format json --system-prompt ...`
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
from pathlib import Path

from sqlmodel import Session

from app.core.action_log import log_action
from app.core.active_project import resolve_project_id
from app.core.db import engine
from app.core.logging import get_logger
from app.integrations.jira_client import get_jira
from app.models import Project

log = get_logger(__name__)


def _claude_bin() -> str:
    """PATH'ten `claude` binary'sini bul. PyInstaller bundle'da PATH sınırlı olabilir;
    fallback olarak /opt/homebrew/bin/claude denenir."""
    return shutil.which("claude") or "/opt/homebrew/bin/claude"


async def _run_claude(
    prompt: str,
    *,
    cwd: str,
    system_prompt: str = "",
    model: str = "claude-opus-4-7",
    timeout: int = 600,
) -> dict:
    """Tek bir claude komutu çalıştır — JSON çıktıyı parse edip döner."""
    args = [_claude_bin(), "-p", "--model", model, "--output-format", "json"]
    if system_prompt:
        args.extend(["--system-prompt", system_prompt])

    proc = await asyncio.create_subprocess_exec(
        *args,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=cwd or None,
    )
    stdout_b, stderr_b = await asyncio.wait_for(
        proc.communicate(input=prompt.encode("utf-8")),
        timeout=timeout,
    )
    if proc.returncode != 0:
        err = stderr_b.decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"claude exit {proc.returncode}: {err}")

    try:
        return json.loads(stdout_b.decode("utf-8"))
    except json.JSONDecodeError:
        return {"is_error": True, "result": stdout_b.decode("utf-8", errors="replace")[:1000]}


async def _git(cwd: str, *args: str) -> tuple[int, str, str]:
    """Lokal git komutu çalıştır."""
    proc = await asyncio.create_subprocess_exec(
        "git", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=cwd,
    )
    out_b, err_b = await proc.communicate()
    return proc.returncode, out_b.decode(errors="replace"), err_b.decode(errors="replace")


# ─────────────────────────────────────────────────────────────────────────
# Step 1: Plan
# ─────────────────────────────────────────────────────────────────────────

async def make_plan(*, jira_key: str, project_id: int | None) -> dict:
    """Jira task'tan plan üret — kod yazmadan önce kullanıcının onaylaması için.

    1. Jira'dan task bilgilerini çek (summary + description + status)
    2. Lokal repo path'ini config'ten al
    3. Claude'a system prompt: 'Sen senior iOS developer, Yapı Kredi banka kodu üstünde
       çalışıyorsun. Önce planı çıkar, kod yazma' — read-only mod
    4. JSON cevap: { plan: "...", concerns: [...], estimated_files: [...] }
    """
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        proj = session.get(Project, pid)
        if not proj or not proj.local_repo_path:
            raise RuntimeError("Aktif projenin local_repo_path'i ayarlı değil (Ayarlar)")
        repo_path = proj.local_repo_path

    if not Path(repo_path).is_dir():
        raise RuntimeError(f"Lokal repo bulunamadı: {repo_path}")

    # Jira detay
    try:
        issue = await get_jira().get_issue(jira_key)
    except Exception as e:
        raise RuntimeError(f"Jira'ya erişilemiyor (VPN?): {e}")
    fields = issue.get("fields") or {}
    summary = fields.get("summary") or ""
    description = (fields.get("description") or "")[:5000]
    status = (fields.get("status") or {}).get("name") or "?"
    issue_type = (fields.get("issuetype") or {}).get("name") or "?"

    system = (
        "Sen Yapı Kredi iOS ekibinde senior iOS developer'sın. Banka kodu üstünde "
        "çalışıyorsun — değişikliklerin güvenli, geri-alınabilir ve test edilebilir "
        "olmalı. Şu an SADECE PLAN ÇIKAR, kod yazma. "
        "Cevabını ŞU FORMATTA Türkçe ver:\n\n"
        "## Plan\n(yapılacakların maddeli listesi)\n\n"
        "## Etkilenecek dosyalar\n(- file/path/X.swift — neden)\n\n"
        "## Riskler / sorular\n(varsa)\n"
    )

    prompt = (
        f"Jira task: **{jira_key}** — {summary}\n"
        f"Tip: {issue_type}, Durum: {status}\n\n"
        f"Açıklama:\n{description or '(yok)'}\n\n"
        "Bu task için lokal repo'yu inceleyip yapılacak değişikliklerin planını çıkar."
    )

    payload = await _run_claude(prompt, cwd=repo_path, system_prompt=system)
    if payload.get("is_error"):
        raise RuntimeError(f"Claude hatası: {payload.get('result', '?')[:300]}")

    plan_text = payload.get("result", "")
    log_action(
        action_type="agent.plan",
        actor="ai",
        target_kind="jira_issue",
        target_id=jira_key,
        payload={
            "summary": summary[:120],
            "preview": plan_text[:200],
            "cost_usd": payload.get("total_cost_usd"),
        },
        project_id=project_id,
    )
    return {
        "ok": True,
        "plan": plan_text,
        "cost_usd": payload.get("total_cost_usd"),
        "duration_ms": payload.get("duration_ms"),
        "repo": repo_path,
        "jira_summary": summary,
    }


# ─────────────────────────────────────────────────────────────────────────
# Step 2: Branch + git checkout
# ─────────────────────────────────────────────────────────────────────────

async def prepare_branch(
    *, jira_key: str, branch_name: str, source_branch: str = "develop",
    project_id: int | None,
) -> dict:
    """Bitbucket'ta branch yaratıp lokal git'te onu çekip checkout eder."""
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        proj = session.get(Project, pid)
        if not proj or not proj.local_repo_path:
            raise RuntimeError("Lokal repo yolu ayarlı değil")
        repo_path = proj.local_repo_path

    # git'in çalıştığı dizini doğrula
    rc, _, err = await _git(repo_path, "status", "--porcelain")
    if rc != 0:
        raise RuntimeError(f"git status başarısız: {err}")

    # fetch
    await _git(repo_path, "fetch", "origin", "--prune")
    # source branch'i checkout
    rc, _, err = await _git(repo_path, "checkout", source_branch)
    if rc != 0:
        raise RuntimeError(f"source branch checkout başarısız: {err}")
    rc, _, err = await _git(repo_path, "pull", "origin", source_branch)
    if rc != 0:
        log.warning(f"pull uyarı: {err}")

    # Yeni branch
    rc, _, err = await _git(repo_path, "checkout", "-b", branch_name)
    if rc != 0:
        # zaten varsa direkt checkout dene
        rc2, _, err2 = await _git(repo_path, "checkout", branch_name)
        if rc2 != 0:
            raise RuntimeError(f"branch oluşturma+checkout başarısız: {err or err2}")

    log_action(
        action_type="agent.branch_ready",
        target_kind="branch",
        target_id=branch_name,
        payload={"jira_key": jira_key, "repo_path": repo_path, "source_branch": source_branch},
        project_id=project_id,
    )
    return {"ok": True, "branch": branch_name, "repo_path": repo_path}


# ─────────────────────────────────────────────────────────────────────────
# Step 3: Code generation (Claude lokal repo'da değişiklik yapar)
# ─────────────────────────────────────────────────────────────────────────

async def generate_code(*, jira_key: str, plan: str, project_id: int | None) -> dict:
    """Claude'a 'planı uygula, kodu yaz' der.

    Kullanıcı plan'ı önceden onayladığı için bu adım kod üretir; git diff
    `get_diff()` ile ayrıca okunur."""
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        proj = session.get(Project, pid)
        if not proj or not proj.local_repo_path:
            raise RuntimeError("Lokal repo yolu yok")
        repo_path = proj.local_repo_path

    try:
        issue = await get_jira().get_issue(jira_key)
    except Exception as e:
        raise RuntimeError(f"Jira: {e}")
    summary = (issue.get("fields") or {}).get("summary") or ""

    system = (
        "Sen Yapı Kredi iOS ekibinde senior iOS developer'sın. Banka kodu üstünde "
        "çalışıyorsun. Az önce onaylanmış bir plana göre değişiklikleri yapacaksın. "
        "Dosyaları düzenle (Edit/Write tool'larıyla), build edilebilir bırak. "
        "Test/lint çalıştırmadan önce kullanıcıya bildir. Türkçe rapor ver."
    )

    prompt = (
        f"Jira task: **{jira_key}** — {summary}\n\n"
        f"Onaylanmış plan:\n{plan}\n\n"
        "Bu planı uygulayarak repo'da gerekli dosya değişikliklerini yap. "
        "İşin sonunda kısa bir Türkçe değişiklik özeti ver."
    )

    payload = await _run_claude(
        prompt, cwd=repo_path, system_prompt=system, timeout=1800
    )
    if payload.get("is_error"):
        raise RuntimeError(f"Claude hatası: {payload.get('result', '?')[:300]}")

    text = payload.get("result", "")
    log_action(
        action_type="agent.code_gen",
        actor="ai",
        target_kind="jira_issue",
        target_id=jira_key,
        payload={"preview": text[:200], "cost_usd": payload.get("total_cost_usd")},
        project_id=project_id,
    )
    return {"ok": True, "report": text, "cost_usd": payload.get("total_cost_usd")}


# ─────────────────────────────────────────────────────────────────────────
# Diff + commit
# ─────────────────────────────────────────────────────────────────────────

async def get_diff(project_id: int | None) -> dict:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        proj = session.get(Project, pid)
        if not proj or not proj.local_repo_path:
            raise RuntimeError("Lokal repo yolu yok")
        repo_path = proj.local_repo_path

    rc, status_out, _ = await _git(repo_path, "status", "--porcelain")
    rc2, diff_out, _ = await _git(repo_path, "diff", "HEAD")

    return {
        "ok": True,
        "status": status_out,
        "diff": diff_out[:50000],   # frontend için kısalt
        "diff_truncated": len(diff_out) > 50000,
    }


async def commit_changes(
    *, message: str, push: bool = True, project_id: int | None
) -> dict:
    pid = resolve_project_id(project_id)
    with Session(engine) as session:
        proj = session.get(Project, pid)
        if not proj or not proj.local_repo_path:
            raise RuntimeError("Lokal repo yolu yok")
        repo_path = proj.local_repo_path

    rc, _, err = await _git(repo_path, "add", "-A")
    if rc != 0:
        raise RuntimeError(f"git add: {err}")
    rc, out, err = await _git(repo_path, "commit", "-m", message)
    if rc != 0:
        raise RuntimeError(f"git commit: {err or out}")

    pushed = False
    if push:
        # Mevcut branch
        _, branch_out, _ = await _git(repo_path, "rev-parse", "--abbrev-ref", "HEAD")
        branch = branch_out.strip()
        rc, _, err = await _git(repo_path, "push", "-u", "origin", branch)
        if rc != 0:
            log.warning(f"push: {err}")
        else:
            pushed = True

    log_action(
        action_type="agent.commit",
        target_kind="branch",
        target_id="HEAD",
        payload={"message": message[:200], "pushed": pushed},
        project_id=project_id,
    )
    return {"ok": True, "pushed": pushed}
