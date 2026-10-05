---
title: talk
---

<!-- An HTML comment. Tree-sitter-markdown parses this block (and any raw
     HTML) as an html_block node, and the frontmatter's closing ---
     starts a section whose first named child is this comment, not a
     heading. Before the fix, heading_level_of/1 crashed on it. -->

# The problem

Some text.
