"""YesterdayAgent — Dün ne yapıldığı: Jira done + merged PR + git commit.

Proje bazlı çalışır. Veriyi ZENGİNLEŞTİRİLMİŞ olarak döner:
  - Jira issue'larında description (kısaltılmış)
  - Merged PR'larda description + commit listesi
"""
from __future__ import annotations

import asyncio
from datetime import date, datetime, timedelta, timezone

from app.core.active_project import get_project, resolve_project_id
from app.core.config import get_settings
from app.core.logging import get_logger
from app.integrations.bitbucket_client import get_bitbucket
from app.integrations.git_local import get_git
from app.integrations.jira_client import get_jira

log = get_logger(__name__)


def _shorten(text: str | None, limit: int = 400) -> str:
    if not text:
        return ""
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0] + "…"


def previous_workday(today: date | None = None) -> date:
    """Önceki iş gününü dön. Pazartesi→Cuma, Pazar→Cuma, Cumartesi→Cuma, diğer→bir önceki gün."""
    today = today or date.today()
    wd = today.weekday()  # 0=Mon, 6=Sun
    if wd == 0:  # Pazartesi
        return today - timedelta(days=3)
    if wd == 6:  # Pazar
        return today - timedelta(days=2)
    if wd == 5:  # Cumartesi
        return today - timedelta(days=1)
    return today - timedelta(days=1)


def workday_range(today: date | None = None) -> tuple[date, date]:
    """Daily için bakılacak tarih aralığı.

    - Pazartesi: Cuma 00:00 → Pazartesi 00:00 (Cuma+Cumartesi+Pazar dahil, son ihtiyaç tut)
    - Salı-Cuma: önceki gün 00:00 → bugün 00:00
    """
    today = today or date.today()
    wd = today.weekday()
    if wd == 0:  # Mon
        start = today - timedelta(days=3)  # Cuma
    elif wd == 6:  # Sun (gün içi atılırsa)
        start = today - timedelta(days=2)
    elif wd == 5:  # Sat
        start = today - timedelta(days=1)
    else:
        start = today - timedelta(days=1)
    end = today  # exclusive üst sınır mantıksal; biz inclusive kullanıyoruz aşağıda
    return start, end


class YesterdayAgent:
    async def collect(
        self,
        project_id: int | None = None,
        target_date: date | None = None,
        today: date | None = None,
    ) -> dict:
        pid = resolve_project_id(project_id)
        proj = get_project(pid)
        today = today or date.today()
        # target_date verildiyse kullan, yoksa "önceki iş gününden bugüne" range
        if target_date is not None:
            start_date = target_date
            end_date = target_date
        else:
            start_date, end_date = workday_range(today)
            # workday_range bugünü exclusive bitiriyor; bizim filtrelemede end_date'i bir gün öncesi kabul edelim
            end_date = today - timedelta(days=1)
            if start_date > end_date:
                start_date = end_date  # güvenli fallback
        s = get_settings()

        log.info(
            f"[Yesterday] proje={proj.name} bugün={today.isoformat()} "
            f"aralık={start_date.isoformat()}..{end_date.isoformat()}"
        )

        result: dict = {
            "project_id": pid,
            "date_start": start_date.isoformat(),
            "date_end": end_date.isoformat(),
            "today": today.isoformat(),
            "jira_done": [],
            "merged_prs": [],
            "commits": [],
            "errors": [],
        }

        keys = [k.strip() for k in (proj.jira_project_keys or "").split(",") if k.strip()]
        project_filter = (" AND project IN (" + ",".join(keys) + ")") if keys else ""

        # Jira — done issue'lar (range)
        try:
            j = get_jira()
            if await j.health():
                jql = (
                    f'assignee = currentUser() AND statusCategory = Done '
                    f'AND updated >= "{start_date.isoformat()} 00:00" '
                    f'AND updated <= "{end_date.isoformat()} 23:59"'
                    f"{project_filter}"
                )
                done = await j.search_jql(jql)
                normalized = [j.normalize(i, s.jira_base_url) for i in done]
                for n in normalized:
                    n["description_short"] = _shorten(n.get("description"), 500)
                result["jira_done"] = normalized
            else:
                result["errors"].append("Jira: erişilemedi")
        except Exception as e:
            result["errors"].append(f"Jira: {e}")

        # Git lokal — range
        try:
            if proj.local_repo_path:
                g = get_git(proj.local_repo_path)
                all_commits: list[dict] = []
                cur = start_date
                while cur <= end_date:
                    all_commits.extend(g.my_commits_on(cur))
                    cur += timedelta(days=1)
                result["commits"] = all_commits
        except Exception as e:
            result["errors"].append(f"Git: {e}")

        # Bitbucket — range
        try:
            b = get_bitbucket()
            if await b.health() and proj.bitbucket_repo:
                prs = await b.list_prs(
                    workspace=proj.bitbucket_workspace,
                    repo=proj.bitbucket_repo,
                    state="MERGED",
                    role="AUTHOR",
                )
                cutoff_start = int(
                    datetime.combine(start_date, datetime.min.time(), tzinfo=timezone.utc).timestamp()
                    * 1000
                )
                cutoff_end = int(
                    datetime.combine(end_date, datetime.max.time(), tzinfo=timezone.utc).timestamp()
                    * 1000
                )
                candidates = [
                    p
                    for p in prs
                    if cutoff_start <= (p.get("updatedDate") or 0) <= cutoff_end
                ]
                # Detayları paralel çek
                async def _enrich(p: dict) -> dict:
                    n = b.normalize(p, b.username)
                    try:
                        commits = await b.get_pr_commits(
                            p["id"],
                            workspace=proj.bitbucket_workspace,
                            repo=proj.bitbucket_repo,
                            limit=15,
                        )
                        n["commit_messages"] = [
                            (c.get("message") or "").strip().splitlines()[0]
                            for c in commits
                            if c.get("message")
                        ]
                    except Exception:
                        n["commit_messages"] = []
                    n["description_short"] = _shorten(p.get("description"), 500)
                    return n

                if candidates:
                    enriched = await asyncio.gather(*[_enrich(p) for p in candidates])
                    result["merged_prs"] = list(enriched)
            elif not proj.bitbucket_repo:
                pass
            else:
                result["errors"].append("Bitbucket: erişilemedi")
        except Exception as e:
            result["errors"].append(f"Bitbucket: {e}")

        return result
