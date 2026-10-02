---
title: {{title}}
author: Ivan Willig
date: {{date}}
# One line on what the talk covers. Write it for somebody deciding
# whether to read on.
description: {{description}}
---

<!-- This file is a Mustache template rendered by the `talk` recipe in the
     Justfile, so {{name}}, {{title}}, and {{date}} are filled in when you run
     `just talk`. HTML escaping is off, because this output is Markdown.

     Build it:  just build-presentation docs/presentations/{{name}}.md
     One `#` heading starts a slide. Keep a slide to one point — if it needs
     scrolling, it is two slides. Delete the slides you do not use; this is an
     arc, not a form. -->

# The problem

<!-- Open on the problem the room already has, not on what you built. If they
     do not recognise the problem, nothing after this slide lands. -->

# {{title}} {.dark}

<!-- A dark slide marks the break between parts of a talk. Use it to move from
     the problem to your answer, and again before what you want from them. -->

# What it is

<!-- One sentence a listener could repeat to a colleague tomorrow. -->

# How it works

<!-- Diagrams live in docs/diagrams/, one per file, so `just lint-plantuml`
     checks them and a deck pulls the same drawing in. Draw
     docs/diagrams/{{name}}.plantuml first, then replace this comment with:
     ```plantuml
     !include docs/diagrams/{{name}}.plantuml
     ```
     Do not paste PlantUML source straight into a deck: nothing lints it. -->

# What it costs

|  | Needs |
|---|---|
| Hardware |  |
| Tooling |  |

# What to do next

<!-- End on the one action you want from the room, not on a summary. -->

::: handout
Speaker notes: hidden on screen, printed with the handout. Write the sentence
you will forget under pressure, not the slide you can already see. Use
`::: handout`, not `::: notes` — the slidy writer drops a notes block and the
text never reaches the page.
:::
