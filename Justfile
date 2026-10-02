# Slidy deck recipes, ported from oneproject-knowledge-base.
# Format reference: https://pandoc.org/demo/example33/10-slide-shows.html

# Filter order is significant and the same everywhere:
#   1. include      puts each diagram's source in its block, so PlantUML
#                   resolves !include before it reads the diagram from a pipe
#   2. diagram      renders every ```plantuml and ```mermaid block into an image
#   3. the rest     operate on the assembled document
#   4. --citeproc   LAST, so citations inside included files are processed
filters := "--lua-filter docs/filters/include.lua \
    --lua-filter docs/filters/diagram.lua \
    --lua-filter docs/filters/not-in-format.lua \
    --lua-filter docs/filters/pagebreak.lua \
    --lua-filter docs/filters/check-links.lua"

# docs/filters/diagram.lua looks for each engine at $<ENGINE>_BIN before it falls
# back to the bare name on PATH. plantuml and dot come from Homebrew and need
# nothing here. mermaid-cli is an npm package — it carries a Chromium and has
# no formula. This repo has no node_modules, so it falls back to mmdc on PATH;
# if you add mermaid-cli as a devDependency, point this at
# justfile_directory() / "node_modules/.bin/mmdc".
export MERMAID_BIN := "mmdc"

# Where PlantUML looks for an !include it finds inside a diagram that arrived
# on its stdin. The oneproject-knowledge-base original points at src/ because
# its diagrams live beside its source; here they live in docs/diagrams/, because
# src/ is the Erlang tree symbolic_parse scans.
export PLANTUML_INCLUDE_PATH := "docs/diagrams"

# A syntax check over exactly the files the build reads: decks pull diagrams in
# with `!include docs/diagrams/<name>.plantuml`, so a bad diagram fails here before
# it can fail a deck build.
lint-plantuml:
    plantuml --check-syntax docs/diagrams/*.plantuml

# List the recipes when run with no arguments.
default:
    @just --list

# Build one deck: just build-presentation docs/presentations/slides.md
build-presentation FILE:
    pandoc -t slidy \
    --embed-resources \
    --standalone \
    {{filters}} --citeproc \
    {{FILE}} \
    -o {{replace(FILE, ".md", ".html")}}

# --embed-resources: docs/filters/diagram.lua hands each rendered diagram to pandoc's
# media bag rather than to a file, so this flag is what puts the SVGs in the
# page. The result is one portable file per deck.
# Build every deck in docs/presentations/.
build-presentations:
    #!/usr/bin/env bash
    set -euo pipefail
    for file in docs/presentations/*.md; do
        [ -e "$file" ] || continue
        just build-presentation "$file"
    done

# TITLE and DESCRIPTION are quoted here because just joins a recipe's arguments
# with spaces before the shell sees them, so an unquoted multi-word value would
# arrive as several arguments.
# Start a new deck: just talk NAME "Title" "One line on what it covers"
talk NAME TITLE="" DESCRIPTION="":
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{NAME}}"
    if ! [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "'$name' is not a slug. Use lowercase letters, digits, and hyphens." >&2
        exit 1
    fi
    target="docs/presentations/$name.md"
    if [ -e "$target" ]; then
        echo "$target already exists"
        exit 1
    fi
    title="{{TITLE}}"
    if [ -z "$title" ]; then
        title=$(printf '%s' "$name" | sed -e 's/-/ /g' -e 's/_/ /g')
        title="$(printf '%s' "${title:0:1}" | tr '[:lower:]' '[:upper:]')${title:1}"
    fi
    # The template is Mustache with double braces. Writing those literally here
    # would hit just's own interpolation, so the brace pairs come from printf
    # with their octal codes, and reach sed as characters, not as syntax.
    ob=$(printf '\173\173'); cb=$(printf '\175\175')
    # Escape / \ & so a title survives sed's replacement syntax.
    esc() { printf '%s' "$1" | sed 's/[&/\]/\\&/g'; }
    sed -e "s/${ob}date${cb}/$(date +%F)/g" \
        -e "s/${ob}title${cb}/$(esc "$title")/g" \
        -e "s/${ob}description${cb}/$(esc "{{DESCRIPTION}}")/g" \
        -e "s/${ob}name${cb}/$name/g" \
        docs/templates/presentation.md > "$target"
    echo "created $target"

# Remove the built decks. Nothing under docs/presentations/*.md is touched.
clean:
    -rm -f docs/presentations/*.html

# The oneproject-knowledge-base original is node scripts/serve.ts; python3 is
# already here, so it stands in.
# View a build in a browser: just serve, then open http://localhost:4000.
serve PORT="4000":
    python3 -m http.server {{PORT}}
