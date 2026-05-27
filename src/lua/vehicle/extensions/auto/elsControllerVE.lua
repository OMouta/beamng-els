local M = {}

local activeSiren = 0
local sirenSources = {}
local manualSource = nil
local manualLoadedPart = nil
local sirenCatalogById = nil
local sirenNamesById = nil
local activeConfigInfo = nil
local loadedPartSirens = {}
local controllerInstalled = false
local feedbackSources = {}
local stopSiren
local playSiren
local stopManual
local lastObservedLightbarState = nil
local warned = {}

local config = {
  lights = { stages = { "off", "on" } },
  feedback = {
    enabled = true,
    selected = "classic",
    variations = {
      classic = { sound = "art/sound/els_controller/beep_classic.wav", volume = 0.55 },
      high = { sound = "art/sound/els_controller/beep_high.wav", volume = 0.55 }
    }
  },
  sirens = {
    [1] = { label = "80s/90s Police Wail 1", soundscapeId = "soundscape_siren_3", volume = 1.0 },
    [2] = { label = "80s/90s Police Wail 2", soundscapeId = "soundscape_siren_4", volume = 1.0 },
    [3] = { label = "80s/90s Police Yelp 1", soundscapeId = "soundscape_siren_8", volume = 1.0 },
    [4] = { label = "Modern Police Hi-Lo", soundscapeId = "soundscape_siren_7", volume = 1.0 }
  }
}

local function warnOnce(key, message)
  if warned[key] then
    return
  end

  warned[key] = true
  log("W", "elsControllerVE", message)
end

local function ensureElectricsValues()
  if electrics then
    electrics.values = electrics.values or {}
    return electrics.values
  end

  return {}
end

local function safeFirstPlayerSeated()
  return playerInfo and playerInfo.firstPlayerSeated
end

local function safeSfxCall(name, sourceId, ...)
  if not sourceId or not obj or not obj[name] then
    return false
  end

  local args = { ... }
  local ok, err = pcall(function()
    obj[name](obj, sourceId, unpack(args))
  end)
  if not ok then
    warnOnce("sfx_" .. name .. "_" .. tostring(sourceId), "Unable to run " .. name .. " for ELS sound source: " .. tostring(err))
    return false
  end

  return true
end

local function safeDeleteSource(source, key)
  if not source or not source.id or not obj or not obj.deleteSFXSource then
    return
  end

  local ok, err = pcall(function()
    obj:deleteSFXSource(source.id)
  end)
  if not ok then
    warnOnce("delete_" .. tostring(key or source.id), "Unable to delete ELS sound source: " .. tostring(err))
  end
end

local function getVehicleModel()
  return (v and v.data and v.data.model) or (v and v.vehicleDirectory and v.vehicleDirectory:match("/vehicles/([^/]+)")) or "unknown"
end

local function getVehicleConfigName()
  if not v or not v.config or not v.config.partConfigFilename then
    return "default"
  end

  local configName = v.config.partConfigFilename:match("([^/\\]+)%.pc$")
  return configName or "default"
end

local function getConfigCandidates()
  local model = getVehicleModel()
  local configName = getVehicleConfigName()

  return {
    {
      path = "settings/els_controller/vehicles/" .. model .. "/" .. configName .. ".json",
      model = model,
      configName = configName
    },
    {
      path = "settings/els_controller/vehicles/" .. model .. "/default.json",
      model = model,
      configName = "default"
    },
    {
      path = "settings/els_controller/default_config.json",
      model = model,
      configName = "global"
    }
  }
end

