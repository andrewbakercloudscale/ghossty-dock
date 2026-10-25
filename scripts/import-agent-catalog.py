#!/usr/bin/env python3
"""Builds Resources/agent-catalog from Plexiform's agent catalogue.

Plexiform (github.com/CallumJB125/claude-traffic-light) pins four MIT agent
collections, checks every file's SHA-256, scans them for risky directives and
ships the result as catalog/agents/catalog.json.gz. This keeps what the Find
page needs (one entry per agent, duplicates dropped), compressed as raw
deflate so Foundation's NSData.decompressed(using: .zlib) reads it, and copies
the licences and notices beside it.

    scripts/import-agent-catalog.py [~/Desktop/github/claude-traffic-light] [ref]
"""
import gzip, json, os, shutil, subprocess, sys, zlib

repo = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/Desktop/github/claude-traffic-light")
ref = sys.argv[2] if len(sys.argv) > 2 else "origin/main"
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "agent-catalog")


def show(path):
    return subprocess.run(["git", "-C", repo, "show", f"{ref}:{path}"], check=True, capture_output=True).stdout


catalog = json.loads(gzip.decompress(show("catalog/agents/catalog.json.gz")))
plexiform = subprocess.run(["git", "-C", repo, "rev-parse", "--short", ref], check=True,
                           capture_output=True, text=True).stdout.strip()

agents = []
for a in catalog["agents"]:
    if not a.get("primary"):
        continue
    agents.append({
        "id": a["id"], "name": a["name"], "slug": a["slug"], "description": a["description"],
        "oneLiner": a.get("oneLiner") or a["description"], "category": a["category"],
        "source": a["source"], "emoji": a.get("upstreamEmoji"), "vibe": a.get("vibe"),
        "icon": a.get("icon"), "model": a.get("model"), "attribution": a["attribution"],
        "risk": [f["why"] for f in a["risk"]["flags"] if f["rule"] != "all-tools"],
        "allTools": a["tools"]["effective"] == "all",
        "raw": a["raw"], "bodyOffset": a["bodyOffset"],
    })

result = {
    "plexiform": plexiform,
    "sources": [{k: s[k] for k in ("id", "name", "url", "sha", "license", "copyright")} for s in catalog["sources"]],
    "categories": catalog["categories"],
    "agents": agents,
}

shutil.rmtree(out, ignore_errors=True)
os.makedirs(os.path.join(out, "licenses"))
c = zlib.compressobj(9, zlib.DEFLATED, -15)
data = c.compress(json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()) + c.flush()
with open(os.path.join(out, "catalog.json.deflate"), "wb") as f:
    f.write(data)
for s in catalog["sources"]:
    name = os.path.basename(s["licenseFile"])
    with open(os.path.join(out, "licenses", name), "wb") as f:
        f.write(show("catalog/agents/" + s["licenseFile"]))
with open(os.path.join(out, "THIRD_PARTY_NOTICES.md"), "wb") as f:
    f.write(show("THIRD_PARTY_NOTICES.md"))
print(f"{len(agents)} agents from Plexiform {plexiform}: {len(data) // 1024} KB")
