#!/usr/bin/env python3
"""Download the Gotham theme's web fonts once, so visitors never contact Google.

Google Fonts serves a stylesheet whose @font-face rules point at font files on
fonts.gstatic.com. Loading that stylesheet from a visitor's browser sends the
visitor's IP address to Google (a German court fined a site for exactly this
under the GDPR). Instead, this fetches the stylesheet and its font files on the
server, saves them under www/fonts/, and writes www/fonts/gotham-fonts.css with
local paths; www/gotham.css imports that file.

The fonts (Rajdhani, Saira Stencil One) are under the SIL Open Font License,
which allows redistribution. www/fonts/ is not in git: run this on each server
(the ship script does), and again only to pick up new versions.

    python3 deploy/fetch_fonts.py [--out www/fonts]
"""
import argparse
import hashlib
import os
import re
import sys
import urllib.request

CSS_URL = ("https://fonts.googleapis.com/css2?family=Rajdhani:wght@500;600;700"
           "&family=Saira+Stencil+One&display=swap")
# Google serves woff2 only to browsers that say they read it.
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "www", "fonts"))
    out = os.path.abspath(ap.parse_args().out)
    os.makedirs(out, exist_ok=True)
    css = get(CSS_URL).decode("utf-8")
    urls = sorted(set(re.findall(r"url\((https://fonts\.gstatic\.com/[^)]+)\)", css)))
    if not urls:
        sys.exit("no font files in Google's stylesheet; nothing changed")
    for u in urls:
        name = hashlib.sha256(u.encode()).hexdigest()[:16] + os.path.splitext(u)[1]
        data = get(u)
        tmp = os.path.join(out, name + ".tmp")
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, os.path.join(out, name))
        css = css.replace(u, name)                 # relative to the stylesheet itself
    css = ("/* Written by deploy/fetch_fonts.py from Google Fonts; served locally so visitors\n"
           "   never contact Google. Rajdhani and Saira Stencil One: SIL Open Font License. */\n" + css)
    tmp = os.path.join(out, "gotham-fonts.css.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(css)
    os.replace(tmp, os.path.join(out, "gotham-fonts.css"))
    print("fonts: %d files and gotham-fonts.css in %s" % (len(urls), out))


if __name__ == "__main__":
    main()
