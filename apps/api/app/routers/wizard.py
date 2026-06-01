"""Setup wizard yardımcı endpoint'leri — kullanıcı henüz config kaydetmemişken
girilen Jira/Bitbucket credential'larını canlı API ile doğrular.

Buradaki endpoint'ler `app.core.config.get_settings()`'i KULLANMAZ; çünkü
wizard sırasında henüz config.json yazılmamış olabilir veya kullanıcı önceki
değerleri değiştirmiş olabilir. Test parametrelerini direkt body'den alıp
geçici httpx client ile API çağrısı yaparlar.
"""
from __future__ import annotations

import httpx
from fastapi import APIRouter
from pydantic import BaseModel

from app.core.logging import get_logger

log = get_logger(__name__)

router = APIRouter(prefix="/api/wizard", tags=["wizard"])

DEFAULT_TIMEOUT = 8.0  # auth check kısa olmalı


# ─────────────────────────────────────────────────────────────────────────
# Jira
# ─────────────────────────────────────────────────────────────────────────

class TestJiraRequest(BaseModel):
    base_url: str
    email: str = ""        # boşsa → Bearer (Server/DC PAT); doluysa → Basic
    token: str
    project_keys: str = ""  # virgüllü liste; bilgi amaçlı (test'te kullanılmıyor)


class TestResult(BaseModel):
    ok: bool
    message: str
    details: dict | None = None


async def _try_jira(url: str, *, bearer: str | None, basic: tuple[str, str] | None,
                    label: str) -> tuple[int, str, dict]:
    """Tek bir auth yöntemiyle Jira myself çağrısı. (status, body_short, json_or_empty) döner."""
    headers = {"Accept": "application/json"}
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as c:
        r = await c.get(url, headers=headers, auth=basic)
    if r.status_code == 200:
        try:
            return r.status_code, "", r.json()
        except Exception:
            return r.status_code, r.text[:160], {}
    return r.status_code, r.text[:160], {}


@router.post("/test-jira", response_model=TestResult)
async def test_jira(body: TestJiraRequest) -> TestResult:
    base = body.base_url.rstrip("/")
    if not base:
        return TestResult(ok=False, message="Base URL boş olamaz")
    if not body.token:
        return TestResult(ok=False, message="Token boş olamaz")

    url = f"{base}/rest/api/2/myself"

    # Yapı Kredi gibi Jira Server/DC kurulumları Bearer (PAT) kabul ederken
    # Basic auth'u reddeder; Atlassian Cloud ise email+token Basic ister.
    # Hangi kurulum olduğunu bilemeyiz → iki yolu da paralel dene, hangisi
    # 200 dönerse o auth kindi ile başarı raporla.
    tried: list[str] = []

    # 1) Önce Bearer (Server/DC PAT — Yapı Kredi gibi yapılarda standart)
    try:
        status, body_txt, data = await _try_jira(url, bearer=body.token, basic=None, label="bearer")
        tried.append(f"bearer→{status}")
        if status == 200:
            display = data.get("displayName") or data.get("name") or data.get("emailAddress") or "?"
            return TestResult(
                ok=True,
                message=f"Bağlantı OK · {display} olarak doğrulandı (bearer)",
                details={"account_id": data.get("accountId") or data.get("key")},
            )
    except (httpx.ConnectError, httpx.TimeoutException) as e:
        # Network seviyesi hata — alternatif auth denemeye gerek yok
        return _jira_network_error(e)

    # 2) Email verilmişse Basic (Cloud akışı)
    if body.email:
        try:
            status, body_txt, data = await _try_jira(
                url, bearer=None, basic=(body.email, body.token), label="basic"
            )
            tried.append(f"basic→{status}")
            if status == 200:
                display = data.get("displayName") or data.get("name") or data.get("emailAddress") or "?"
                return TestResult(
                    ok=True,
                    message=f"Bağlantı OK · {display} olarak doğrulandı (basic)",
                    details={"account_id": data.get("accountId") or data.get("key")},
                )
        except (httpx.ConnectError, httpx.TimeoutException) as e:
            return _jira_network_error(e)

    # İki yöntem de tutmadıysa son status'a göre mesaj
    if any(t.endswith("→401") or t.endswith("→403") for t in tried):
        hint = (
            "Token doğru mu? Server/DC PAT için e-postayı BOŞ bırak. "
            "Atlassian Cloud için e-posta + API token gerekir."
        )
        return TestResult(ok=False, message=f"Auth reddedildi ({', '.join(tried)}). {hint}")
    return TestResult(ok=False, message=f"Beklenmedik cevap: {', '.join(tried)}")


