#!/bin/sh
# Renders every diagrams/*.puml source into theme/static/img/*.svg.
#
# The rendered SVGs are committed (see theme/static/img/) so `make
# build` never needs PlantUML/Java/Graphviz installed just to build the
# site — same reasoning as theme/static/css/pygments.css: generated
# once by a script, checked in, regenerated only when its source
# changes.
#
# Requires PlantUML (with its bundled C4-PlantUML stdlib, used via
# `!include <C4/C4_Container>` in diagrams/architecture.puml) and a JVM
# — `brew install plantuml` pulls in graphviz and openjdk with it.
set -e
cd "$(dirname "$0")/.."

mkdir -p theme/static/img
for src in diagrams/*.puml; do
    plantuml -tsvg -o "$(pwd)/theme/static/img" "$src"
done
echo "wrote theme/static/img/*.svg from diagrams/*.puml"
