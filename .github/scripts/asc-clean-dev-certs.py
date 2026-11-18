"""
Revokes the Apple Development certificates that earlier CI runs created through the App Store
Connect API key ("Created via API"). Each run signs the archive on a fresh runner, so Xcode makes a
new development certificate every time, and the account's limit is soon reached ("Choose a
certificate to revoke"). Their private keys died with those runners, so nothing else uses them.
The Apple team is shared with Bottlepost, whose CI does the same; that is fine as long as two
archives do not run at the same moment. Distribution signing is cloud-managed and untouched.
Env: KEY_ID, ISSUER, KEY_PATH (see asc_api.py).
"""
from asc_api import call, token

print("signing App Store Connect token", flush=True)
auth = token()
print("listing development certificates", flush=True)
certs = call("GET", "/certificates", auth,
             {"filter[certificateType]": "DEVELOPMENT,IOS_DEVELOPMENT", "limit": "200"})["data"]
revoked = 0
for cert in certs:
    name = cert["attributes"].get("name", "") + " " + (cert["attributes"].get("displayName") or "")
    if "Created via API" in name:
        print(f"revoking {cert['id']}", flush=True)
        call("DELETE", f"/certificates/{cert['id']}", auth)
        revoked += 1
print(f"development certificates: {len(certs)}, revoked {revoked} made by earlier CI runs")
