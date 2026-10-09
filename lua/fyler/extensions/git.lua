local extensions = require('fyler.extensions')
local libpath = require('fyler.lib.path')
local util = require('fyler.util')

local uv = vim.uv
local repo_root_cache = {}
local propagate_priority = {
  ['UU'] = 6,
  ['MM'] = 5,
  [' M'] = 5,
  ['AM'] = 5,
  ['M '] = 4,
  ['A '] = 4,
  ['??'] = 3,
  [' D'] = 2,
  ['D '] = 2,
  ['R '] = 2,
  ['!!'] = 0,
}
local status_order = {
  ['UU'] = 1,
  ['MM'] = 2,
  ['M '] = 3,
  ['AM'] = 4,
  ['A '] = 5,
  [' M'] = 6,
  ['??'] = 7,
  ['R '] = 8,
  ['D '] = 9,
  [' D'] = 10,
  ['!!'] = 11,
}
local default_icons = {
  [' M'] = { icon = '×', hl = 'FylerGitModified' },
  ['M '] = { icon = '', hl = 'FylerGitStaged' },
  ['MM'] = { icon = '', hl = 'FylerGitStaged' },
  ['??'] = { icon = '', hl = 'FylerGitUntracked' },
  [' D'] = { icon = '', hl = 'FylerGitDeleted' },
  ['D '] = { icon = '', hl = 'FylerGitStaged' },
  ['R '] = { icon = '', hl = 'FylerGitRenamed' },
  ['UU'] = { icon = '󰧾', hl = 'FylerGitConflict' },
  ['!!'] = { icon = '󱙝', hl = 'FylerGitIgnored' },
}

local default_highlights_tbl
local refresh_count = 0
local status_cache = {}
local H = {}

function H.repo_root(path)
  if repo_root_cache[path] then return repo_root_cache[path] end

  local dir = libpath.to_dirname(path)
  while #dir > 0 do
    if uv.fs_stat(libpath.do_join(dir, '.git')) then
      repo_root_cache[path] = dir
      return dir
    end
    local parent = libpath.to_dirname(dir)
    if parent == dir then break end
    dir = parent
  end

  repo_root_cache[path] = false
  return nil
end

function H.parse_porcelain(raw, repo_path, out)
  if not raw or #raw == 0 then return end

  local tokens = vim.split(raw, '\0', { plain = true })
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    i = i + 1
    if #token >= 4 then
      local xy = token:sub(1, 2)
      local path = token:sub(4)
      if path and #path > 0 then
        out[libpath.do_join(repo_path, path)] = xy
        if xy:match('[RC]') and i <= #tokens and #tokens[i] and #tokens[i] > 0 then
          out[libpath.do_join(repo_path, tokens[i])] = xy
          i = i + 1
        end
      end
    end
  end
end

function H.get_icon(xy, icons)
  local entry = icons[xy]
  if entry then return entry.icon, entry.hl end
  return nil, nil
end

function H.is_inside_git_dir(path)
  local dir = path
  while #dir > 0 do
    local name = dir:match('([^/\\]+)[/\\]*$')
    if name == '.git' then
      return true
    end
    local parent = libpath.to_dirname(dir)
    if parent == dir then break end
    dir = parent
  end
  return false
end

function H.mark_git_dir(entries, statuses)
  for _, entry in ipairs(entries) do
    local root = H.repo_root(entry.path)
    if root then
      local git_dir = libpath.do_join(root, '.git')

      if entry.path == git_dir then
        statuses[git_dir] = '!!'
      end
    end
  end
end

function H.store_known_roots()
  local watcher_cfg = require('fyler.config').DATA.extensions.watcher
  if not watcher_cfg or not watcher_cfg.enabled then return end
  local roots = {}
  for _, root in pairs(repo_root_cache) do
    if root then roots[root] = true end
  end
  watcher_cfg.known_git_roots = roots
end

function H.propagate_to_parents(statuses)
  local children_statuses = {}

  for path, xy in pairs(statuses) do
    local dir = libpath.to_dirname(path)

    while #dir > 0 do
      children_statuses[dir] = children_statuses[dir] or {}

      local found = false
      for _, existing in ipairs(children_statuses[dir]) do
        if existing == xy then
          found = true
          break
        end
      end

      if not found then
        table.insert(children_statuses[dir], xy)
      end

      local parent = libpath.to_dirname(dir)
      if parent == dir then break end
      dir = parent
    end
  end

  for dir, child_statuses in pairs(children_statuses) do
    if statuses[dir] then
      table.insert(child_statuses, statuses[dir])
    end
    statuses[dir] = child_statuses
  end
end