def _jira_network_error(e: Exception) -> TestResult:
    if isinstance(e, httpx.TimeoutException):
        return TestResult(ok=False, message="İstek zaman aşımına uğradı (8 sn). VPN/ağ yavaş olabilir.")
    return TestResult(ok=False, message=f"Bağlanılamadı: {e}. VPN bağlı mı, URL doğru mu?")


# ─────────────────────────────────────────────────────────────────────────
# Auto-discovery — Jira projects + Bitbucket repos
# ─────────────────────────────────────────────────────────────────────────

class ListJiraProjectsResponse(BaseModel):
    ok: bool
    message: str = ""
    projects: list[dict] = []   # [{key, name}]


@router.post("/list-jira-projects", response_model=ListJiraProjectsResponse)
async def list_jira_projects(body: TestJiraRequest) -> ListJiraProjectsResponse:
    """Kullanıcının Jira'da erişebildiği tüm projeleri (key + name) döner.

    Wizard ProjectsStep'te kullanıcıya dropdown olarak sunulur. Bearer-first +
    Basic fallback aynı test-jira mantığıyla çalışır.
    """
    base = body.base_url.rstrip("/")
    url = f"{base}/rest/api/2/project"

    async def attempt(bearer: str | None, basic: tuple[str, str] | None) -> tuple[int, list]:
        headers = {"Accept": "application/json"}
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as c:
            r = await c.get(url, headers=headers, auth=basic)
        if r.status_code == 200:
            data = r.json()
            return 200, data if isinstance(data, list) else []
        return r.status_code, []

    try:
        status, projects = await attempt(bearer=body.token, basic=None)
        if status != 200 and body.email:
            status, projects = await attempt(bearer=None, basic=(body.email, body.token))
        if status != 200:
            return ListJiraProjectsResponse(ok=False, message=f"Auth/erişim hatası (HTTP {status})")

        items = [{"key": p.get("key"), "name": p.get("name")} for p in projects if p.get("key")]
        items.sort(key=lambda x: x["key"])
        return ListJiraProjectsResponse(ok=True, projects=items, message=f"{len(items)} proje")
    except (httpx.ConnectError, httpx.TimeoutException) as e:
        net = _jira_network_error(e)
        return ListJiraProjectsResponse(ok=False, message=net.message)
    except Exception as e:
        log.warning(f"list-jira-projects: {e}")
        return ListJiraProjectsResponse(ok=False, message=f"Beklenmedik hata: {e}")


class ListBitbucketReposRequest(BaseModel):
    base_url: str
    username: str
    token: str
    workspace: str   # project key (örn COSADC)


class ListBitbucketReposResponse(BaseModel):
    ok: bool
    message: str = ""
    repos: list[dict] = []   # [{slug, name, default_branch}]


