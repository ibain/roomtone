#!/usr/bin/env python3
"""Ensure Icon Composer Roomtone.icon is a target resource after xcodegen.

XcodeGen currently drops .icon bundles, so App Icon never ships without this.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PBX = ROOT / "Roomtone.xcodeproj" / "project.pbxproj"
ICON_REL = "Roomtone/Resources/Roomtone.icon"

FILE_REF = "EFD2B07B30266ABD00963D56"
BUILD_FILE = "A0F1E2D3C4B5A69788776655"
RES_PHASE = "B1A2C3D4E5F6071890ABCDEF"
RES_GROUP = "C2B3A4D5E6F7081910BCDEFA"


def main() -> int:
    if not (ROOT / ICON_REL).is_dir():
        print(f"wire_app_icon: missing {ICON_REL}", file=sys.stderr)
        return 1
    text = PBX.read_text()
    if f"{BUILD_FILE} /* Roomtone.icon in Resources */" in text and "PBXResourcesBuildPhase" in text:
        print("wire_app_icon: already wired")
        return 0

    # Strip any stale partial refs from a previous half-apply.
    text = re.sub(rf"\t\t{FILE_REF} /\* Roomtone\.icon \*/ = \{{[^}}]+\}};\n", "", text)
    text = re.sub(rf"\t\t{BUILD_FILE} /\* Roomtone\.icon in Resources \*/ = \{{[^}}]+\}};\n", "", text)
    text = re.sub(rf"\t\t{RES_GROUP} /\* Resources \*/ = \{{.*?\n\t\t\}};\n", "", text, flags=re.S)
    text = re.sub(
        rf"/\* Begin PBXResourcesBuildPhase section \*/.*?/\* End PBXResourcesBuildPhase section \*/\n",
        "",
        text,
        flags=re.S,
    )
    text = text.replace(f"\t\t\t\t{FILE_REF} /* Roomtone.icon */,\n", "")
    text = text.replace(f"\t\t\t\t{RES_GROUP} /* Resources */,\n", "")
    text = text.replace(f"\t\t\t\t{RES_PHASE} /* Resources */,\n", "")
    text = text.replace(f"\t\t\t\t{BUILD_FILE} /* Roomtone.icon in Resources */,\n", "")

    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{BUILD_FILE} /* Roomtone.icon in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {FILE_REF} /* Roomtone.icon */; }};\n",
    )

    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        f"\t\t{FILE_REF} /* Roomtone.icon */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = folder.iconcomposer.icon; path = Roomtone.icon; "
        f'sourceTree = "<group>"; }};\n',
    )

    resources_group = (
        f"\t\t{RES_GROUP} /* Resources */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n"
        f"\t\t\t\t{FILE_REF} /* Roomtone.icon */,\n"
        f"\t\t\t);\n"
        f"\t\t\tpath = Resources;\n"
        f'\t\t\tsourceTree = "<group>";\n'
        f"\t\t}};\n"
    )
    text = text.replace("/* Begin PBXGroup section */\n", "/* Begin PBXGroup section */\n" + resources_group)

    roomtone_group = re.search(
        r"(/\* Roomtone \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)",
        text,
    )
    if not roomtone_group:
        print("wire_app_icon: Roomtone group not found", file=sys.stderr)
        return 1
    text = text.replace(
        roomtone_group.group(1),
        roomtone_group.group(1) + f"\t\t\t\t{RES_GROUP} /* Resources */,\n",
        1,
    )

    target_phases = re.search(
        r"(/\* Roomtone \*/ = \{\n"
        r"\t\t\tisa = PBXNativeTarget;\n"
        r"\t\t\tbuildConfigurationList = [A-F0-9]+ /\* Build configuration list for PBXNativeTarget \"Roomtone\" \*/;\n"
        r"\t\t\tbuildPhases = \(\n)",
        text,
    )
    if not target_phases:
        print("wire_app_icon: target buildPhases not found", file=sys.stderr)
        return 1
    text = text.replace(
        target_phases.group(1),
        target_phases.group(1) + f"\t\t\t\t{RES_PHASE} /* Resources */,\n",
        1,
    )

    resources_phase = (
        "/* Begin PBXResourcesBuildPhase section */\n"
        f"\t\t{RES_PHASE} /* Resources */ = {{\n"
        f"\t\t\tisa = PBXResourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{BUILD_FILE} /* Roomtone.icon in Resources */,\n"
        f"\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};\n"
        "/* End PBXResourcesBuildPhase section */\n\n"
    )
    text = text.replace(
        "/* Begin PBXSourcesBuildPhase section */\n",
        resources_phase + "/* Begin PBXSourcesBuildPhase section */\n",
    )

    PBX.write_text(text)
    print("wire_app_icon: wired Roomtone.icon into Resources build phase")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
