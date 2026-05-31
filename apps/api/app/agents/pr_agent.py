"""PR agent'ları — author (PR aç) + reviewer (özet üret). Proje bazlı."""
from __future__ import annotations

import json
import re
from collections.abc import AsyncIterator
from datetime import datetime

import httpx
from sqlmodel import Session, select

from app.agents.prompts import (
    PR_DESCRIPTION_SYSTEM,
    PR_DESCRIPTION_USER,
    PR_INLINE_REVIEW_SYSTEM,
    PR_INLINE_REVIEW_USER,
    PR_REVIEW_SUMMARY_SYSTEM,
    PR_REVIEW_SUMMARY_USER,
)
from app.core.active_project import get_project, resolve_project_id
from app.core.db import engine
from app.core.logging import get_logger
from app.integrations.bitbucket_client import get_bitbucket
from app.integrations.git_local import get_git
from app.integrations.llm import get_llm
from app.integrations.rag import get_rag
from app.models import PullRequestCache

log = get_logger(__name__)


class PRAuthorAgent:
    async def draft(
        self,
        source_branch: str,
        project_id: int | None = None,
        target_branch: str | None = None,
        repo: str | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        target_branch = target_branch or proj.git_default_branch or "develop"
        repo = repo or proj.bitbucket_repo

        git = get_git(proj.local_repo_path or None)
        diff = git.diff_full(target_branch, source_branch, max_chars=20000)
        diff_stat = git.diff_between(target_branch, source_branch)

        commits = []
        try:
            for c in git.repo.iter_commits(f"{target_branch}..{source_branch}"):
                commits.append(f"- {c.hexsha[:8]} {c.message.strip().splitlines()[0]}")
        except Exception as e:
            log.warning(f"Commit listesi alınamadı: {e}")

        prompt = PR_DESCRIPTION_USER.format(
            branch=source_branch,
            target=target_branch,
            commits="\n".join(commits) or "(commit yok)",
            diff_stat=diff_stat or "(stat yok)",
            diff=diff or "(diff yok)",
        )
        llm = get_llm()
        description = await llm.complete(
            prompt, system=PR_DESCRIPTION_SYSTEM, kind="code", max_tokens=1500
        )

        title = commits[0].split(" ", 2)[-1] if commits else source_branch.replace("-", " ").title()

        return {
            "project_id": pid,
            "source_branch": source_branch,
            "target_branch": target_branch,
            "repo": repo,
            "title_suggestion": title,
            "description": description,
            "diff_stat": diff_stat,
            "commit_count": len(commits),
        }

    async def open_pr(
        self,
        title: str,
        description: str,
        source_branch: str,
        target_branch: str,
        project_id: int | None = None,
        repo: str | None = None,
        reviewers: list[str] | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        repo = repo or proj.bitbucket_repo

        bb = get_bitbucket()
        if not await bb.health():
            return {"ok": False, "error": "Bitbucket erişilemedi"}
        try:
            res = await bb.create_pr(
                title=title,
                description=description,
                source_branch=source_branch,
                target_branch=target_branch,
                workspace=proj.bitbucket_workspace,
                repo=repo,
                reviewers=reviewers,
            )
            return {"ok": True, "pr": res}
        except Exception as e:
            return {"ok": False, "error": str(e)}


class PRReviewerAgent:
    async def list_for_review(self, project_id: int | None = None) -> list[dict]:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        if not await bb.health() or not proj.bitbucket_repo or not proj.bitbucket_workspace:
            return []
        prs = await bb.list_prs(
            workspace=proj.bitbucket_workspace, repo=proj.bitbucket_repo, state="OPEN"
        )
        return [bb.normalize(p, bb.username) for p in prs]

    async def summarize(
        self, pr_id: int, project_id: int | None = None, repo: str | None = None
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        repo = repo or proj.bitbucket_repo
        bb = get_bitbucket()
        pr = await bb.get_pr(pr_id, workspace=proj.bitbucket_workspace, repo=repo)
        diff = await bb.get_diff(
            pr_id, workspace=proj.bitbucket_workspace, repo=repo, context_lines=2
        )
        diff = _smart_truncate_diff(diff, max_chars=10000)

        title = pr.get("title") or ""
        author = ((pr.get("author") or {}).get("user") or {}).get("displayName") or ""
        target = (pr.get("toRef") or {}).get("displayId") or ""

        plus = sum(1 for ln in diff.splitlines() if ln.startswith("+") and not ln.startswith("+++"))
        minus = sum(1 for ln in diff.splitlines() if ln.startswith("-") and not ln.startswith("---"))
        diff_stat = f"+{plus} / -{minus} satır"

        prompt = PR_REVIEW_SUMMARY_USER.format(
            title=title,
            author=author,
            target=target,
            diff_stat=diff_stat,
            diff=diff,
        )
        llm = get_llm()
        summary = await llm.complete(
            prompt,
            system=PR_REVIEW_SUMMARY_SYSTEM,
            kind="code",
            max_tokens=8000,
            label="pr-summary",
        )

        normalized = bb.normalize(pr, bb.username)
        normalized["diff_summary"] = summary
        normalized["fetched_at"] = datetime.utcnow()

        with Session(engine) as session:
            existing = session.exec(
                select(PullRequestCache).where(
                    PullRequestCache.project_id == pid,
                    PullRequestCache.pr_id == normalized["pr_id"],
                )
            ).first()
            payload = {k: v for k, v in normalized.items() if k in PullRequestCache.model_fields}
            payload["project_id"] = pid
            if existing:
                for k, v in payload.items():
                    setattr(existing, k, v)
                session.add(existing)
            else:
                session.add(PullRequestCache(**payload))
            session.commit()

        rag = get_rag()
        await rag.upsert(
            "pull_request",
            ids=[f"{pid}:{normalized['pr_id']}"],
            documents=[f"[{proj.name}] {title}\n{summary}"],
            metadatas=[
                {
                    "project_id": pid,
                    "author": author,
                    "target": target,
                    "url": normalized["url"],
                }
            ],
        )

        return {"pr": normalized, "summary": summary}

    async def summarize_stream(
        self, pr_id: int, project_id: int | None = None, repo: str | None = None
    ) -> AsyncIterator[dict]:
        """AI özet'i stream olarak üretir — kullanıcı anlık görür.

        Yields:
          {"type": "meta", "data": {pr meta...}}
          {"type": "delta", "data": "..."}  (kelime kelime)
          {"type": "done", "data": {full summary saved}}
        """
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        repo = repo or proj.bitbucket_repo
        bb = get_bitbucket()

        pr = await bb.get_pr(pr_id, workspace=proj.bitbucket_workspace, repo=repo)
        diff = await bb.get_diff(
            pr_id, workspace=proj.bitbucket_workspace, repo=repo, context_lines=2
        )
        diff = _smart_truncate_diff(diff, max_chars=10000)

        title = pr.get("title") or ""
        author = ((pr.get("author") or {}).get("user") or {}).get("displayName") or ""
        target = (pr.get("toRef") or {}).get("displayId") or ""
        plus = sum(1 for ln in diff.splitlines() if ln.startswith("+") and not ln.startswith("+++"))
        minus = sum(1 for ln in diff.splitlines() if ln.startswith("-") and not ln.startswith("---"))
        diff_stat = f"+{plus} / -{minus} satır (truncated: {len(diff)} ch)"

        yield {
            "type": "meta",
            "data": {"title": title, "author": author, "target": target, "diff_stat": diff_stat},
        }

        prompt = PR_REVIEW_SUMMARY_USER.format(
            title=title, author=author, target=target, diff_stat=diff_stat, diff=diff
        )
        llm = get_llm()
        full = []
        async for chunk in llm.stream(
            prompt,
            system=PR_REVIEW_SUMMARY_SYSTEM,
            kind="code",
            max_tokens=8000,
            label="pr-summary-stream",
        ):
            full.append(chunk)
            yield {"type": "delta", "data": chunk}

        summary = "".join(full)
        normalized = bb.normalize(pr, bb.username)
        normalized["diff_summary"] = summary
        normalized["fetched_at"] = datetime.utcnow()

        with Session(engine) as session:
            existing = session.exec(
                select(PullRequestCache).where(
                    PullRequestCache.project_id == pid,
                    PullRequestCache.pr_id == normalized["pr_id"],
                )
            ).first()
            payload = {k: v for k, v in normalized.items() if k in PullRequestCache.model_fields}
            payload["project_id"] = pid
            if existing:
                for k, v in payload.items():
                    setattr(existing, k, v)
                session.add(existing)
            else:
                session.add(PullRequestCache(**payload))
            session.commit()

        rag = get_rag()
        await rag.upsert(
            "pull_request",
            ids=[f"{pid}:{normalized['pr_id']}"],
            documents=[f"[{proj.name}] {title}\n{summary}"],
            metadatas=[
                {
                    "project_id": pid,
                    "author": author,
                    "target": target,
                    "url": normalized["url"],
                }
            ],
        )

        yield {"type": "done", "data": {"summary": summary, "pr": normalized}}

    # ----- Aksiyonlar -----

    async def set_status(
        self,
        pr_id: int,
        status: str,  # APPROVED | NEEDS_WORK | UNAPPROVED
        project_id: int | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        try:
            res = await bb.set_participant_status(
                pr_id=pr_id,
                status=status,
                workspace=proj.bitbucket_workspace,
                repo=proj.bitbucket_repo,
            )
            return {"ok": True, "status": status, "result": res}
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 409:
                return {
                    "ok": False,
                    "stale": True,
                    "error": (
                        f"PR #{pr_id} artık güncellenemiyor — büyük ihtimalle "
                        "merge edilmiş veya kapatılmış. Liste tazeleniyor."
                    ),
                }
            return {"ok": False, "error": f"Bitbucket {e.response.status_code}: {e.response.text}"}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    async def add_comment(
        self,
        pr_id: int,
        text: str,
        project_id: int | None = None,
        anchor: dict | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        try:
            res = await bb.add_pr_comment(
                pr_id=pr_id,
                text=text,
                workspace=proj.bitbucket_workspace,
                repo=proj.bitbucket_repo,
                anchor=anchor,
            )
            return {"ok": True, "comment": res}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    async def list_file_comments(
        self, pr_id: int, path_in_repo: str, project_id: int | None = None
    ) -> list[dict]:
        """Belirli dosyadaki yorumları çek + frontend'e uygun normalize et."""
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        raw = await bb.list_pr_comments(
            pr_id=pr_id,
            workspace=proj.bitbucket_workspace,
            repo=proj.bitbucket_repo,
            path_in_repo=path_in_repo,
        )
        my = (bb.username or "").lower()
        out: list[dict] = []

        def _flatten(item: dict) -> None:
            anchor = item.get("anchor") or {}
            author = (item.get("author") or {})
            author_name = author.get("name") or ""
            out.append(
                {
                    "id": item.get("id"),
                    "version": item.get("version", 0),
                    "text": item.get("text", ""),
                    "author_name": author_name,
                    "author_display": author.get("displayName") or author_name,
                    "created_at": item.get("createdDate"),
                    "updated_at": item.get("updatedDate"),
                    "is_mine": author_name.lower() == my,
                    "anchor": {
                        "line": anchor.get("line"),
                        "line_type": anchor.get("lineType"),
                        "file_type": anchor.get("fileType"),
                        "path": anchor.get("path"),
                    },
                    "parent_id": item.get("parentId") or item.get("parent", {}).get("id"),
                }
            )
            for reply in item.get("comments") or []:
                _flatten(reply)

        for top in raw:
            _flatten(top)
        return out

    async def update_comment(
        self,
        pr_id: int,
        comment_id: int,
        version: int,
        text: str,
        project_id: int | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        try:
            res = await bb.update_comment(
                pr_id=pr_id,
                comment_id=comment_id,
                version=version,
                text=text,
                workspace=proj.bitbucket_workspace,
                repo=proj.bitbucket_repo,
            )
            return {"ok": True, "comment": res}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    async def delete_comment(
        self,
        pr_id: int,
        comment_id: int,
        version: int,
        project_id: int | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        try:
            await bb.delete_comment(
                pr_id=pr_id,
                comment_id=comment_id,
                version=version,
                workspace=proj.bitbucket_workspace,
                repo=proj.bitbucket_repo,
            )
            return {"ok": True}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    async def get_changes(
        self, pr_id: int, project_id: int | None = None
    ) -> list[dict]:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        changes = await bb.get_pr_changes(
            pr_id=pr_id,
            workspace=proj.bitbucket_workspace,
            repo=proj.bitbucket_repo,
        )
        # Stash değişiklik formatı: path.toString, type (ADD/MODIFY/DELETE/RENAME), srcPath
        out = []
        for c in changes:
            path_obj = c.get("path") or {}
            src_path_obj = c.get("srcPath") or {}
            out.append(
                {
                    "path": path_obj.get("toString") or "",
                    "src_path": src_path_obj.get("toString"),
                    "type": c.get("type"),
                    "executable": c.get("executable", False),
                }
            )
        return out

    async def get_file_diff(
        self,
        pr_id: int,
        path_in_repo: str,
        project_id: int | None = None,
        context_lines: int = 10,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        return await bb.get_pr_file_diff(
            pr_id=pr_id,
            path_in_repo=path_in_repo,
            workspace=proj.bitbucket_workspace,
            repo=proj.bitbucket_repo,
            context_lines=context_lines,
        )

    async def suggest_inline_comments(
        self, pr_id: int, project_id: int | None = None
    ) -> dict:
        """AI'dan dosya/satır bazlı yorum önerileri al — kullanıcı onaylayıp Bitbucket'a gönderir."""
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()

        pr = await bb.get_pr(pr_id, workspace=proj.bitbucket_workspace, repo=proj.bitbucket_repo)
        title = pr.get("title") or ""

        changes = await self.get_changes(pr_id, project_id=pid)
        file_summary = "\n".join(f"- {c['type']:7} {c['path']}" for c in changes[:30])

        # Tüm diff (tek seferde) — agresif kes
        full_diff = await bb.get_diff(
            pr_id, workspace=proj.bitbucket_workspace, repo=proj.bitbucket_repo, context_lines=2
        )
        full_diff = _smart_truncate_diff(full_diff, max_chars=12000)

        prompt = PR_INLINE_REVIEW_USER.format(
            title=title, file_summary=file_summary or "(yok)", diff=full_diff or "(yok)"
        )
        llm = get_llm()
        ai_raw = await llm.complete(
            prompt,
            system=PR_INLINE_REVIEW_SYSTEM,
            kind="code",
            max_tokens=5000,
            temperature=0.2,
            label="pr-inline-review",
        )

        suggestions = _extract_suggestions(ai_raw)
        return {
            "ok": True,
            "title": title,
            "files_changed": len(changes),
            "suggestions": suggestions,
            "raw": ai_raw if not suggestions else None,
        }

    async def post_inline_suggestions(
        self,
        pr_id: int,
        suggestions: list[dict],
        project_id: int | None = None,
    ) -> dict:
        """Seçilmiş AI yorumlarını Bitbucket'a inline yorum olarak gönderir."""
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        bb = get_bitbucket()
        results = []
        for s in suggestions:
            text = s.get("comment") or ""
            if s.get("title"):
                text = f"**{s['title']}**\n\n{text}"
            if s.get("suggestion"):
                text += f"\n\n```swift\n{s['suggestion']}\n```"
            severity = (s.get("severity") or "info").lower()
            badge = {"info": "ℹ️", "warning": "⚠️", "critical": "🚨"}.get(severity, "")
            if badge:
                text = f"{badge} {text}"

            anchor = {
                "line": int(s["line"]),
                "lineType": s.get("line_type") or "ADDED",
                "fileType": "TO",
                "path": s["path"],
                "diffType": "EFFECTIVE",
            }
            try:
                res = await bb.add_pr_comment(
                    pr_id=pr_id,
                    text=text,
                    workspace=proj.bitbucket_workspace,
                    repo=proj.bitbucket_repo,
                    anchor=anchor,
                )
                results.append({"ok": True, "id": res.get("id"), "path": s["path"]})
            except Exception as e:
                results.append({"ok": False, "error": str(e), "path": s.get("path")})
        return {"results": results, "posted": sum(1 for r in results if r["ok"])}


def _smart_truncate_diff(diff: str, max_chars: int) -> str:
    """Diff'i akıllı kes: dosya başlarını koru, ortadan kes.

    Bitbucket diff'i `diff --git ...` ile yeni dosya başlatır. Her dosyanın ilk
    20-25 satırını koru, sonrasını "...truncated..." ile geç. Çok uzun değişikliklerde
    bağlam kaybetmeden hangi dosyada ne olduğu anlaşılır.
    """
    if len(diff) <= max_chars:
        return diff
    # Dosya başlarını yakalayıp her dosyaya pay ver
    parts = diff.split("\ndiff --git ")
    if len(parts) == 1:
        return diff[:max_chars] + "\n...[truncated]"
    head = parts[0]
    files = ["diff --git " + p for p in parts[1:]]
    per_file = max(800, max_chars // max(len(files), 1))
    chunks = [head[:600]]
    used = len(chunks[0])
    for f in files:
        if used >= max_chars:
            chunks.append(f"...[{len(files) - len(chunks) + 1} more files truncated]")
            break
        keep = f[:per_file]
        if len(f) > per_file:
            keep += "\n...[truncated]"
        chunks.append(keep)
        used += len(keep)
    return "\n".join(chunks)


def _extract_suggestions(text: str) -> list[dict]:
    """LLM çıktısından JSON parse — komşu metinlerden temizler."""
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?", "", text).strip()
        text = re.sub(r"```$", "", text).strip()
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if not m:
            return []
        try:
            obj = json.loads(m.group(0))
        except json.JSONDecodeError:
            return []
    return obj.get("comments", []) if isinstance(obj, dict) else []
