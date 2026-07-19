-- projects.yazi - save/load tab layouts as named projects
require("projects"):setup({
    last = {
        update_after_save = true,
        update_after_load = true,
    },
    notify = {
        enable = true,
        title = "Projects",
        timeout = 3,
        level = "info",
    },
})

-- bbm.yazi — optional (plugin + bbm binary must exist on this host)
local bbm_ok, bbm = pcall(require, "bbm")
if bbm_ok then
    local bbm_bin = os.getenv("BBM_BIN") or "/usr/bin/bbm"
    local rclone_bin = os.getenv("RCLONE_BIN") or "/usr/bin/rclone"
    bbm:setup({
        prefix = "bu/",
        browse_prefix = "bu/",
        bbm_bin = bbm_bin,
        rclone_bin = rclone_bin,
        mount = {
            remote = "lsybb0:j4y-bu",
            path = "~/mnt/j4y-bu",
            start_in = "bu",
            cache_mode = "full",
        },
    })
end

-- DuckDB plugin configuration (disabled for yazi 0.4.2 compatibility)
-- require("duckdb"):setup({ ... })