local function getMaxStage()
  if config.lights.maxStage then
    return config.lights.maxStage
  end

  if type(config.lights.stages) == "table" then
    return math.max(#config.lights.stages - 1, 0)
  end

  return 1
end

local function getSoundscapeSource(soundscape)
  if type(soundscape) ~= "table" then
    return nil
  end

  for _, row in ipairs(soundscape) do
    if type(row) == "table" and row[1] == "siren" then
      return row[2]
    end
  end

  return nil
end

local function buildSirenCatalog()
  local catalog = {}
  sirenNamesById = {}
  local files = FS:findFiles("/vehicles/common/sounds/", "*.jbeam", -1, true, false) or {}

  for _, file in ipairs(files) do
    local data = jsonReadFile(file)
    if data then
      for id, entry in pairs(data) do
        if type(entry) == "table" and entry.slotType == "soundscape_siren" then
          -- Record the display name for every siren part, even when its audio
          -- source can't be detected, so the UI never has to fall back to ids.
          local name = (entry.information and entry.information.name) or id
          sirenNamesById[id] = name

          local source = getSoundscapeSource(entry.soundscape)
          if source and source ~= "" then
            catalog[id] = { id = id, name = name, source = source }
          end
        end
      end
    end
  end

  return catalog
end

-- Friendly display name for a siren part id (e.g. "Ambulance Wail 1").
local function getSirenDisplayName(partId)
  if not partId or partId == "" then
    return nil
  end

  if not sirenNamesById then
    sirenCatalogById = sirenCatalogById or buildSirenCatalog()
  end

  return sirenNamesById and sirenNamesById[partId] or nil
end

local function buildFeedbackCatalog()
  local catalog = {}
  local files = FS:findFiles("/vehicles/common/sounds/", "*.jbeam", -1, true, false) or {}

  for _, file in ipairs(files) do
    local data = jsonReadFile(file)
    if data then
      for id, entry in pairs(data) do
        if type(entry) == "table" and entry.slotType == "els_feedback_beep" and entry.elsFeedback then
          catalog[id] = {
            id = id,
            name = entry.information and entry.information.name or id,
            sound = entry.elsFeedback.sound,
            volume = entry.elsFeedback.volume or 0.55
          }
        end
      end
    end
  end

  return catalog
end

local function loadConfig()
  for _, candidate in ipairs(getConfigCandidates()) do
    local loadedConfig = jsonReadFile(candidate.path)
    if loadedConfig then
      config = loadedConfig
      activeConfigInfo = candidate
      log("I", "elsControllerVE", "Loaded ELS config: " .. candidate.path)
      return
    end
  end
end

local function findChosenPartInTree(node, slotId)
  if not node then
    return nil
  end

  if node.id == slotId then
    local chosenPartName = node.chosenPartName
    if chosenPartName and chosenPartName ~= "" and chosenPartName ~= "none" then
      return chosenPartName
    end
    return nil
  end

  for _, child in pairs(node.children or {}) do
    local chosenPartName = findChosenPartInTree(child, slotId)
    if chosenPartName then
      return chosenPartName
    end
  end

  return nil
end

local function isPartInTree(node, partName)
  if not node then
    return false
  end

  if node.chosenPartName == partName then
    return true
  end

  for _, child in pairs(node.children or {}) do
    if isPartInTree(child, partName) then
      return true
    end
  end

  return false
end

local function updateControllerInstalled()
  local vehicleConfig = v and v.config or {}
  controllerInstalled = isPartInTree(vehicleConfig.partsTree, "els_controller_siren_bank")

  if not controllerInstalled and vehicleConfig.parts then
    for _, selectedPart in pairs(vehicleConfig.parts) do
      if selectedPart == "els_controller_siren_bank" then
        controllerInstalled = true
        break
      end
    end
  end

  if not controllerInstalled then
    stopSiren()
  end

  return controllerInstalled
end

local function getSelectedPart(slotId)
  local vehicleConfig = v and v.config or {}

  if vehicleConfig.parts then
    local selectedPart = vehicleConfig.parts[slotId]
    if selectedPart and selectedPart ~= "" and selectedPart ~= "none" then
      return selectedPart
    end
  end

  return findChosenPartInTree(vehicleConfig.partsTree, slotId)
end

local function getSelectedSirenPart(index)
  return getSelectedPart("els_siren_" .. index)
end

local function applyPartSelectedFeedback()
  config.feedback = config.feedback or {}

  local selectedPart = getSelectedPart("els_feedback_beep")
  if not selectedPart then
    return
  end

  local feedbackCatalog = buildFeedbackCatalog()
  local selectedFeedback = feedbackCatalog[selectedPart]
  if not selectedFeedback then
    warnOnce("missing_feedback_part_" .. selectedPart, "Missing ELS feedback part: " .. selectedPart)
    return
  end

  config.feedback.beep = {
    sound = selectedFeedback.sound,
    volume = selectedFeedback.volume
  }
  config.feedback.selected = nil
  config.feedback.variations = nil
end

local function applyPartSelectedSirens()
  if not updateControllerInstalled() then
    return
  end

  config.sirens = config.sirens or {}
  applyPartSelectedFeedback()

  for index = 1, 4 do
    local selectedPart = getSelectedSirenPart(index)
    if selectedPart and selectedPart ~= "" and config.sirens[index] and loadedPartSirens[index] ~= selectedPart then
      if activeSiren == index then
        stopSiren()
      end

      local oldSource = sirenSources[index]
      if oldSource then
        safeDeleteSource(oldSource, "siren_" .. index)
        sirenSources[index] = nil
      end

      config.sirens[index].soundscapeId = selectedPart
      config.sirens[index].label = getSirenDisplayName(selectedPart) or selectedPart
      loadedPartSirens[index] = selectedPart
      log("I", "elsControllerVE", "ELS siren " .. index .. " mapped to selected part " .. selectedPart)
    end
  end
end

local function getRefNode()
  local refNodes = v and v.data and v.data.refNodes
  local refNode = refNodes and ((refNodes[0] and refNodes[0].ref) or (refNodes[1] and refNodes[1].ref))
  if not refNode then
    warnOnce("missing_ref_node", "Unable to create ELS sound source because this vehicle has no usable ref node")
  end

  return refNode
end

local function getFeedbackConfig()
  local feedback = config.feedback or {}
  if feedback.enabled == false then
    return nil
  end

  local selected = feedback.selected or "classic"
  local variations = feedback.variations or {}
  return variations[selected] or feedback.beep
end

local function playFeedback()
  if not controllerInstalled then
    return
  end

  local feedback = getFeedbackConfig()
  if not feedback or not feedback.sound or feedback.sound == "" then
    return
  end

  if feedback.sound:sub(1, 6) ~= "event:" and not FS:fileExists(feedback.sound) then
    warnOnce("missing_feedback_sound_" .. feedback.sound, "Missing ELS feedback sound: " .. feedback.sound)
    return
  end

  if not feedbackSources.beep or feedbackSources.beep.sound ~= feedback.sound then
    if feedbackSources.beep then
      safeDeleteSource(feedbackSources.beep, "feedback")
    end

    local refNode = getRefNode()
    if not refNode then
      return
    end

    local ok, sourceId = pcall(function()
      return obj:createSFXSource2(feedback.sound, "AudioDefault3D", "els_feedback_" .. obj:getID(), refNode, 0)
    end)
    if not ok or not sourceId then
      warnOnce("create_feedback_" .. feedback.sound, "Unable to create ELS feedback sound source: " .. tostring(sourceId))
      return
    end

    feedbackSources.beep = {
      sound = feedback.sound,
      id = sourceId
    }
  end

  local source = feedbackSources.beep
  safeSfxCall("cutSFX", source.id)
  safeSfxCall("setVolume", source.id, feedback.volume or 0.55)
  safeSfxCall("playSFX", source.id)
end

local function normalizeLightbarState(stage)
  stage = math.floor(tonumber(stage) or 0)
  if stage < 0 then
    return 0
  end

  return stage
end

local function applyLightStageValues(stage)
  stage = normalizeLightbarState(stage)
  local values = ensureElectricsValues()

  values.elsLightsStage = stage
  values.lightbarSignal = stage
  values.emergencyLights = stage
end

local function setVehicleLightbarState(stage)
  stage = normalizeLightbarState(stage)

  if electrics and electrics.set_lightbar_signal then
    electrics.set_lightbar_signal(stage)
  end

  ensureElectricsValues().lightbar = stage
  applyLightStageValues(stage)
  lastObservedLightbarState = stage
end

local function ensureSirenSource(index)
  applyPartSelectedSirens()

  if not controllerInstalled then
    return nil
  end

  if sirenSources[index] then
    return sirenSources[index]
  end

  local siren = config.sirens[index]
  if not siren then
    return nil
  end

  sirenCatalogById = sirenCatalogById or buildSirenCatalog()

  local entry = sirenCatalogById[siren.soundscapeId]
  if not entry then
    warnOnce("missing_siren_soundscape_" .. tostring(siren.soundscapeId), "Missing siren soundscape: " .. tostring(siren.soundscapeId))
    return nil
  end

  local path = entry.source
  if path:sub(1, 6) ~= "event:" and not FS:fileExists(path) then
    warnOnce("missing_siren_sound_" .. tostring(path), "Missing sound for " .. entry.name .. ": " .. path)
    return nil
  end

  local refNode = getRefNode()
  if not refNode then
    return nil
  end

  local profileName = "els_siren_" .. index .. "_" .. tostring(siren.soundscapeId) .. "_" .. obj:getID()
  local ok, source = pcall(function()
    return obj:createSFXSource2(path, "AudioDefaultLoop3D", profileName, refNode, 0)
  end)
  if not ok or not source then
    warnOnce("create_siren_" .. tostring(siren.soundscapeId), "Unable to create ELS siren source for " .. tostring(siren.soundscapeId) .. ": " .. tostring(source))
    return nil
  end

  sirenSources[index] = {
    id = source,
    label = entry.name,
    volume = siren.volume or 1.0
  }

  return sirenSources[index]
end

stopSiren = function()
  if activeSiren == 0 then
    return
  end

  local source = sirenSources[activeSiren]
  if source then
    safeSfxCall("stopSFX", source.id)
  end

  ensureElectricsValues().elsSiren = 0
  activeSiren = 0
end

playSiren = function(index)
  local source = ensureSirenSource(index)
  if not source then
    if controllerInstalled and safeFirstPlayerSeated() then
      ui_message("ELS siren " .. index .. " is not configured for this vehicle", 3, 0, 1)
    end
    return
  end

  stopSiren()
  playFeedback()
  activeSiren = index
  ensureElectricsValues().elsSiren = index
  safeSfxCall("cutSFX", source.id)
  safeSfxCall("setVolume", source.id, source.volume)
  safeSfxCall("playSFX", source.id)
end

-- The manual tone is a momentary "air-horn" style override: it has its own
-- assignable siren slot, plays while held, and ignores the light stage.
local function ensureManualConfig()
  config.manual = config.manual or {}
  if not config.manual.soundscapeId or config.manual.soundscapeId == "" then
    config.manual.soundscapeId = "soundscape_siren_3"
  end
  config.manual.volume = config.manual.volume or 1.0
  config.manual.label = config.manual.label or "Manual"
end

local function applyManualPart()
  local selectedPart = getSelectedPart("els_siren_manual")
  if selectedPart and selectedPart ~= "" and manualLoadedPart ~= selectedPart then
    if manualSource then
      safeDeleteSource(manualSource, "manual")
      manualSource = nil
    end
    config.manual.soundscapeId = selectedPart
    config.manual.label = getSirenDisplayName(selectedPart) or selectedPart
    manualLoadedPart = selectedPart
  end
end

local function ensureManualSource()
  ensureManualConfig()
  applyManualPart()

  if not controllerInstalled then
    return nil
  end

  if manualSource then
    return manualSource
  end

  sirenCatalogById = sirenCatalogById or buildSirenCatalog()

  local entry = sirenCatalogById[config.manual.soundscapeId]
  if not entry then
    warnOnce("missing_manual_soundscape_" .. tostring(config.manual.soundscapeId), "Missing manual soundscape: " .. tostring(config.manual.soundscapeId))
    return nil
  end

  local path = entry.source
  if path:sub(1, 6) ~= "event:" and not FS:fileExists(path) then
    warnOnce("missing_manual_sound_" .. tostring(path), "Missing sound for manual: " .. path)
    return nil
  end

  local refNode = getRefNode()
  if not refNode then
    return nil
  end

  local profileName = "els_manual_" .. tostring(config.manual.soundscapeId) .. "_" .. obj:getID()
  local ok, source = pcall(function()
    return obj:createSFXSource2(path, "AudioDefaultLoop3D", profileName, refNode, 0)
  end)
  if not ok or not source then
    warnOnce("create_manual_" .. tostring(config.manual.soundscapeId), "Unable to create ELS manual source for " .. tostring(config.manual.soundscapeId) .. ": " .. tostring(source))
    return nil
  end

  manualSource = {
    id = source,
    label = entry.name,
    volume = config.manual.volume or 1.0
  }

  return manualSource
end

local function startManual()
  if not updateControllerInstalled() then
    return
  end

  local source = ensureManualSource()
  if not source then
    if controllerInstalled and safeFirstPlayerSeated() then
      ui_message("ELS manual siren is not configured for this vehicle", 3, 0, 1)
    end
    return
  end

  -- Manual overrides any playing tone and does not require the lights to be on.
  stopSiren()
  playFeedback()
  ensureElectricsValues().elsManual = 1
  safeSfxCall("cutSFX", source.id)
  safeSfxCall("setVolume", source.id, source.volume)
  safeSfxCall("playSFX", source.id)
end

stopManual = function()
  if manualSource then
    safeSfxCall("stopSFX", manualSource.id)
  end
  ensureElectricsValues().elsManual = 0
end

local function manualSiren(value, filtertype)
  local numericValue = tonumber(value) or 0
  if value == true or numericValue > 0.1 then
    startManual()
  else
    stopManual()
  end
end

local function setLightStage(stage)
  if not controllerInstalled then
    return
  end

  setVehicleLightbarState(stage)

  if stage == 0 then
    stopSiren()
  end
end

local function toggleVehicleLightbar()
  local values = ensureElectricsValues()
  local currentStage = values.elsLightsStage or values.lightbar or values.lightbarSignal or 0
  local nextStage = normalizeLightbarState(currentStage) > 0 and 0 or 1

  setLightStage(nextStage)
  playFeedback()
end

local function syncFromStockLightbar()
  if not updateControllerInstalled() then
    return
  end

  local stockStage = normalizeLightbarState(ensureElectricsValues().lightbar)
  if lastObservedLightbarState == nil then
    lastObservedLightbarState = stockStage
  end

  if stockStage == lastObservedLightbarState then
    return
  end

  lastObservedLightbarState = stockStage
  applyLightStageValues(stockStage)

  if stockStage == 0 then
    stopSiren()
    stopManual()
  elseif stockStage == 2 and activeSiren == 0 then
    playSiren(1)
  elseif stockStage < 2 and activeSiren ~= 0 then
    stopSiren()
  end
end

local function stageUp(value, filtertype)
  if not updateControllerInstalled() then
    return
  end

  toggleVehicleLightbar()
end

local function stageDown(value, filtertype)
  if not updateControllerInstalled() then
    return
  end

  toggleVehicleLightbar()
end

local function activateSiren(index, value, filtertype)
  if not updateControllerInstalled() then
    return
  end

  if (ensureElectricsValues().elsLightsStage or 0) == 0 then
    return
  end

  if activeSiren == index then
    playFeedback()
    stopSiren()
    return
  end

  playSiren(index)
end

local function setSiren(index, soundscapeId)
  if not config.sirens[index] then
    return
  end

  if activeSiren == index then
    stopSiren()
  end

  local oldSource = sirenSources[index]
  if oldSource then
    safeDeleteSource(oldSource, "siren_" .. index)
    sirenSources[index] = nil
  end

  config.sirens[index].soundscapeId = soundscapeId
end

local function getConfigInfo()
  return activeConfigInfo
end

local function getVisualizerState()
  syncFromStockLightbar()
  updateControllerInstalled()
  applyPartSelectedSirens()
  local values = ensureElectricsValues()

  local sirens = {}
  for index = 1, 4 do
    local siren = config.sirens[index] or {}
    local selectedPart = getSelectedSirenPart(index)
    local part = selectedPart or siren.soundscapeId
    sirens[index] = {
      id = index,
      active = activeSiren == index,
      part = part or "",
      label = getSirenDisplayName(part) or siren.label or part or ("Siren " .. index)
    }
  end

  return {
    controllerInstalled = controllerInstalled,
    stage = values.elsLightsStage or values.lightbar or 0,
    activeSiren = activeSiren,
    manualActive = (values.elsManual or 0) > 0,
    sirens = sirens
  }
end

local function debugSirenParts()
  local selected = {}
  for index = 1, 4 do
    selected[index] = getSelectedSirenPart(index) or "<default>"
  end

  local data = {
    controllerInstalled = updateControllerInstalled(),
    selected = selected
  }

  log("I", "elsControllerVE", "ELS controller state: " .. dumps(data))
  return data
end

local function onExtensionLoaded()
  loadConfig()
  ensureManualConfig()
  updateControllerInstalled()
  applyPartSelectedSirens()
  sirenCatalogById = buildSirenCatalog()
  local values = ensureElectricsValues()
  lastObservedLightbarState = normalizeLightbarState(values.lightbar)
  applyLightStageValues(lastObservedLightbarState)
  values.elsSiren = values.elsSiren or 0
  values.elsManual = values.elsManual or 0
  log("I", "elsControllerVE", "ELS Controller vehicle extension loaded")
end

local function onReset()
  stopSiren()
  stopManual()
  setVehicleLightbarState(0)
end

local function onUpdate(dt)
  syncFromStockLightbar()
end

M.stageUp = stageUp
M.stageDown = stageDown
M.activateSiren = activateSiren
M.manualSiren = manualSiren
M.startManual = startManual
M.stopManual = stopManual
M.stopSiren = stopSiren
M.setSiren = setSiren
M.getConfigInfo = getConfigInfo
M.getVisualizerState = getVisualizerState
M.debugSirenParts = debugSirenParts
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.onUpdate = onUpdate

return M
