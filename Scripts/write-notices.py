#!/usr/bin/env python3
"""Writes the app's third-party notices, license texts, and About-panel credits.

Usage: write-notices.py <FFmpeg install prefix> <Contents/Resources dir>

Reads BUILD-INFO.txt written by Scripts/build-ffmpeg.sh.
"""

import html
import json
import os
import shutil
import sys

prefix, resources = sys.argv[1:3]
info = dict(line.rstrip("\n").split("=", 1) for line in open(os.path.join(prefix, "BUILD-INFO.txt")) if "=" in line)

licenses = os.path.join(resources, "Licenses", "FFmpeg")
os.makedirs(licenses, exist_ok=True)
for name in ("COPYING.LGPLv2.1", "LICENSE.md"):
    shutil.copy(os.path.join(prefix, "share", "licenses", name), os.path.join(licenses, name))

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(root, "Package.resolved")) as file:
    pins = json.load(file)["pins"]
alamofire_version = next(pin["state"]["version"] for pin in pins if pin["identity"] == "alamofire")
shutil.copy(os.path.join(root, "Licenses", "Alamofire.txt"), os.path.join(resources, "Licenses", "Alamofire.txt"))

notices = f"""Loudible third-party notices

Alamofire {alamofire_version}
https://github.com/Alamofire/Alamofire
Distributed under the MIT License. License text: Licenses/Alamofire.txt.

FFmpeg {info['version']}
This software uses libraries from the FFmpeg project (https://ffmpeg.org) under the
GNU Lesser General Public License version 2.1 or later: libavformat, libavcodec, and
libavutil, bundled unmodified as separate dynamic libraries in Contents/Frameworks.
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.

License text: Licenses/FFmpeg/COPYING.LGPLv2.1 (see also Licenses/FFmpeg/LICENSE.md).

Source code: the exact source used is the official release tarball
  {info['url']}
  SHA-256 {info['sha256']}
It is also published alongside each Loudible release, together with the build
script (Scripts/build-ffmpeg.sh). FFmpeg was configured with:
  {info['configure']}

You may replace the bundled FFmpeg libraries with your own builds of the same version.
"""
with open(os.path.join(resources, "THIRD_PARTY_NOTICES.txt"), "w") as file:
    file.write(notices)

credits = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"></head>
<body style="font: 11px -apple-system, sans-serif; text-align: center">
<p>Downloads use <a href="https://github.com/Alamofire/Alamofire">Alamofire</a>
{html.escape(alamofire_version)} under the MIT License.</p>
<p>This software uses libraries from the <a href="https://ffmpeg.org">FFmpeg</a> project
under the <a href="https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html">LGPLv2.1</a>.</p>
<p>FFmpeg {html.escape(info['version'])} source:
<a href="{html.escape(info['url'])}">{html.escape(os.path.basename(info['url']))}</a></p>
</body></html>
"""
with open(os.path.join(resources, "Credits.html"), "w") as file:
    file.write(credits)