@router.post("/list-bitbucket-repos", response_model=ListBitbucketReposResponse)
async def list_bitbucket_repos(body: ListBitbucketReposRequest) -> ListBitbucketReposResponse:
    """Bitbucket Server'da verilen project key altındaki tüm repo'ları listeler.

    Wizard ProjectsStep'te kullanıcı tek tıkla repo seçebilsin diye.
    """
    base = body.base_url.rstrip("/")
    if not body.workspace:
        return ListBitbucketReposResponse(ok=False, message="Project Key boş — önceki adımda doldur")

    url = f"{base}/rest/api/1.0/projects/{body.workspace}/repos?limit=1000"
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {body.token}",
    }

    try:
        async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as c:
            r = await c.get(url, headers=headers)
        if r.status_code != 200:
            return ListBitbucketReposResponse(
                ok=False,
                message=f"Erişim hatası (HTTP {r.status_code}) — Project Key ve token izinleri doğru mu?"
            )
        data = r.json()
        values = data.get("values", [])
        repos = []
        for v in values:
            repos.append({
                "slug": v.get("slug"),
                "name": v.get("name") or v.get("slug"),
                "default_branch": (v.get("defaultBranch") or {}).get("displayId", ""),
            })
        repos.sort(key=lambda x: x["slug"])
        return ListBitbucketReposResponse(
            ok=True, repos=repos, message=f"{len(repos)} repo"
        )
    except httpx.ConnectError as e:
        return ListBitbucketReposResponse(ok=False, message=f"Bağlanılamadı: {e}")
    except httpx.TimeoutException:
        return ListBitbucketReposResponse(ok=False, message="İstek zaman aşımına uğradı (8 sn).")
    except Exception as e:
        log.warning(f"list-bitbucket-repos: {e}")
        return ListBitbucketReposResponse(ok=False, message=f"Beklenmedik hata: {e}")


# ─────────────────────────────────────────────────────────────────────────
# Bitbucket Server
# ─────────────────────────────────────────────────────────────────────────

class TestBitbucketRequest(BaseModel):
    base_url: str
    username: str
    token: str
    workspace: str = ""
    repo: str = ""


@router.post("/test-bitbucket", response_model=TestResult)
async def test_bitbucket(body: TestBitbucketRequest) -> TestResult:
    base = body.base_url.rstrip("/")
    if not base:
        return TestResult(ok=False, message="Base URL boş olamaz")
    if not body.username:
        return TestResult(ok=False, message="Kullanıcı adı boş olamaz")
    if not body.token:
        return TestResult(ok=False, message="Token boş olamaz")

    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {body.token}",
    }

    # Bitbucket Server: GET /rest/api/1.0/users/{user-slug} → 200 + kullanıcı detayı
    url = f"{base}/rest/api/1.0/users/{body.username}"
    try:
        async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as c:
            r = await c.get(url, headers=headers)
        if r.status_code == 200:
            data = r.json()
            display = data.get("displayName") or data.get("name") or "?"
            extras: dict = {"username_id": data.get("id")}

            # workspace+repo verildiyse onu da doğrula (opsiyonel)
            if body.workspace and body.repo:
                async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as c:
                    r2 = await c.get(
                        f"{base}/rest/api/1.0/projects/{body.workspace}/repos/{body.repo}",
                        headers=headers,
                    )
                if r2.status_code == 200:
                    extras["repo_ok"] = True
                else:
                    return TestResult(
                        ok=False,
                        message=f"Kullanıcı OK ama {body.workspace}/{body.repo} repo'sına erişilemiyor (HTTP {r2.status_code}). Token'da REPO_READ izni var mı?",
                        details=extras,
                    )

            return TestResult(
                ok=True,
                message=f"Bağlantı OK · {display} olarak doğrulandı",
                details=extras,
            )
        if r.status_code in (401, 403):
            return TestResult(
                ok=False,
                message=f"Auth reddedildi (HTTP {r.status_code}). Token doğru mu, kullanıcı adı doğru mu?",
            )
        if r.status_code == 404:
            return TestResult(
                ok=False,
                message=f"Kullanıcı bulunamadı: '{body.username}'. Bitbucket username'i doğru mu?",
            )
        return TestResult(ok=False, message=f"Beklenmedik cevap HTTP {r.status_code}: {r.text[:160]}")
    except httpx.ConnectError as e:
        return TestResult(ok=False, message=f"Bağlanılamadı: {e}. VPN bağlı mı, URL doğru mu?")
    except httpx.TimeoutException:
        return TestResult(ok=False, message="İstek zaman aşımına uğradı (8 sn). VPN/ağ yavaş olabilir.")
    except Exception as e:
        log.warning(f"test-bitbucket hata: {e}")
        return TestResult(ok=False, message=f"Beklenmedik hata: {e}")
