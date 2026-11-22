import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import zipfile

IPA_PATH = "build/Swipterm.ipa"
OUTPUT_PATH = "build/altstore"

parser = argparse.ArgumentParser()
parser.add_argument("--tag", default="nightly", help="release tag")
tag = parser.parse_args().tag

repository = os.environ.get("GITHUB_REPOSITORY") or "swipt-automation/Swipterm"
website_url = "https://github.com/" + repository
release_url = website_url + "/releases/download/" + tag + "/"

with zipfile.ZipFile(IPA_PATH) as archive:
    info_plist = next(name for name in archive.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name))
    info = plistlib.loads(archive.read(info_plist))

name = "Swipterm Nightly"
identifier = info["CFBundleIdentifier"]
source_url = release_url + "altstore.json"
if tag != "nightly":
    name = "Swipterm"
    identifier += ".stable"
    source_url = website_url + "/releases/latest/download/altstore.json"

with open(IPA_PATH, "rb") as file:
    content = file.read()

with open("Swipterm/Swipterm.entitlements", "rb") as file:
    entitlements = sorted(plistlib.load(file).keys())

privacy = {
    key: value
    for key, value in sorted(info.items())
    if isinstance(value, str) and "UsageDescription" in key
}

source = {
    "name": name,
    "identifier": identifier,
    "sourceURL": source_url,
    "iconURL": release_url + "icon.png",
    "website": website_url,
    "apps": [
        {
            "name": info["CFBundleDisplayName"],
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "nekohasekai",
            "localizedDescription": "Swipterm runs a Linux distribution on this iPhone or iPad behind a Ghostty terminal.",
            "iconURL": release_url + "icon.png",
            "category": "developer",
            "versions": [
                {
                    "version": info["CFBundleShortVersionString"],
                    "buildVersion": info["CFBundleVersion"],
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "downloadURL": release_url + os.path.basename(IPA_PATH),
                    "size": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                    "minOSVersion": info["MinimumOSVersion"],
                }
            ],
            "appPermissions": {
                "entitlements": entitlements,
                "privacy": privacy,
            },
        }
    ],
    "news": [],
}

os.makedirs(OUTPUT_PATH, exist_ok=True)
with open(os.path.join(OUTPUT_PATH, "altstore.json"), "w", encoding="utf-8") as file:
    file.write(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
