local M = {}

local function registerInputCategory()
  if not core_input_categories then
    return
  end

  core_input_categories.els_controller = core_input_categories.els_controller or {
    order = 2.1,
    icon = "warning",
    title = "ELS Controller",
    desc = "Emergency lighting and siren controls"
  }
end

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
