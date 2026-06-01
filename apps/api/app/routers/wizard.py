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
