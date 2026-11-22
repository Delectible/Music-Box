"""Moves a build from Play internal testing to production (promote-production.yml).

Env: SA = service account JSON, BUILD = version code (empty = newest internal).
"""
import json
import os
import sys

from google.oauth2 import service_account
from googleapiclient.discovery import build

PKG = "com.dingo.roadie"

sa = os.environ.get("SA")
if not sa:
    sys.exit("No PLAY_SERVICE_ACCOUNT_JSON secret")
creds = service_account.Credentials.from_service_account_info(
    json.loads(sa), scopes=["https://www.googleapis.com/auth/androidpublisher"]
)
edits = build("androidpublisher", "v3", credentials=creds, cache_discovery=False).edits()
edit = edits.insert(packageName=PKG, body={}).execute()["id"]

internal = edits.tracks().get(packageName=PKG, editId=edit, track="internal").execute()
codes = [int(c) for r in internal.get("releases", []) for c in r.get("versionCodes", [])]
if not codes:
    sys.exit("Nothing on internal testing")
want = int(os.environ["BUILD"]) if os.environ.get("BUILD") else max(codes)
if want not in codes:
    sys.exit(f"Build {want} isn't on internal testing (there: {sorted(codes)})")
notes = next(
    (r.get("releaseNotes") for r in internal["releases"] if str(want) in r.get("versionCodes", [])), None
)

release = {"versionCodes": [str(want)], "status": "completed"}
if notes:
    release["releaseNotes"] = notes
edits.tracks().update(
    packageName=PKG, editId=edit, track="production", body={"track": "production", "releases": [release]}
).execute()
edits.commit(packageName=PKG, editId=edit).execute()
print(f"Build {want} is on production")
