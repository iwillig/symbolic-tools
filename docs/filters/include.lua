--- include.lua — resolve `!include` directives before the document is written.
--
-- This replaces the Python `pandoc-include` filter. It does the two things
-- this repository used it for, and it does them the same way:
--
--   1. A code block whose whole content is `!include path` becomes that file's
--      text. This is how a ```plantuml block pulls in `src/<name>.plantuml`,
--      so `just lint-plantuml` checks exactly what the build reads.
--   2. A paragraph whose whole content is `!include path` becomes that file
--      parsed as Markdown. No page uses this today; it is here for parity.
--
-- Usage:
--   pandoc --lua-filter filters/include.lua ...
--
-- Three rules that look like details and are not:
--
--   * The directive must be the WHOLE block. A block that holds an `!include`
--     line among other lines is left alone. This is what lets conventions.md
--     print the syntax as an example without the example being resolved, and
--     it is the rule `pandoc-include` applied.
--   * A code-block include goes ONE level deep. An `!include` inside the
--     included file stays as text, because in a `.plantuml` file that line is
--     PlantUML's own directive and PlantUML must be the one to resolve it.
--     A Markdown include, in contrast, recurses.
--   * `!include <name>` — the angle-bracket form — is PlantUML's standard
--     library, not a path. It is left alone.
--
-- A missing file fails the build. `pandoc-include` only warned, and a build
-- that quietly ships a diagram-shaped hole is worse than a build that stops.
--
-- Deliberately not supported, because nothing here needs them: glob patterns,
-- `shift-heading-level-by`, and the `include-entry` metadata key.

local MAX_DEPTH = 10

--- Directories to resolve a relative path against.
-- The working directory, then the directory of each input file. That covers
-- both `src/x.plantuml` written from the repository root and `x.plantuml`
-- written from a sibling page. Same order as check-links.lua.
local function search_roots (dir)
  local roots = {}
  if dir and dir ~= '' and dir ~= '.' then roots[#roots + 1] = dir end
  roots[#roots + 1] = '.'
  for _, f in ipairs(PANDOC_STATE.input_files or {}) do
    local input_dir = pandoc.path.directory(f)
    if input_dir and input_dir ~= '' then roots[#roots + 1] = input_dir end
  end
  return roots
end

--- The file's text, or nil if it cannot be read.
local function read_file (path)
  local fh = io.open(path, 'r')
  if not fh then return nil end
  local text = fh:read('a')
  fh:close()
  return text
end

--- Find `target` under one of the search roots and return its text and path.
local function resolve (target, dir)
  local path = target:gsub('^"(.*)"$', '%1'):gsub("^'(.*)'$", '%1')
  for _, root in ipairs(search_roots(dir)) do
    local candidate = pandoc.path.join{ root, path }
    local text = read_file(candidate)
    if text then return text, candidate end
  end
  return nil, path
end

--- The include target this text names, or nil if the text is not one include.
-- `text` is a whole block, so a newline inside the target means the block
-- holds more than an include directive and is none of our business.
local function directive (text)
  local body = text:gsub('^%s+', ''):gsub('%s+$', '')
  local target = body:match('^!include[ \t]+(.+)$')
  if not target or target:find('\n') or target:match('^<') then return nil end
  return target
end

local function fail (target, where)
  error(('include.lua: no such file: %s (included from %s)'):format(target, where), 0)
end

--- The filter, bound to the directory includes resolve against.
local function includer (dir, depth)
  local filter

  filter = {
    -- One level. The included text is inserted as it is.
    CodeBlock = function (block)
      local target = directive(block.text)
      if not target then return nil end
      local text = resolve(target, dir)
      if not text then fail(target, dir == '' and 'a code block' or dir) end
      block.text = (text:gsub('\n$', ''))
      return block
    end,

    -- Recursive. The included file is a document in its own right.
    Para = function (block)
      local target = directive(pandoc.utils.stringify(block.content))
      if not target then return nil end
      if depth >= MAX_DEPTH then
        error(('include.lua: includes nest more than %d deep at %s')
          :format(MAX_DEPTH, target), 0)
      end
      local text, path = resolve(target, dir)
      if not text then fail(target, dir == '' and 'the document' or dir) end
      local blocks = pandoc.read(text, 'markdown').blocks
      local walked = pandoc.walk_block(
        pandoc.Div(blocks),
        includer(pandoc.path.directory(path), depth + 1)
      )
      return walked.content
    end,
  }

  return filter
end

return { includer('', 0) }
