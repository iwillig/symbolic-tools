# website

The project's static site, built with [Pelican](https://getpelican.com/)
and styled with [Pico CSS](https://picocss.com/) (loaded from its CDN in
`theme/templates/base.html` — no build step for the CSS itself).

The homepage lives at `content/pages/home.md` — a Page saved directly
as `index.html` (see its own `Save_as`/`URL` metadata; `DIRECT_TEMPLATES`
in `pelicanconf.py` drops the default blog-index generation so there's
only ever one file at that path). Add further Markdown/reST posts and
pages under `content/` when ready.

Fenced code blocks (` ```prolog `, ` ```erlang `, ` ```sh `, ...) are
syntax-highlighted by Pygments through Markdown's `codehilite`
extension. The stylesheet for that is generated, not hand-written —
`theme/static/css/pygments.css`, produced by
`scripts/gen_pygments_css.py`. Re-run it after changing the light/dark
style names in that script:

```sh
pipenv run python scripts/gen_pygments_css.py
```

Diagrams are [PlantUML](https://plantuml.com/) C4 diagrams
(`diagrams/*.puml`, using the bundled C4-PlantUML stdlib via
`!include <C4/C4_Container>` — no network fetch needed at render time).
They're rendered to SVG and committed under `theme/static/img/`, the
same generate-once-and-commit approach as the Pygments stylesheet, so
`just build` never needs PlantUML installed. Regenerate after editing
a `.puml` source:

```sh
brew install plantuml   # pulls in graphviz + a JVM
./scripts/gen_diagrams.sh
```

## Setup

```sh
pipenv install
```

Requires [just](https://github.com/casey/just) (`brew install just`) to
run the recipes below.

## Build

```sh
just build   # writes to output/
just serve   # build, watch content/ for changes, and serve output/ locally
just clean   # remove output/ and the build cache
```
