AUTHOR = "Ivan Willig"
SITENAME = "symbolic-tools"
SITEURL = ""

PATH = "content"

TIMEZONE = "America/New_York"
DEFAULT_LANG = "en"

THEME = "theme"

# No content yet, so no feeds to generate.
FEED_ALL_ATOM = None
CATEGORY_FEED_ATOM = None
TRANSLATION_FEED_ATOM = None
AUTHOR_FEED_ATOM = None
AUTHOR_FEED_RSS = None

DEFAULT_PAGINATION = 10

# The homepage IS a Page (content/pages/home.md, saved as index.html —
# see its own metadata) rather than a blog-article listing, since there
# are no articles. Drop 'index' from the default direct-templates list
# so Pelican doesn't also generate its own empty article-listing
# index.html alongside (and racing) it.
DIRECT_TEMPLATES = ["tags", "categories", "authors", "archives"]

# Document-relative URLs while developing locally, so `just serve` and a
# plain `file://` open of output/index.html both resolve links correctly.
RELATIVE_URLS = True
