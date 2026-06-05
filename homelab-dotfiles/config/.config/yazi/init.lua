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

-- DuckDB plugin configuration (disabled for yazi 0.4.2 compatibility)
-- require("duckdb"):setup({
--   mode = "summarized",            -- Default: "summarized" or "standard"
--   cache_size = 500,               -- Default: 500 (number of rows cached in standard mode)
--   row_id = false,                 -- Default: false (true/false/"dynamic")
--   minmax_column_width = 21,       -- Default: 21 (characters displayed in min/max columns)
--   column_fit_factor = 10.0        -- Default: 10.0 (average space each column takes)
-- })
