# Production settings for GitHub Pages, layered over pelicanconf.py.
#
# The site deploys as a GitHub Pages PROJECT site, so it lives at
# https://www.iwillig.me/symbolic-tools/ (the user site carries the
# iwillig.me domain; project pages serve under it, exactly like
# clj-llm). Two overrides make that work:
#
# - SITEURL points at the deployed URL, so the theme's
#   {{ SITEURL }}/theme/... links (CSS, favicon) resolve. Locally
#   pelicanconf keeps SITEURL = "" with document-relative URLs, which
#   is what makes `just serve` and a file:// open work.
#
# - RELATIVE_URLS turns off: with a real SITEURL, Pelican prefixes it
#   to generated links instead of making them document-relative.
#
# CI builds with `pelican content -o output -s publishconf.py`;
# nothing here affects a local `just build`/`just serve`.

import os
import sys

sys.path.append(os.curdir)

from pelicanconf import *  # noqa: F401,F403

SITEURL = "https://www.iwillig.me/symbolic-tools"
RELATIVE_URLS = False
