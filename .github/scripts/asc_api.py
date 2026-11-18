"""
Minimal App Store Connect API client shared by asc-clean-dev-certs.py and asc-status.py.
The ES256 token is signed with the openssl CLI (on every GitHub runner), so no pip install.
Env: KEY_ID, ISSUER, and the .p8 key as a file (KEY_PATH) or its contents (KEY).
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def _b64(data: bytes) -> bytes:
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def _raw_signature(der: bytes) -> bytes:
    """ES256 JWTs need r||s; openssl prints an ASN.1 DER sequence of two integers."""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        assert der[i] == 2
        length = der[i + 1]
        parts.append(der[i + 2 : i + 2 + length].lstrip(b"\0").rjust(32, b"\0"))
        i += 2 + length
    return b"".join(parts)


def token() -> str:
    """JWT valid for 10 minutes (Apple allows at most 20)."""
    now = int(time.time())
    header = {"alg": "ES256", "kid": os.environ["KEY_ID"], "typ": "JWT"}
    payload = {"iss": os.environ["ISSUER"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = _b64(json.dumps(header).encode()) + b"." + _b64(json.dumps(payload).encode())
    key_path = os.environ.get("KEY_PATH")
    tmp = None
    if not key_path:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False)
        tmp.write(os.environ["KEY"].strip() + "\n")
        tmp.close()
        key_path = tmp.name
    try:
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                             input=signing_input, capture_output=True, check=True, timeout=30).stdout
    finally:
        if tmp:
            os.unlink(tmp.name)
    return (signing_input + b"." + _b64(_raw_signature(der))).decode()


class ApiError(Exception):
    def __init__(self, method: str, path: str, status: int, detail: str):
        super().__init__(f"{method} {path} -> HTTP {status}: {detail or 'no error body'}")
        self.status = status


def call(method: str, path: str, auth: str, params: dict | None = None):
    """path is relative to /v1 (e.g. "/apps"). Returns the JSON body, or None if empty."""
    url = API + path + ("?" + urllib.parse.urlencode(params, safe="[],-") if params else "")
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {auth}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as res:
            body = res.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        try:
            detail = "; ".join(f"{x.get('title', '')} - {x.get('detail', '')}".strip(" -")
                               for x in json.loads(e.read()).get("errors", []))
        except Exception:
            detail = ""
        raise ApiError(method, path, e.code, detail) from None
