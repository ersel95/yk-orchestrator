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


@router.post("/test-jira", response_model=TestResult)
async def test_jira(body: TestJiraRequest) -> TestResult:
    base = body.base_url.rstrip("/")
    if not base:
        return TestResult(ok=False, message="Base URL boş olamaz")
    if not body.token:
        return TestResult(ok=False, message="Token boş olamaz")

    headers: dict[str, str] = {"Accept": "application/json"}
    auth: tuple[str, str] | None = None
    if body.email:
        # Cloud / Basic auth (email + api token)
        auth = (body.email, body.token)
        auth_kind = "basic"
    else:
        # Server/DC PAT
        headers["Authorization"] = f"Bearer {body.token}"
        auth_kind = "bearer"

    url = f"{base}/rest/api/2/myself"
    try:
        async with httpx.AsyncClient(timeout=DEFAULT_TIMEOUT, follow_redirects=True) as c:
            r = await c.get(url, headers=headers, auth=auth)
        if r.status_code == 200:
            data = r.json()
            display = data.get("displayName") or data.get("name") or data.get("emailAddress") or "?"
            return TestResult(
                ok=True,
                message=f"Bağlantı OK · {display} olarak doğrulandı ({auth_kind})",
                details={"account_id": data.get("accountId") or data.get("key")},
            )
        if r.status_code in (401, 403):
            return TestResult(ok=False, message=f"Auth reddedildi (HTTP {r.status_code}). Token doğru mu, e-posta gerekli mi?")
        return TestResult(ok=False, message=f"Beklenmedik cevap HTTP {r.status_code}: {r.text[:160]}")
    except httpx.ConnectError as e:
        return TestResult(ok=False, message=f"Bağlanılamadı: {e}. VPN bağlı mı, URL doğru mu?")
    except httpx.TimeoutException:
        return TestResult(ok=False, message="İstek zaman aşımına uğradı (8 sn). VPN/ağ yavaş olabilir.")
    except Exception as e:
        log.warning(f"test-jira hata: {e}")
        return TestResult(ok=False, message=f"Beklenmedik hata: {e}")


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
