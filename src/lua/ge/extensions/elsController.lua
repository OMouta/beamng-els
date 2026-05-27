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

local function onUiChangedState(state)
  if state == "menu.mainmenu" then
    local actions = extensions.core_input_actions and extensions.core_input_actions.getActiveActions()
    if actions and not actions.els_lights_stage_up then
      Lua:requestReload()
    end
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onUiChangedState = onUiChangedState
M.registerInputCategory = registerInputCategory

return M
