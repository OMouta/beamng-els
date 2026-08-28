local M = {}

local function registerInputCategory()
  if core_input_categories then
    core_input_categories.els_controller = {
      desc = "Emergency lighting and siren controls",
      order = 1.8,
      title = "ELS Controller",
      icon = "warning"
    }
  end
end

registerInputCategory()

local function onExtensionLoaded()
  registerInputCategory()
  log("I", "elsController", "ELS Controller GE extension loaded")
end

M.onExtensionLoaded = onExtensionLoaded
M.registerInputCategory = registerInputCategory

return M
