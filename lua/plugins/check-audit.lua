return {
  {
    "neovim/nvim-lspconfig",
    opts = function()
      -- Create a namespace for our custom diagnostics
      local ns = vim.api.nvim_create_namespace("check_audit")

      -- Store the results buffer
      local results_bufnr = nil

      -- Function to parse machine-readable svelte-check output
      local function parse_audit_output(output)
        local qf_items = {}
        local diagnostics = {}
        local lines = vim.split(output, "\n")
        local in_output_section = false

        for i, line in ipairs(lines) do
          -- Check for START marker
          if line:match("%d+ START") then
            in_output_section = true
          -- Check for COMPLETED marker
          elseif line:match("%d+ COMPLETED") then
            in_output_section = false
          -- Process lines between START and COMPLETED
          elseif in_output_section and line ~= "" then
            -- Parse JSON line from machine-readable output
            local ok, json_data = pcall(vim.json.decode, line)
            if ok and json_data and json_data.filename then
              local severity_level = vim.diagnostic.severity.INFO
              local qf_type = "I"

              -- Map type to severity
              if json_data.type == "ERROR" then
                severity_level = vim.diagnostic.severity.ERROR
                qf_type = "E"
              elseif json_data.type == "WARNING" then
                severity_level = vim.diagnostic.severity.WARN
                qf_type = "W"
              elseif json_data.type == "HINT" then
                severity_level = vim.diagnostic.severity.HINT
                qf_type = "I"
              end

              -- Build diagnostic text
              local text = string.format("[%s] %s", json_data.type or "INFO", json_data.text or "")

              -- Add to quickfix list with proper file location
              table.insert(qf_items, {
                filename = json_data.filename,
                lnum = json_data.start and json_data.start.line or 1,
                col = json_data.start and json_data.start.character or 1,
                text = text,
                type = qf_type,
              })

              -- Add to diagnostics for results buffer
              if results_bufnr then
                table.insert(diagnostics, {
                  bufnr = results_bufnr,
                  lnum = i - 1, -- 0-indexed
                  col = 0,
                  severity = severity_level,
                  source = "check-audit",
                  message = string.format(
                    "%s:%d:%d %s",
                    json_data.filename,
                    json_data.start and json_data.start.line or 1,
                    json_data.start and json_data.start.character or 1,
                    text
                  ),
                })
              end
            end
          end
        end

        return qf_items, diagnostics
      end

      -- Create the CheckAudit command
      vim.api.nvim_create_user_command("CheckAudit", function()
        -- Show a message that we're running the check
        vim.notify("Running pnpm audit check...", vim.log.levels.INFO)

        local stdout_data = {}
        local stderr_data = {}

        -- Run the command asynchronously
        vim.fn.jobstart("pnpm -F audit run check:machine", {
          stdout_buffered = true,
          stderr_buffered = true,
          on_stdout = function(_, data)
            if data then
              vim.list_extend(stdout_data, data)
            end
          end,
          on_stderr = function(_, data)
            if data then
              vim.list_extend(stderr_data, data)
            end
          end,
          on_exit = function(_, exit_code)
            -- Combine stdout and stderr
            local all_output = {}
            vim.list_extend(all_output, stdout_data)
            vim.list_extend(all_output, stderr_data)

            local output = table.concat(all_output, "\n")

            -- Create or reuse a scratch buffer for results
            if not results_bufnr or not vim.api.nvim_buf_is_valid(results_bufnr) then
              results_bufnr = vim.api.nvim_create_buf(false, true)
              vim.api.nvim_buf_set_name(results_bufnr, "CheckAudit Results")
              vim.api.nvim_set_option_value("buftype", "nofile", { buf = results_bufnr })
              vim.api.nvim_set_option_value("filetype", "checkaudit", { buf = results_bufnr })
            end

            -- Set the output in the buffer
            vim.api.nvim_buf_set_lines(results_bufnr, 0, -1, false, all_output)

            -- Parse output and create diagnostics
            local qf_items, diagnostics = parse_audit_output(output)

            -- Clear previous diagnostics
            vim.diagnostic.reset(ns, results_bufnr)

            -- Set new diagnostics
            if #diagnostics > 0 then
              vim.diagnostic.set(ns, results_bufnr, diagnostics, {})
            end

            -- Set quickfix list
            vim.fn.setqflist({}, "r", { title = "CheckAudit results", items = qf_items })

            -- Show notification and open results
            if exit_code == 0 then
              vim.notify("✓ Audit check passed!", vim.log.levels.INFO)
            else
              vim.notify("✗ Audit check found issues (exit code: " .. exit_code .. ")", vim.log.levels.WARN)
            end

            -- Open Trouble if available, otherwise open quickfix
            -- local has_trouble, trouble = pcall(require, "trouble")
            -- if has_trouble then
            --   trouble.open("quickfix")
            -- else
            vim.cmd("copen")
            -- end

            -- Also open the results buffer in a split
            vim.cmd("split")
            vim.api.nvim_set_current_buf(results_bufnr)
          end,
        })
      end, {
        desc = "Run pnpm audit check and show results in diagnostics",
      })
    end,
  },
}
