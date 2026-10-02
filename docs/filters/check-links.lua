--- check-links.lua — warn about links that go nowhere.
--
-- Two checks, both computable without touching the network:
--
--   1. `#anchor` targets that match no id anywhere in the document. These are
--      the ones that rot silently: rename a heading and every link to it
--      becomes a no-op that still looks like a link.
--   2. Relative file targets that don't exist on disk. Resolved against the
--      working directory and against the directory of each input file, which
--      covers both `pages/foo.md` (from the repo root) and `foo.md` (from a
--      sibling page).
--
-- External links (anything with a scheme) are left alone — checking those
-- needs the network and belongs in a different tool.
--
-- Usage:
--   pandoc --lua-filter filters/check-links.lua ...            # warn only
--   pandoc -M link-check-strict=true --lua-filter ... ...      # fail the build
--
-- Note that in the single-page build every section is concatenated into one
-- index.html, so a link to another section's *file* will not resolve in the
-- output even when the file exists. Link to that section's `#anchor` instead.

local ids = {}
local links = {}

local function record_id (el)
  if el.attr and el.attr.identifier and el.attr.identifier ~= '' then
    ids[el.attr.identifier] = true
  end
end

local function search_roots ()
  local roots = { '.' }
  for _, f in ipairs(PANDOC_STATE.input_files or {}) do
    local dir = pandoc.path.directory(f)
    if dir and dir ~= '' then roots[#roots + 1] = dir end
  end
  return roots
end

local function file_exists (path)
  local fh = io.open(path, 'r')
  if fh then fh:close() return true end
  -- A directory opens as nil on macOS, so fall back to a rename-to-self probe.
  return os.rename(path, path) ~= nil
end

return {
  -- Collect every id and every link in one pass over the whole document.
  {
    Block = record_id,
    Inline = record_id,
    Link = function (el)
      links[#links + 1] = el.target
    end,
  },
  -- Then report, once, with everything known.
  {
    Pandoc = function (doc)
      local problems = {}
      local roots = search_roots()

      for _, target in ipairs(links) do
        if target == '' then
          problems[#problems + 1] = 'empty link target'
        elseif target:match('^#') then
          local anchor = target:sub(2)
          if not ids[anchor] then
            problems[#problems + 1] = 'no such anchor: ' .. target
          end
        elseif not target:match('^%a[%w+.-]*:') and not target:match('^//') then
          -- Relative path, with any fragment or query stripped off.
          local path = target:gsub('[#?].*$', '')
          if path ~= '' then
            local found = false
            for _, root in ipairs(roots) do
              if file_exists(pandoc.path.join{ root, path }) then
                found = true
                break
              end
            end
            if not found then
              problems[#problems + 1] = 'no such file: ' .. target
            end
          end
        end
      end

      if #problems > 0 then
        io.stderr:write('[check-links] ' .. #problems .. ' problem(s):\n')
        for _, p in ipairs(problems) do
          io.stderr:write('  - ' .. p .. '\n')
        end
        if doc.meta['link-check-strict'] then
          error('check-links: ' .. #problems .. ' broken link(s)', 0)
        end
      end

      return doc
    end,
  },
}