function H.statuses_async(entries, force, cb)
  if #entries == 0 then
    cb({})
    return
  end

  local repos = {}
  for _, entry in ipairs(entries) do
    local root = H.repo_root(entry.path)
    if root then repos[root] = true end
  end

  if not next(repos) then
    cb({})
    return
  end

  local repos_to_fetch = {}
  if force then
    repos_to_fetch = vim.deepcopy(repos)
  else
    for root, _ in pairs(repos) do
      if not status_cache[root] then repos_to_fetch[root] = true end
    end
  end

  if not next(repos_to_fetch) then
    local all_statuses = {}
    for root, _ in pairs(repos) do
      for path, xy in pairs(status_cache[root] or {}) do
        all_statuses[path] = xy
      end
    end
    cb(all_statuses)
    return
  end

  local total = 0
  for _ in pairs(repos_to_fetch) do
    total = total + 1
  end

  local done = util.promise_all(total, function()
    local all_statuses = {}
    for root, _ in pairs(repos) do
      for path, xy in pairs(status_cache[root] or {}) do
        all_statuses[path] = xy
      end
    end
    cb(all_statuses)
  end)

  for root, _ in pairs(repos_to_fetch) do
    vim.system({ 'git', '-C', root, 'status', '--porcelain', '-z' }, { text = true }, function(result)
      status_cache[root] = {}
      if result.code == 0 then H.parse_porcelain(result.stdout, root, status_cache[root]) end
      done()
    end)
  end
end

function H.git_col(lines)
  local col = 0
  for _, line in ipairs(lines) do
    col = math.max(col, vim.fn.strdisplaywidth(line))
  end
  return col + 1
end

function H.get_default_highlights()
  if default_highlights_tbl then return default_highlights_tbl end

  return {
    FylerGitConflictIcon = { fg = '#e06c75' },
    FylerGitDeletedIcon = { fg = '#fb4934' },
    FylerGitIgnoredIcon = { fg = '#83a598' },
    FylerGitModifiedIcon = { fg = '#fb4934' },
    FylerGitRenamedIcon = { fg = '#8ec07c' },
    FylerGitStagedIcon = { fg = '#d3869b' },
    FylerGitUntrackedIcon = { fg = '#8ec07c' },
  }
end

extensions.register({
  name = 'git',
  setup = function(opts, config)
    config.extensions.git = vim.tbl_deep_extend('force', { icons = vim.deepcopy(default_icons), inline = true }, opts)
    config.extensions.git.inline = true
  end,
  hooks = {
    finder_refresh_post = function(inst, visible, hl_ns, lines, args)
      local cfg = require('fyler.config').DATA.extensions.git
      if not cfg.enabled then return end

      refresh_count = refresh_count + 1
      local current_count = refresh_count

      local gc = H.git_col(lines)

      local function apply(i, item, stat)
        local icons = {}

        if type(stat) == 'table' then
          table.sort(stat, function(a, b)
            return (status_order[a] or 99) < (status_order[b] or 99)
          end)

          for _, status in ipairs(stat) do
            local icon, hl = H.get_icon(status, cfg.icons)
            if icon and hl then
              table.insert(icons, { icon .. ' ', hl .. 'Icon' })
            end
          end
        else
          local icon, hl = H.get_icon(stat, cfg.icons)
          if icon and hl then
            table.insert(icons, { icon, hl .. 'Icon' })
          end
        end

        if #icons == 0 then return end

        if cfg.inline then
          pcall(
            vim.api.nvim_buf_set_extmark,
            inst.buf_id,
            hl_ns,
            i - 1,
            item._name_col + #item.name,
            { virt_text = icons, hl_mode = 'combine' }
          )
        else
          pcall(
            vim.api.nvim_buf_set_extmark,
            inst.buf_id,
            hl_ns,
            i - 1,
            0,
            { virt_text = icons, virt_text_win_col = gc, hl_mode = 'combine' }
          )
        end

        -- Mantener el resaltado Git del nombre
        local _, hl = H.get_icon(type(stat) == 'table' and stat[1] or stat, cfg.icons)
        if hl then
          pcall(
            vim.api.nvim_buf_set_extmark,
            inst.buf_id,
            hl_ns,
            i - 1,
            item._name_col,
            {
              hl_group = hl,
              end_line = i - 1,
              end_col = item._name_col + #item.name,
              hl_mode = 'combine',
            }
          )
        end
      end

      H.statuses_async(visible, args and args.force, function(statuses)
        if current_count == refresh_count then
          H.mark_git_dir(visible, statuses)
          H.propagate_to_parents(statuses)
          H.store_known_roots()

          for i, item in ipairs(visible) do
            local stat = statuses[item.path]

            if H.is_inside_git_dir(item.path) then
              stat = '!!'
            end

            if stat then
              apply(i, item, stat)
            end
          end
        end
      end)
    end,
    highlights_post = function()
      for name, hl in pairs(H.get_default_highlights()) do
        hl.default = true
        vim.api.nvim_set_hl(0, name, hl)
      end
    end,
  },
})
