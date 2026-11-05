#!/usr/bin/env python3
"""Generate source.json (AltStore/SideStore repo format) from published GitHub releases.

Run in CI after a release, or locally with GH_TOKEN set. Old versions are rebuilt from
the releases API, so the file is self-healing if it is deleted or edited by hand.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = os.environ.get("GITHUB_REPOSITORY", "h4rvey-g/podcast-learning")
OWNER, NAME = REPO.split("/")
BRANCH = "main"
RAW = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}/"
TINT = "#6D4AFF"  # Assets.xcassets/AccentColor.colorset (light)
ICON = RAW + "PodcastLearning/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
DESCRIPTION = (
    "Learn English from podcasts and transcripts you import. Your library, dictionary, "
    "dictation, and spaced review all run on device. Optional AI analysis and audio "
    "transcription use your own API key. These builds are unsigned: SideStore re-signs "
    "them with your Apple ID."
)

QUERY = """query($owner:String!,$name:String!){repository(owner:$owner,name:$name){
releases(first:100,orderBy:{field:CREATED_AT,direction:DESC}){nodes{
tagName publishedAt isDraft isPrerelease
releaseAssets(first:20){nodes{name size downloadUrl}}}}}}"""


def setting(pattern: str, path: Path) -> str:
    match = re.search(pattern, path.read_text(), re.MULTILINE)
    if not match:
        sys.exit(f"error: {pattern} not found in {path.relative_to(ROOT)}")
    return match.group(1)


def releases() -> list[dict]:
    out = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={QUERY}", "-F", f"owner={OWNER}",
         "-F", f"name={NAME}", "--jq", ".data.repository.releases.nodes"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(out.stdout)


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def main() -> None:
    bundle_id = setting(r"^APP_BUNDLE_ID\s*=\s*(\S+)", ROOT / "Config.xcconfig")
    min_os = setting(r"<key>IPHONEOS_DEPLOYMENT_TARGET</key>\s*<string>([\d.]+)</string>",
                     ROOT / "PodcastLearning.xcodeproj/project.pbxproj")

    versions = []
    for release in releases():
        ipa = next(
            (asset for asset in release["releaseAssets"]["nodes"]
             if re.fullmatch(r"PodLearn-.+-unsigned\.ipa", asset["name"])),
            None,
        )
        if release["isDraft"] or release["isPrerelease"] or not ipa:
            continue
        version = release["tagName"].removeprefix("v")
        versions.append({
            "version": version,
            "date": release["publishedAt"],
            "localizedDescription": f"PodLearn {version}. Unsigned build; SideStore re-signs it with your Apple ID.",
            "downloadURL": "https://ghfast.top/" + ipa["downloadUrl"],
            "size": ipa["size"],
            "minOSVersion": min_os,
        })

    if not versions:
        sys.exit("error: no releases with a PodLearn-*-unsigned.ipa asset")
    versions.sort(key=lambda v: version_key(v["version"]), reverse=True)
    latest = versions[0]

    app = {
        "name": "PodLearn",
        "bundleIdentifier": bundle_id,
        "developerName": OWNER,
        "subtitle": "English practice from podcasts",
        "localizedDescription": DESCRIPTION,
        "iconURL": ICON,
        "tintColor": TINT,
        "category": "Education",
        "versions": versions,
        # Legacy top-level fields; old clients read these instead of versions[0].
        "version": latest["version"],
        "versionDate": latest["date"],
        "downloadURL": latest["downloadURL"],
        "size": latest["size"],
        "minOSVersion": min_os,
    }

    source = {
        "name": "PodLearn",
        "identifier": f"{bundle_id}.source",
        "subtitle": "Podcast learning for English",
        "description": DESCRIPTION,
        "iconURL": ICON,
        "headerURL": ICON,
        "tintColor": TINT,
        "featuredApps": [bundle_id],
        "apps": [app],
        "news": [],
    }

    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "source.json")
    out.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {out.name}: {bundle_id} {latest['version']} ({len(versions)} versions)", file=sys.stderr)


if __name__ == "__main__":
    main()
