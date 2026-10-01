local async = require("diffview.async")
local helpers = require("diffview.tests.helpers")
local GitAdapter = require("diffview.vcs.adapters.git").GitAdapter
local GitRev = require("diffview.vcs.adapters.git.rev").GitRev
local RevType = require("diffview.vcs.rev").RevType
local File = require("diffview.vcs.file").File
local Diff2Hor = require("diffview.scene.layouts.diff_2_hor").Diff2Hor
local Diff4Mixed = require("diffview.scene.layouts.diff_4_mixed").Diff4Mixed
local lib = require("diffview.lib")
local actions = require("diffview.actions")
local utils = require("diffview.utils")

require("diffview").setup({ use_icons = false })

local eq = helpers.eq
local await = async.await

describe("submodule reference diffs", function()
  local root, parent, module, adapter, old, new, latest, base, head
  local errors, original_err

  local function git(cwd, ...)
    local out = vim.fn.systemlist({ "git", "-C", cwd, ... })
    if vim.v.shell_error ~= 0 then error(table.concat(out, "\n")) end
    eq(0, vim.v.shell_error)
    return out
  end

  local function write(path, lines)
    vim.fn.writefile(lines, path)
  end

  local function init(path)
    vim.fn.mkdir(path, "p")
    git(path, "init", "--quiet")
    git(path, "config", "user.name", "Diffview Tests")
    git(path, "config", "user.email", "diffview-tests@example.invalid")
    git(path, "config", "commit.gpgsign", "false")
  end

  local function commit(cwd, message)
    git(cwd, "add", "--all")
    git(cwd, "commit", "--quiet", "-m", message)
    return git(cwd, "rev-parse", "HEAD")[1]
  end

  local function open(args)
    local view = lib.diffview_open(args)
    assert(view)
    view:open()
    assert(vim.wait(10000, function() return view.initialized and view.cur_entry and view.cur_entry.opened end, 10))
    return view
  end

  local function open_submodule()
    local mapping = vim.fn.maparg("gs", "n", false, true)
    eq("Open the submodule diff in a new tabpage", mapping.desc)
    mapping.callback()
    local view = lib.get_current_view()
    assert(vim.wait(10000, function() return view.initialized and view.cur_entry and view.cur_entry.opened end, 10))
    return view
  end

  before_each(function()
    root = vim.fn.tempname():gsub("\\", "/")
    parent = root .. "/parent"
    module = parent .. "/module with spaces"
    init(parent)
    init(module)
    write(module .. "/file.txt", { "old" })
    old = commit(module, "old")
    write(module .. "/file.txt", { "new" })
    new = commit(module, "new")
    write(module .. "/file.txt", { "latest" })
    latest = commit(module, "latest")
    git(parent, "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", "../source", "module with spaces")
    git(module, "checkout", "--quiet", old)
    write(parent .. "/normal.txt", { "unchanged" })
    base = commit(parent, "base")
    git(module, "checkout", "--quiet", new)
    head = commit(parent, "bump")
    git(module, "checkout", "--quiet", latest)
    adapter = GitAdapter({ toplevel = parent })
    errors = {}
    original_err = utils.err
    utils.err = function(message) errors[#errors + 1] = message end
  end)

  after_each(function()
    utils.err = original_err
    for _, view in ipairs(vim.list_slice(lib.views)) do view:close() end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr):find(root, 1, true) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(root, "rf")
  end)

  it("resolves historical, index, local, dirty and ordinary entries", function()
    eq({ sha = old, dirty = false }, adapter:get_gitlink("module with spaces", GitRev(RevType.COMMIT, base)))
    eq({ sha = new, dirty = false }, adapter:get_gitlink("module with spaces", GitRev(RevType.STAGE, 0)))
    eq({ sha = latest, dirty = false }, adapter:get_gitlink("module with spaces", GitRev(RevType.LOCAL)))
    write(module .. "/untracked.txt", { "dirty" })
    eq({ sha = latest, dirty = true }, adapter:get_gitlink("module with spaces", GitRev(RevType.LOCAL)))
    eq(nil, adapter:get_gitlink("normal.txt", GitRev(RevType.COMMIT, base)))
    eq(nil, adapter:get_gitlink("missing", GitRev(RevType.STAGE, 0)))
  end)

  it("lists gitlinks even when Git config ignores them", helpers.async_test(function()
    git(parent, "config", "diff.ignoreSubmodules", "all")
    git(parent, "config", "diff.submodule", "diff")
    local err, files = await(adapter:tracked_files(
      GitRev(RevType.COMMIT, base), GitRev(RevType.COMMIT, head),
      { base .. ".." .. head }, "working",
      { default_layout = Diff2Hor, merge_layout = Diff4Mixed }
    ))
    eq(nil, err)
    eq(1, #files)
    eq("module with spaces", files[1].path)
    for _, file in ipairs(files) do file:destroy() end
  end))

  it("renders read-only SHA buffers, including the index and dirty worktree", helpers.async_test(function()
    write(module .. "/file.txt", { "dirty" })
    for _, item in ipairs({
      { rev = GitRev(RevType.COMMIT, base), line = "Subproject commit " .. old },
      { rev = GitRev(RevType.STAGE, 0), line = "Subproject commit " .. new },
      { rev = GitRev(RevType.LOCAL), line = "Subproject commit " .. latest .. "-dirty" },
    }) do
      local file = File({ adapter = adapter, path = "module with spaces", kind = "working", rev = item.rev })
      local bufnr = await(file:create_buffer())
      eq({
        item.line,
        "",
        "Press gs to open the submodule diff in a new tab.",
      }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      eq(false, vim.bo[bufnr].modifiable)
      eq("nowrite", vim.bo[bufnr].buftype)
      file:destroy()
    end
  end))

  it("keeps ordinary local files editable", helpers.async_test(function()
    local file = File({ adapter = adapter, path = "normal.txt", kind = "working", rev = GitRev(RevType.LOCAL) })
    local bufnr = await(file:create_buffer())
    eq({ "unchanged" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    eq(true, vim.bo[bufnr].modifiable)
    eq(nil, file.submodule)
    file:destroy(true)
  end))

  it("stages and unstages only the gitlink, leaving submodule files alone", function()
    write(module .. "/file.txt", { "unstaged content" })
    eq(true, adapter:add_files({ "module with spaces" }))
    eq({ sha = latest, dirty = false }, adapter:get_gitlink("module with spaces", GitRev(RevType.STAGE, 0)))
    eq({ " M file.txt" }, git(module, "status", "--porcelain"))
    eq(true, adapter:reset_files({ "module with spaces" }))
    eq({ sha = new, dirty = false }, adapter:get_gitlink("module with spaces", GitRev(RevType.STAGE, 0)))
    eq({ " M file.txt" }, git(module, "status", "--porcelain"))
  end)

  it("opens exact historical endpoints in a new tab without changing cwd", function()
    local cwd = vim.fn.getcwd()
    local view = open({ base .. ".." .. head, "-C" .. parent })
    local tab = view.tabpage
    local child = open_submodule()
    assert(child ~= view)
    eq(old, child.left.commit)
    eq(new, child.right.commit)
    eq(utils.path:normalize(module), utils.path:normalize(child.adapter.ctx.toplevel))
    eq(true, vim.api.nvim_tabpage_is_valid(tab))
    eq(cwd, vim.fn.getcwd())
    eq({}, errors)
  end)

  it("opens the index reference against the actual submodule worktree", function()
    local view = open({ "-C" .. parent })
    local child = open_submodule()
    assert(child ~= view)
    eq(new, child.left.commit)
    eq(RevType.LOCAL, child.right.type)
    eq({}, errors)
  end)

  it("opens staged references rather than the submodule's current HEAD", function()
    git(parent, "add", "--", "module with spaces")
    git(module, "checkout", "--quiet", old)
    local view = open({ "-C" .. parent })
    local staged = view.files.staged[1]
    view:set_file(staged, true, true)
    assert(vim.wait(10000, function() return view.cur_entry == staged and staged.opened end, 10))
    local child = open_submodule()
    assert(child ~= view)
    eq(new, child.left.commit)
    eq(latest, child.right.commit)
    eq({}, errors)
  end)

  it("opens the referenced comparison from file history", function()
    local view = lib.file_history(nil, { "-C" .. parent, "--range=" .. base .. ".." .. head })
    assert(view)
    view:open()
    assert(vim.wait(10000, function() return view.cur_entry and view.cur_entry.opened end, 10))
    local child = open_submodule()
    assert(child ~= view)
    eq(old, child.left.commit)
    eq(new, child.right.commit)
    eq({}, errors)
  end)

  it("allows drilling into nested submodules without flattening either parent", function()
    local nested = module .. "/nested"
    init(nested)
    write(nested .. "/nested.txt", { "before" })
    local nested_old = commit(nested, "nested old")
    git(module, "submodule", "add", "--quiet", "../nested-source", "nested")
    local module_old = commit(module, "add nested")
    local parent_old = commit(parent, "add nested reference")
    write(nested .. "/nested.txt", { "after" })
    local nested_new = commit(nested, "nested new")
    local module_new = commit(module, "bump nested")
    local parent_new = commit(parent, "bump module")
    local view = open({ parent_old .. ".." .. parent_new, "-C" .. parent })
    local child = open_submodule()
    eq(module_old, child.left.commit)
    eq(module_new, child.right.commit)
    eq("nested", child.cur_entry.path)
    local grandchild = open_submodule()
    eq(nested_old, grandchild.left.commit)
    eq(nested_new, grandchild.right.commit)
    eq("nested.txt", grandchild.cur_entry.path)
    eq(true, vim.api.nvim_tabpage_is_valid(view.tabpage))
    eq(true, vim.api.nvim_tabpage_is_valid(child.tabpage))
    eq({}, errors)
  end)

  it("refreshes the local SHA after the submodule checkout changes", function()
    local view = open({ "-C" .. parent })
    local file = view.cur_entry.layout.b.file
    eq({
      "Subproject commit " .. latest,
      "",
      "Press gs to open the submodule diff in a new tab.",
    }, vim.api.nvim_buf_get_lines(file.bufnr, 0, -1, false))
    git(module, "checkout", "--quiet", old)
    local finished = false
    view:update_files(function(err)
      eq(nil, err)
      finished = true
    end)
    assert(vim.wait(10000, function() return finished and file:is_valid() end, 10))
    eq({
      "Subproject commit " .. old,
      "",
      "Press gs to open the submodule diff in a new tab.",
    }, vim.api.nvim_buf_get_lines(file.bufnr, 0, -1, false))
    eq({}, errors)
  end)

  it("shows references but refuses to enter uninitialized submodules", function()
    git(parent, "submodule", "deinit", "--force", "--", "module with spaces")
    eq({ sha = new, dirty = false }, adapter:get_gitlink("module with spaces", GitRev(RevType.STAGE, 0)))
    local view = open({ base .. ".." .. head, "-C" .. parent })
    actions.open_submodule()
    eq(view, lib.get_current_view())
    eq(1, #errors)
    assert(errors[1]:find("not initialized", 1, true))
  end)

  it("uses an empty tree for newly added references", function()
    local view = open({ base .. "^!", "-C" .. parent, "--selected-file=" .. module })
    local child = open_submodule()
    assert(child ~= view)
    eq(GitRev.NULL_TREE_SHA, child.left.commit)
    eq(old, child.right.commit)
    eq({}, errors)
  end)

  it("uses an empty tree for deleted references", function()
    git(parent, "rm", "--quiet", "--force", "module with spaces")
    local removed = commit(parent, "remove")
    git(parent, "checkout", head, "--", ".gitmodules", "module with spaces")
    git(parent, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--", "module with spaces")
    local view = open({ head .. ".." .. removed, "-C" .. parent, "--selected-file=" .. module })
    local child = open_submodule()
    assert(child ~= view)
    eq(new, child.left.commit)
    eq(GitRev.NULL_TREE_SHA, child.right.commit)
    eq({}, errors)
  end)

  it("reports unavailable referenced commits instead of opening another repository", function()
    local missing = string.rep("a", 40)
    git(parent, "update-index", "--cacheinfo", "160000," .. missing .. ",module with spaces")
    local view = open({ "-C" .. parent })
    actions.open_submodule()
    eq(view, lib.get_current_view())
    eq(1, #errors)
    assert(errors[1]:find("unavailable", 1, true))
  end)

  it("renders all conflict stages read-only and refuses ambiguous drill-down", function()
    git(parent, "update-index", "--force-remove", "--", "module with spaces")
    local input = table.concat({
      "160000 " .. old .. " 1\tmodule with spaces",
      "160000 " .. new .. " 2\tmodule with spaces",
      "160000 " .. latest .. " 3\tmodule with spaces",
      "",
    }, "\n")
    vim.fn.system({ "git", "-C", parent, "update-index", "--index-info" }, input)
    eq(0, vim.v.shell_error)
    local view = open({ "-C" .. parent })
    eq("U", view.cur_entry.status)
    for _, file in ipairs(view.cur_entry.layout:files()) do
      eq(false, vim.bo[file.bufnr].modifiable)
      assert(vim.api.nvim_buf_get_lines(file.bufnr, 0, 1, false)[1]:match("^Subproject commit "))
    end
    actions.open_submodule()
    eq(view, lib.get_current_view())
    eq(1, #errors)
    assert(errors[1]:find("conflicting reference", 1, true))
  end)
end)
