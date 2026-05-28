local M = {}

local activeSiren = 0
local activeDualSiren = 0
local dualModifierHeld = false
local sirenSources = {}
local dualSirenSources = {}
local manualSource = nil
local manualLoadedPart = nil
local sirenCatalogById = nil
local sirenNamesById = nil
local activeConfigInfo = nil
local loadedPartSirens = {}
local controllerInstalled = false
local lightbarModeChoices = nil
local feedbackSources = {}
local stopSiren
local stopDualSiren
local stopAllSirens
local playSiren
local stopManual
local normalizeLightbarState
local lastObservedLightbarState = nil
local warned = {}

local config = {
  lights = {
    stages = nil
  },
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

local function ensureStockLightbarElectrics(values)
  values = values or ensureElectricsValues()

  local names = {
    "lightbar_L1", "lightbar_L2", "lightbar_L3", "lightbar_L4",
    "lightbar_R1", "lightbar_R2", "lightbar_R3", "lightbar_R4",
    "lightbar_A1", "lightbar_A2", "lightbar_A3", "lightbar_A4",
    "lightbar_B1", "lightbar_B2", "lightbar_B3", "lightbar_B4"
  }

  for _, name in ipairs(names) do
    values[name] = values[name] or 0
  end
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

local function safePlaySfxOnce(name, nodeRef, volume, pitch)
  if not name or not nodeRef or not obj or not obj.playSFXOnce then
    return false
  end

  local ok, err = pcall(function()
    obj:playSFXOnce(name, nodeRef, volume or 1, pitch or 1)
  end)
  if not ok then
    warnOnce("sfx_once_" .. tostring(name), "Unable to play ELS one-shot sound: " .. tostring(err))
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
  config.lights = config.lights or {}
  if config.lights.maxStage then
    return config.lights.maxStage
  end

  if type(config.lights.stages) == "table" then
    return math.max(#config.lights.stages - 1, 0)
  end

  return 1
end

local function getLightStageConfig(stage)
  config.lights = config.lights or {}
  local stages = config.lights.stages or {}
  local stageConfig = stages[stage + 1] or stages[tostring(stage)]

  if type(stageConfig) == "table" then
    return stageConfig
  end

  return {
    label = tostring(stageConfig or ("Stage " .. stage)),
    modeIndex = stage
  }
end

local function getModeIndexForStage(stage)
  stage = normalizeLightbarState(stage)
  local stageConfig = getLightStageConfig(stage)
  local modeIndex = stageConfig.modeIndex or stageConfig.index or stageConfig.lightbarMode or stageConfig.lightbarStage or stageConfig.mode or stageConfig.value
  return math.max(normalizeLightbarState(modeIndex ~= nil and modeIndex or stage), 1)
end

local function addLightbarModesFromConfig(choicesByIndex, controllerName, controllerConfig)
  if type(controllerConfig) ~= "table" or type(controllerConfig.modes) ~= "table" then
    return
  end

  for index, row in ipairs(controllerConfig.modes) do
    if index > 1 and type(row) == "table" then
      local modeName = row[1]
      if modeName and modeName ~= "" then
        local modeIndex = index - 1
        local choice = choicesByIndex[modeIndex]
        if not choice then
          choicesByIndex[modeIndex] = {
            index = modeIndex,
            label = tostring(modeName),
            controllers = { controllerName }
          }
        elseif not choice.label:find(tostring(modeName), 1, true) then
          choice.label = choice.label .. " / " .. tostring(modeName)
          table.insert(choice.controllers, controllerName)
        end
      end
    end
  end
end

local function collectLightbarModesFromNode(node, choicesByIndex, seen)
  if type(node) ~= "table" or seen[node] then
    return
  end
  seen[node] = true

  local controllerRows = node.controller
  if type(controllerRows) == "table" then
    for _, row in ipairs(controllerRows) do
      local controllerName = type(row) == "table" and row[1]
      if controllerName == "lightbar" or (type(controllerName) == "string" and controllerName:find("lightbar", 1, true)) then
        addLightbarModesFromConfig(choicesByIndex, controllerName, row[2] or node[controllerName])
      end
    end
  end

  for _, child in pairs(node) do
    collectLightbarModesFromNode(child, choicesByIndex, seen)
  end
end

local function getLightbarModeChoices()
  if lightbarModeChoices then
    return lightbarModeChoices
  end

  local choicesByIndex = {}
  collectLightbarModesFromNode(v and v.data, choicesByIndex, {})

  lightbarModeChoices = {}
  for index, choice in pairs(choicesByIndex) do
    table.insert(lightbarModeChoices, choice)
  end
  table.sort(lightbarModeChoices, function(a, b) return a.index < b.index end)

  return lightbarModeChoices
end

local function getSirenStage()
  config.lights = config.lights or {}
  return normalizeLightbarState(config.lights.sirenStage or getMaxStage())
end

local function getCurrentElsStage(values)
  values = values or ensureElectricsValues()
  if values.elsLightsStage ~= nil then
    return math.min(normalizeLightbarState(values.elsLightsStage), getMaxStage())
  end

  return values.lightbar and values.lightbar > 0 and getSirenStage() or 0
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

local function isEmptySound(path)
  return not path or path == "" or path:lower():find("empty%.ogg", 1) ~= nil
end

local function resolveSoundPath(path, warningKey, displayName)
  if not path or path == "" or path:sub(1, 6) == "event:" then
    return path
  end

  if FS:fileExists(path) then
    return path
  end

  if not path:match("%.[^/\\%.]+$") then
    local extensions = { ".wav", ".ogg", ".mp3" }
    for _, extension in ipairs(extensions) do
      local candidate = path .. extension
      if FS:fileExists(candidate) then
        return candidate
      end
    end
  end

  warnOnce(warningKey, "Unable to verify sound path for " .. tostring(displayName) .. "; trying BeamNG source as-is: " .. tostring(path))
  return path
end

local function getNoFadeSirenData(entry)
  if type(entry) ~= "table" or type(entry.controller) ~= "table" then
    return nil
  end

  -- General_Cool/DaddelZeit no-fade parts keep the real siren path in
  -- controller data while the soundscape points at empty.ogg.
  for _, row in ipairs(entry.controller) do
    local controllerName = type(row) == "table" and row[1]
    local controllerData = controllerName and entry[controllerName]
    if type(controllerData) == "table" and controllerData.sirenPath and controllerData.sirenPath ~= "" then
      return {
        source = controllerData.sirenPath,
        stopPath = controllerData.sirenStopPath,
        stopName = controllerData.internalSirenStopName,
        volume = controllerData.sirenVolume,
        pitch = controllerData.sirenPitch,
        noFade = true
      }
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
          local noFadeData = getNoFadeSirenData(entry)
          if noFadeData and isEmptySound(source) then
            source = noFadeData.source
          end

          if source and source ~= "" then
            catalog[id] = {
              id = id,
              name = name,
              source = source,
              stopPath = noFadeData and noFadeData.stopPath or nil,
              stopName = noFadeData and noFadeData.stopName or nil,
              volume = noFadeData and noFadeData.volume or nil,
              pitch = noFadeData and noFadeData.pitch or nil,
              noFade = noFadeData and noFadeData.noFade or false
            }
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

local function buildLightStageCatalog()
  local catalog = {}
  local files = FS:findFiles("/vehicles/common/sounds/", "*.jbeam", -1, true, false) or {}

  for _, file in ipairs(files) do
    local data = jsonReadFile(file)
    if data then
      for id, entry in pairs(data) do
        if type(entry) == "table" and entry.slotType == "els_light_stage_mode" and entry.elsLightStage then
          catalog[id] = {
            id = id,
            name = entry.information and entry.information.name or id,
            modeIndex = entry.elsLightStage.modeIndex or entry.elsLightStage.index or entry.elsLightStage.mode or entry.elsLightStage.value or 1
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
    stopAllSirens()
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

local function applyPartSelectedLightStages()
  config.lights = config.lights or {}

  local lightStageCatalog = buildLightStageCatalog()
  local stages = {
    { label = "OFF", modeIndex = 1 }
  }
  local hasConfiguredStage = false

  for stage = 1, 3 do
    local selectedPart = getSelectedPart("els_light_stage_" .. stage)
    local selectedStage = selectedPart and lightStageCatalog[selectedPart]
    if selectedStage then
      stages[stage + 1] = {
        label = "STAGE " .. stage,
        modeIndex = selectedStage.modeIndex
      }
      hasConfiguredStage = true
    end
  end

  if hasConfiguredStage then
    for stage = 1, 3 do
      stages[stage + 1] = stages[stage + 1] or {
        label = "STAGE " .. stage,
        modeIndex = stage
      }
    end
    config.lights.stages = stages
    config.lights.sirenStage = 3
  else
    config.lights.stages = nil
    config.lights.sirenStage = nil
  end
end

local function applyPartSelectedSirens()
  if not updateControllerInstalled() then
    return
  end

  config.sirens = config.sirens or {}
  applyPartSelectedFeedback()
  applyPartSelectedLightStages()

  for index = 1, 4 do
    local selectedPart = getSelectedSirenPart(index)
    if selectedPart and selectedPart ~= "" and config.sirens[index] and loadedPartSirens[index] ~= selectedPart then
      if activeSiren == index then
        stopSiren()
      end
      if activeDualSiren == index then
        stopDualSiren()
      end

      local oldSource = sirenSources[index]
      if oldSource then
        safeDeleteSource(oldSource, "siren_" .. index)
        sirenSources[index] = nil
      end

      local oldDualSource = dualSirenSources[index]
      if oldDualSource then
        safeDeleteSource(oldDualSource, "dual_siren_" .. index)
        dualSirenSources[index] = nil
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

local function getFrontCenterNodeRef()
  local nodes = v and v.data and v.data.nodes
  local fallbackRef = getRefNode()

  if not nodes then
    return fallbackRef
  end

  local centerNodes = {}
  local minY = math.huge
  local maxY = -math.huge

  for index, node in ipairs(nodes) do
    local x = node.pos and (node.pos.x or node[1]) or node[1]
    local y = node.pos and (node.pos.y or node[2]) or node[2]
    if x and y and math.abs(x) < 0.05 then
      table.insert(centerNodes, { ref = node.ref or node.cid or node.id or index, y = y })
      minY = math.min(minY, y)
      maxY = math.max(maxY, y)
    end
  end

  if #centerNodes == 0 then
    return fallbackRef
  end

  local targetY = minY + 0.15 * (maxY - minY)
  local bestNode = centerNodes[1]
  local bestDist = math.abs(bestNode.y - targetY)

  for _, node in ipairs(centerNodes) do
    local dist = math.abs(node.y - targetY)
    if dist < bestDist then
      bestNode = node
      bestDist = dist
    end
  end

  return bestNode.ref
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

normalizeLightbarState = function(stage)
  stage = math.floor(tonumber(stage) or 0)
  if stage < 0 then
    return 0
  end

  return stage
end

local function applyLightStageValues(stage)
  stage = normalizeLightbarState(stage)
  local values = ensureElectricsValues()
  ensureStockLightbarElectrics(values)

  values.elsLightsStage = stage
  values.elsLightbarModeIndex = stage > 0 and getModeIndexForStage(stage) or 0
  values.lightbarSignal = stage > 0 and 1 or 0
  values.emergencyLights = stage > 0 and 1 or 0
end

local function setLightbarSignal(enabled)
  local signal = enabled and 1 or 0
  if electrics and electrics.set_lightbar_signal then
    electrics.set_lightbar_signal(signal)
  end

  ensureElectricsValues().lightbar = signal
end

local function getLightbarController()
  if not controller then
    return nil
  end

  if controller.getControllersByType then
    local ok, lightbars = pcall(function()
      return controller.getControllersByType("lightbar")
    end)
    if ok and type(lightbars) == "table" and next(lightbars) then
      return lightbars
    end
  end

  if controller.getController then
    local names = { "lightbar", "lightbar_rear", "lightbar_front" }
    for _, name in ipairs(names) do
      local ok, lightbar = pcall(function()
        return controller.getController(name)
      end)
      if ok and lightbar and lightbar.setModeIndex then
        return { lightbar }
      end
    end
  end

  return nil
end

local function setLightbarModeIndex(modeIndex)
  local lightbars = getLightbarController()
  if not lightbars then
    warnOnce("missing_lightbar_controller", "Unable to set ELS lightbar mode because no compatible lightbar controller was found")
    return
  end

  for _, lightbar in pairs(lightbars) do
    if lightbar and lightbar.setModeIndex then
      local ok, err = pcall(function()
        lightbar.setModeIndex(modeIndex)
      end)
      if not ok then
        warnOnce("set_lightbar_mode_" .. tostring(modeIndex), "Unable to set ELS lightbar mode index " .. tostring(modeIndex) .. ": " .. tostring(err))
      end
    end
  end
end

local function setVehicleLightbarState(stage)
  stage = math.min(normalizeLightbarState(stage), getMaxStage())

  setLightbarSignal(stage > 0)
  if stage > 0 and getMaxStage() > 1 then
    setLightbarModeIndex(getModeIndexForStage(stage))
  end

  applyLightStageValues(stage)
  lastObservedLightbarState = stage > 0 and 1 or 0
end

local function createSirenSource(index, role, targetSources)
  applyPartSelectedSirens()

  if not controllerInstalled then
    return nil
  end

  if targetSources[index] then
    return targetSources[index]
  end

  local siren = config.sirens[index]
  if not siren then
    return nil
  end

  sirenCatalogById = sirenCatalogById or buildSirenCatalog()

  local entry = sirenCatalogById[siren.soundscapeId]
  if not entry then
    warnOnce("missing_" .. role .. "_soundscape_" .. tostring(siren.soundscapeId), "Missing siren soundscape: " .. tostring(siren.soundscapeId))
    return nil
  end

  local path = resolveSoundPath(entry.source, "unverified_" .. role .. "_sound_" .. tostring(siren.soundscapeId), entry.name)

  local refNode = getFrontCenterNodeRef()
  if not refNode then
    return nil
  end

  local profileName = "els_" .. role .. "_" .. index .. "_" .. tostring(siren.soundscapeId) .. "_" .. obj:getID()
  local ok, source = pcall(function()
    return obj:createSFXSource2(path, "AudioDefaultLoop3D", profileName, refNode, 0)
  end)
  if not ok or not source then
    warnOnce("create_" .. role .. "_" .. tostring(siren.soundscapeId), "Unable to create ELS siren source for " .. tostring(siren.soundscapeId) .. ": " .. tostring(source))
    return nil
  end

  local stopName = nil
  local stopPath = resolveSoundPath(entry.stopPath, "unverified_" .. role .. "_stop_" .. tostring(siren.soundscapeId), entry.name .. " stop")
  if stopPath and stopPath ~= "" and stopPath:sub(1, 6) ~= "event:" then
    stopName = entry.stopName or (profileName .. "_stop")
    local stopOk, stopErr = pcall(function()
      obj:createSFXSource(stopPath, "AudioDefault3D", stopName, refNode)
    end)
    if not stopOk then
      warnOnce("create_" .. role .. "_stop_" .. tostring(siren.soundscapeId), "Unable to create ELS siren stop source for " .. tostring(siren.soundscapeId) .. ": " .. tostring(stopErr))
      stopName = nil
    end
  end

  targetSources[index] = {
    id = source,
    label = entry.name,
    volume = entry.volume or siren.volume or 1.0,
    pitch = entry.pitch or 1.0,
    stopName = stopName,
    nodeRef = refNode
  }

  return targetSources[index]
end

local function ensureSirenSource(index)
  return createSirenSource(index, "siren", sirenSources)
end

local function ensureDualSirenSource(index)
  return createSirenSource(index, "dual_siren", dualSirenSources)
end

local function stopSource(source)
  if not source then
    return
  end

  safeSfxCall("stopSFX", source.id)
  safeSfxCall("cutSFX", source.id)
  safePlaySfxOnce(source.stopName, source.nodeRef, source.volume, source.pitch)
end

stopSiren = function()
  if activeSiren == 0 then
    return
  end

  local source = sirenSources[activeSiren]
  stopSource(source)

  ensureElectricsValues().elsSiren = 0
  activeSiren = 0
end

stopDualSiren = function()
  if activeDualSiren == 0 then
    return
  end

  local source = dualSirenSources[activeDualSiren]
  stopSource(source)

  ensureElectricsValues().elsDualSiren = 0
  activeDualSiren = 0
end

stopAllSirens = function()
  stopSiren()
  stopDualSiren()
  if stopManual then
    stopManual()
  end
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
  if not safeSfxCall("setVolumePitch", source.id, source.volume, source.pitch or 1.0) then
    safeSfxCall("setVolume", source.id, source.volume)
  end
  safeSfxCall("playSFX", source.id)
end

local function playDualSiren(index)
  local source = ensureDualSirenSource(index)
  if not source then
    if controllerInstalled and safeFirstPlayerSeated() then
      ui_message("ELS dual siren " .. index .. " is not configured for this vehicle", 3, 0, 1)
    end
    return
  end

  stopDualSiren()
  playFeedback()
  activeDualSiren = index
  ensureElectricsValues().elsDualSiren = index
  safeSfxCall("cutSFX", source.id)
  if not safeSfxCall("setVolumePitch", source.id, source.volume, source.pitch or 1.0) then
    safeSfxCall("setVolume", source.id, source.volume)
  end
  safeSfxCall("playSFX", source.id)
end

local function toggleDualSiren(index)
  if not updateControllerInstalled() then
    return
  end

  if getCurrentElsStage() < getSirenStage() then
    return
  end

  if activeDualSiren == index then
    playFeedback()
    stopDualSiren()
    return
  end

  playDualSiren(index)
end

local function dualModifier(value, filtertype)
  local numericValue = tonumber(value) or 0
  dualModifierHeld = value == true or numericValue > 0.1
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

  local path = resolveSoundPath(entry.source, "unverified_manual_sound_" .. tostring(config.manual.soundscapeId), "manual")

  local refNode = getFrontCenterNodeRef()
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

  local stopName = nil
  local stopPath = resolveSoundPath(entry.stopPath, "unverified_manual_stop_" .. tostring(config.manual.soundscapeId), "manual stop")
  if stopPath and stopPath ~= "" and stopPath:sub(1, 6) ~= "event:" then
    stopName = entry.stopName or (profileName .. "_stop")
    local stopOk, stopErr = pcall(function()
      obj:createSFXSource(stopPath, "AudioDefault3D", stopName, refNode)
    end)
    if not stopOk then
      warnOnce("create_manual_stop_" .. tostring(config.manual.soundscapeId), "Unable to create ELS manual stop source for " .. tostring(config.manual.soundscapeId) .. ": " .. tostring(stopErr))
      stopName = nil
    end
  end

  manualSource = {
    id = source,
    label = entry.name,
    volume = entry.volume or config.manual.volume or 1.0,
    pitch = entry.pitch or 1.0,
    stopName = stopName,
    nodeRef = refNode
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
  stopAllSirens()
  playFeedback()
  ensureElectricsValues().elsManual = 1
  safeSfxCall("cutSFX", source.id)
  if not safeSfxCall("setVolumePitch", source.id, source.volume, source.pitch or 1.0) then
    safeSfxCall("setVolume", source.id, source.volume)
  end
  safeSfxCall("playSFX", source.id)
end

stopManual = function()
  if manualSource then
    safeSfxCall("stopSFX", manualSource.id)
    safeSfxCall("cutSFX", manualSource.id)
    safePlaySfxOnce(manualSource.stopName, manualSource.nodeRef, manualSource.volume, manualSource.pitch)
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

  applyPartSelectedLightStages()
  local currentStage = getCurrentElsStage()
  stage = math.min(normalizeLightbarState(stage), getMaxStage())

  if stage ~= currentStage then
    stopAllSirens()
  end

  setVehicleLightbarState(stage)
end

local function getNextLightStage(direction)
  applyPartSelectedLightStages()
  local values = ensureElectricsValues()
  local currentStage = getCurrentElsStage(values)
  local maxStage = getMaxStage()

  if direction < 0 then
    return currentStage <= 0 and maxStage or currentStage - 1
  end

  return currentStage >= maxStage and 0 or currentStage + 1
end

local function syncFromStockLightbar()
  if not updateControllerInstalled() then
    return
  end

  local values = ensureElectricsValues()
  local stockSignal = normalizeLightbarState(values.lightbar)
  if stockSignal > 1 then
    setLightbarSignal(true)
    stockSignal = 1
  end

  if lastObservedLightbarState == nil then
    lastObservedLightbarState = stockSignal
  end

  if stockSignal == lastObservedLightbarState then
    return
  end

  lastObservedLightbarState = stockSignal
  local stockStage = stockSignal > 0 and getSirenStage() or 0
  applyLightStageValues(stockStage)
  if stockStage > 0 and getMaxStage() > 1 then
    setLightbarModeIndex(getModeIndexForStage(stockStage))
  end

  if stockStage == 0 then
    stopAllSirens()
  elseif stockStage < getSirenStage() and (activeSiren ~= 0 or activeDualSiren ~= 0) then
    stopAllSirens()
  end
end

local function stageUp(value, filtertype)
  if not updateControllerInstalled() then
    return
  end

  setLightStage(getNextLightStage(1))
  playFeedback()
end

local function stageDown(value, filtertype)
  if not updateControllerInstalled() then
    return
  end

  setLightStage(getNextLightStage(-1))
  playFeedback()
end

local function activateSiren(index, value, filtertype)
  if not updateControllerInstalled() then
    return
  end

  if getCurrentElsStage() < getSirenStage() then
    return
  end

  if dualModifierHeld then
    toggleDualSiren(index)
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
  if activeDualSiren == index then
    stopDualSiren()
  end

  local oldSource = sirenSources[index]
  if oldSource then
    safeDeleteSource(oldSource, "siren_" .. index)
    sirenSources[index] = nil
  end

  local oldDualSource = dualSirenSources[index]
  if oldDualSource then
    safeDeleteSource(oldDualSource, "dual_siren_" .. index)
    dualSirenSources[index] = nil
  end

  config.sirens[index].soundscapeId = soundscapeId
end

local function setStageLightbarMode(stage, modeIndex)
  stage = normalizeLightbarState(stage)
  modeIndex = math.max(normalizeLightbarState(modeIndex), 1)
  if stage < 1 then
    return
  end

  config.lights = config.lights or {}
  config.lights.stages = config.lights.stages or {
    { label = "OFF", modeIndex = 1 },
    { label = "STAGE 1", modeIndex = 1 },
    { label = "STAGE 2", modeIndex = 2 },
    { label = "STAGE 3", modeIndex = 3 }
  }
  for stageIndex = 1, stage do
    config.lights.stages[stageIndex + 1] = config.lights.stages[stageIndex + 1] or {
      label = "STAGE " .. stageIndex,
      modeIndex = stageIndex
    }
  end
  config.lights.stages[stage + 1] = {
    label = "STAGE " .. stage,
    modeIndex = modeIndex
  }
  config.lights.sirenStage = math.max(normalizeLightbarState(config.lights.sirenStage or 0), stage)

  if getCurrentElsStage() == stage then
    setLightbarModeIndex(modeIndex)
    applyLightStageValues(stage)
  end
end

local function getConfigInfo()
  return activeConfigInfo
end

local function getVisualizerState()
  updateControllerInstalled()
  applyPartSelectedSirens()
  syncFromStockLightbar()
  local values = ensureElectricsValues()

  local sirens = {}
  for index = 1, 4 do
    local siren = config.sirens[index] or {}
    local selectedPart = getSelectedSirenPart(index)
    local part = selectedPart or siren.soundscapeId
    sirens[index] = {
      id = index,
      active = activeSiren == index,
      dualActive = activeDualSiren == index,
      part = part or "",
      label = getSirenDisplayName(part) or siren.label or part or ("Siren " .. index)
    }
  end

  local lightStages = {}
  for stage = 1, getMaxStage() do
    lightStages[stage] = {
      stage = stage,
      modeIndex = getModeIndexForStage(stage),
      label = getLightStageConfig(stage).label or ("STAGE " .. stage)
    }
  end

  return {
    controllerInstalled = controllerInstalled,
    stage = getCurrentElsStage(values),
    maxStage = getMaxStage(),
    sirenStage = getSirenStage(),
    lightbarModeIndex = values.elsLightbarModeIndex or 0,
    lightbarModes = getLightbarModeChoices(),
    lightStages = lightStages,
    activeSiren = activeSiren,
    activeDualSiren = activeDualSiren,
    dualModifierHeld = dualModifierHeld,
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
  lightbarModeChoices = nil
  sirenCatalogById = buildSirenCatalog()
  local values = ensureElectricsValues()
  lastObservedLightbarState = normalizeLightbarState(values.lightbar)
  applyLightStageValues(lastObservedLightbarState > 0 and getSirenStage() or 0)
  values.elsSiren = values.elsSiren or 0
  values.elsDualSiren = values.elsDualSiren or 0
  values.elsManual = values.elsManual or 0
  log("I", "elsControllerVE", "ELS Controller vehicle extension loaded")
end

local function onReset()
  stopAllSirens()
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
M.stopDualSiren = stopDualSiren
M.stopAllSirens = stopAllSirens
M.toggleDualSiren = toggleDualSiren
M.dualModifier = dualModifier
M.setSiren = setSiren
M.setStageLightbarMode = setStageLightbarMode
M.getConfigInfo = getConfigInfo
M.getVisualizerState = getVisualizerState
M.debugSirenParts = debugSirenParts
M.onExtensionLoaded = onExtensionLoaded
M.onReset = onReset
M.onUpdate = onUpdate

return M
