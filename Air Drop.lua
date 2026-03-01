-- Air Drop 0.3 By Burning Skies MYTH
-- Pure DCS Lua
-- Description: This script adds Air Drop radio commands that will spawn C-130's and deliver units to a designated
--              map marker to drop cargo. You can also spawn and track the c130 supply containers dropped by players and use 
--              them as "materials" to "manufacture" vehicles at the drop zone using the map marker "make {{unit}}" command.

-- To use this script:
-- 1. Place it in your mission's MISSION SCRIPTS folder
-- 2. Load the script in the mission editor using the "Do Script" action

-- then in-game:
-- Use the radio menu to call in drops
-- Place map markers named "dp-alpha", "dp-bravo", etc. for drop zones (these are generated dynamically)
-- or
-- Spawn cargo containers using the C-130J mod (or any static object with the correct name pattern) and fly and drop them from the c130j
-- then use "make tank", "make apc", or "make humvee" map markers to spawn vehicles from nearby landed crates.

-- 5. Get good.


-- =====================================================================================
-- CONFIG (Editable Section)
-- =====================================================================================

local CONFIG = {
    debug = true,  -- Set to false to disable debug messages
    production_mode = false,  -- Set to true to reduce overhead and debug output

    -- Aircraft settings
    aircraft_type = "C-130",  -- Aircraft type to spawn
    aircraft_fallback = "KC130",  -- Fallback if C-130 not available
    spawn_altitude = 1000,    -- Altitude in meters (approximately 3280 feet)
    cruise_speed = 130,       -- Speed in m/s (approximately 250 knots)

    -- Timing settings
    scan_frequency = 3,       -- How often to scan for containers/commands (seconds)
    monitor_frequency = 2,    -- How often to monitor container status (seconds)

    -- Cargo settings for NPC air drops
    cargo_types = {
        ["Tank"] = {
            name = "M1 Abrams Tank",
            type = "M-1 Abrams",
            mass = 60000,  -- Mass in kg for an M1 Abrams
            category = "vehicle",
            materials_required = 2
        },
        ["APC"] = {
            name = "M113 APC",
            type = "M-113",
            mass = 11000,  -- Mass in kg for an M113
            category = "vehicle",
            materials_required = 2
        },
        ["Humvee"] = {
            name = "M1025 HMMWV",
            type = "Hummer",
            mass = 2400,   -- Mass in kg for a HMMWV
            category = "vehicle",
            materials_required = 2
        },
        ["FARP"] = {
            name = "Forward Arming and Refueling Point",
            type = "FARP",
            mass = 50000,  -- Mass in kg for FARP equipment
            category = "static",
            materials_required = 4
        }
    }
}


-- =====================================================================================
-- DEBUG FUNCTIONS
-- =====================================================================================

-- Debug function that outputs to both log and players if debug is enabled
local function debugMsg(message, force)
    env.info("[Air Drop] " .. message)
    if (CONFIG.debug and not CONFIG.production_mode) or force then
        trigger.action.outText(message, 10)
    end
end


-- =====================================================================================
-- STATE MANAGEMENT
-- =====================================================================================

local AirDropState = {
    initialized = false,
    groupCounter = 0,
    makeCounter = 0,           -- Counter for manufactured vehicles
    playerCrates = {},         -- Track dropped cargo crates from players: [unitName] = { unit, spawnTime, been_airborne }
    spawnedGroups = {},        -- Track all spawned aircraft groups: [groupName] = { group, spawnTime }
    activeDrops = {},          -- Track active drop missions: [groupName] = { markerName, vehicleType, qty, status, spawnTime }
    pendingDropRequests = {},  -- Store pending drop requests waiting for markers: [markerLabel] = { vehicleType, qty, requestTime }
}


-- =====================================================================================
-- PLAYER CRATE FUNCTIONS
-- =====================================================================================

-- Event handler for unit spawning
local function onEvent(event)
    -- Log all events to see what's happening
    if CONFIG.debug then
        debugMsg("EVENT: Received event ID: " .. (event.id or "nil") .. " (" .. tostring(event.id) .. ")")
    end
    
    -- Check for various spawn-related events
    if event.id == world.event.S_EVENT_BIRTH or 
       event.id == world.event.S_EVENT_UNIT_LOST or
       event.id == world.event.S_EVENT_DEAD or
       event.id == world.event.S_EVENT_PLAYER_ENTER_UNIT then
        
        local unit = event.initiator or event.target
        if unit and unit:isExist() then
            local unitName = unit:getName()
            local unitTypeName = unit:getTypeName()
            
            if event.id == world.event.S_EVENT_BIRTH then
                debugMsg("EVENT: Unit spawned/born - " .. unitName .. " (type: " .. unitTypeName .. ")")
            else
                debugMsg("EVENT: Unit event " .. event.id .. " - " .. unitName .. " (type: " .. unitTypeName .. ")")
            end
            
            -- Check if this is a crate type and not already tracked (only for birth events)
            if event.id == world.event.S_EVENT_BIRTH and isPlayerCrateType(unitTypeName, unitName) and not AirDropState.playerCrates[unitName] then
                -- Add to tracking
                AirDropState.playerCrates[unitName] = {
                    unit = unit,
                    spawnTime = timer.getTime(),
                    been_airborne = false,
                    airborne = false,
                    typeName = unitTypeName,
                    isStatic = true
                }
                
                debugMsg("✓ Player crate detected via event and added to tracking: " .. unitName .. " (type: " .. unitTypeName .. ")")
                debugMsg("Player crate detected: " .. unitName .. " (" .. unitTypeName .. ")")
            end
        end
    end
end

-- Function to check if a static object is a player-spawned container (based on c130_supply.lua)
local function isPlayerCrateType(unitTypeName, unitName)
    if not unitName then 
        return false 
    end
    
    -- Check by name patterns (C-130J mod containers use specific patterns)
    -- Pattern matches based on working c130_supply.lua implementation
    if string.find(unitName, "^iso_container%-") or 
       string.find(unitName, "^iso_container_small%-") or
       string.find(unitName, "^cds_barrels%-") or
       string.find(unitName, "^cds_crate%-") or
       string.find(unitName, "^container_cargo%-") then
        return true
    end
    
    return false
end

-- Debug function to show all current objects (now including static objects correctly)
local function debugShowAllObjects()
    debugMsg("========== DEBUGGING: Showing all objects in mission ==========")
    
    local coalitions = {coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}
    local totalObjects = 0
    local potentialContainers = 0
    
    for _, side in pairs(coalitions) do
        debugMsg("Checking coalition " .. side .. ":")
        
        -- Check ground groups
        local groups = coalition.getGroups(side, Group.Category.GROUND)
        if groups then
            for _, group in pairs(groups) do
                if group and group:isExist() then
                    local units = group:getUnits()
                    if units then
                        for _, unit in pairs(units) do
                            if unit and unit:isExist() then
                                local unitName = unit:getName()
                                local unitTypeName = unit:getTypeName()
                                debugMsg("  GROUND: " .. unitName .. " (type: " .. unitTypeName .. ")")
                                if isPlayerCrateType(unitTypeName, unitName) then
                                    debugMsg("    *** POTENTIAL CONTAINER!! ***")
                                    potentialContainers = potentialContainers + 1
                                end
                                totalObjects = totalObjects + 1
                            end
                        end
                    end
                end
            end
        end
        
        -- Check static objects (using correct API)
        local statics = coalition.getStaticObjects(side)
        if statics then
            debugMsg("Found " .. #statics .. " static objects for coalition " .. side)
            for _, static in pairs(statics) do
                if static and static:isExist() then
                    local staticName = static:getName()
                    local staticTypeName = static:getTypeName()
                    debugMsg("  STATIC: " .. staticName .. " (type: " .. staticTypeName .. ")")
                    if isPlayerCrateType(staticTypeName, staticName) then
                        debugMsg("    *** FOUND C-130J CONTAINER!! ***")
                        potentialContainers = potentialContainers + 1
                    end
                    totalObjects = totalObjects + 1
                end
            end
        else
            debugMsg("No static objects found for coalition " .. side)
        end
    end
    
    debugMsg("Total objects found: " .. totalObjects .. ", potential containers: " .. potentialContainers)
    debugMsg("========== END DEBUG OBJECT LIST ==========")
    debugMsg("Debug complete - found " .. totalObjects .. " objects (" .. potentialContainers .. " potential containers). Check log for details.")
end

-- Debug function to search for objects by partial name match
local function debugSearchObjects(searchPattern)
    debugMsg("========== DEBUGGING: Searching for objects matching '" .. searchPattern .. "' ==========")
    
    local coalitions = {coalition.side.BLUE, coalition.side.RED, coalition.side.NEUTRAL}
    local foundObjects = 0
    local searchLower = string.lower(searchPattern)
    
    for _, side in pairs(coalitions) do
        -- Search in ground groups
        local groups = coalition.getGroups(side, Group.Category.GROUND)
        if groups then
            for _, group in pairs(groups) do
                if group and group:isExist() then
                    local units = group:getUnits()
                    if units then
                        for _, unit in pairs(units) do
                            if unit and unit:isExist() then
                                local unitName = unit:getName()
                                local unitTypeName = unit:getTypeName()
                                local nameLower = string.lower(unitName)
                                local typeLower = string.lower(unitTypeName)
                                
                                if string.find(nameLower, searchLower) or string.find(typeLower, searchLower) then
                                    debugMsg("  GROUND: " .. unitName .. " (type: " .. unitTypeName .. ")")
                                    foundObjects = foundObjects + 1
                                end
                            end
                        end
                    end
                end
            end
        end
        
        -- Search in static objects
        local statics = coalition.getStaticObjects(side)
        if statics then
            for _, static in pairs(statics) do
                if static and static:isExist() then
                    local staticName = static:getName()
                    local staticTypeName = static:getTypeName()
                    local nameLower = string.lower(staticName)
                    local typeLower = string.lower(staticTypeName)
                    
                    if string.find(nameLower, searchLower) or string.find(typeLower, searchLower) then
                        debugMsg("  STATIC: " .. staticName .. " (type: " .. staticTypeName .. ")")
                        if isPlayerCrateType(staticTypeName, staticName) then
                            debugMsg("    *** CONTAINER MATCH!! ***")
                        end
                        foundObjects = foundObjects + 1
                    end
                end
            end
        end
    end
    
    debugMsg("Found " .. foundObjects .. " objects matching '" .. searchPattern .. "'")
    debugMsg("========== END SEARCH ==========")
    debugMsg("Found " .. foundObjects .. " objects matching '" .. searchPattern .. "'. Check log for details.")
end

-- Debug function to show currently tracked containers
local function debugShowTrackedContainers()
    debugMsg("========== DEBUGGING: Currently tracked containers ==========")
    
    local trackedCount = 0
    for containerName, containerData in pairs(AirDropState.playerCrates) do
        trackedCount = trackedCount + 1
        local status = containerData.been_airborne and "HAS BEEN AIRBORNE" or "NOT YET AIRBORNE"
        local groundStatus = containerData.isOnGround and "ON GROUND" or "AIRBORNE"
        local coalition = containerData.coalition or "UNKNOWN"
        local containerType = containerData.containerType or "UNKNOWN"
        
        debugMsg("  CONTAINER: " .. containerName .. " [" .. containerType .. "] (" .. coalition .. ") - " .. status .. " - Currently: " .. groundStatus)
    end
    
    debugMsg("Total tracked containers: " .. trackedCount)
    debugMsg("========== END TRACKED CONTAINERS ==========")
    debugMsg("Currently tracking " .. trackedCount .. " containers. Check log for details.")
end

-- Consolidated function to scan for containers and monitor status in one pass
local function scanAndMonitorPlayerCrates()
    local foundContainers = 0
    local newContainers = 0
    local currentTime = timer.getTime()

    -- Get static objects from blue and neutral coalitions (C-130J containers spawn here)
    local allStatics = {}
    local blueStatics = coalition.getStaticObjects(coalition.side.BLUE)
    if blueStatics then
        for _, static in pairs(blueStatics) do
            table.insert(allStatics, {obj = static, coalition = "BLUE"})
        end
    end

    local neutralStatics = coalition.getStaticObjects(coalition.side.NEUTRAL)
    if neutralStatics then
        for _, static in pairs(neutralStatics) do
            table.insert(allStatics, {obj = static, coalition = "NEUTRAL"})
        end
    end

    -- Process existing containers (monitor status changes)
    for unitName, crateData in pairs(AirDropState.playerCrates) do
        if crateData.unit and crateData.unit:isExist() then
            local unitPos = crateData.unit:getPoint()

            if unitPos then
                -- Get ground height and calculate altitude AGL
                local groundHeight = land.getHeight({x = unitPos.x, y = unitPos.z})
                local isOnGround = false
                local altitudeAGL = 0

                if groundHeight then
                    altitudeAGL = unitPos.y - groundHeight
                    isOnGround = math.abs(altitudeAGL) < 5
                else
                    isOnGround = unitPos.y < 100
                    altitudeAGL = unitPos.y
                end

                -- Check for status changes
                if not crateData.been_airborne and not isOnGround then
                    -- Container is now airborne
                    crateData.been_airborne = true
                    crateData.isOnGround = false
                    if not CONFIG.production_mode then
                        debugMsg("Container is now AIRBORNE: " .. unitName .. " (altitude: " .. math.floor(altitudeAGL) .. "m AGL)")
                    end

                elseif crateData.been_airborne and not crateData.isOnGround and isOnGround then
                    -- Container has landed after being airborne
                    crateData.isOnGround = true
                    debugMsg("Container has LANDED: " .. unitName .. " at x=" .. math.floor(unitPos.x) .. ", z=" .. math.floor(unitPos.z) .. " (altitude: " .. math.floor(altitudeAGL) .. "m AGL)", true)
                end

                -- Update position tracking
                crateData.lastPosition = unitPos
                crateData.isOnGround = isOnGround
            end
        else
            -- Unit no longer exists, remove from tracking
            if not CONFIG.production_mode then
                debugMsg("Container removed from tracking (destroyed): " .. unitName)
            end
            AirDropState.playerCrates[unitName] = nil
        end
    end

    -- Search for new containers
    for _, staticData in pairs(allStatics) do
        local staticObj = staticData.obj
        if staticObj and staticObj:isExist() then
            local objName = staticObj:getName()
            if objName and isPlayerCrateType(nil, objName) then
                foundContainers = foundContainers + 1

                -- Check if this is a new container
                if not AirDropState.playerCrates[objName] then
                    local pos = staticObj:getPoint()
                    local groundHeight = land.getHeight({x = pos.x, y = pos.z})
                    local isOnGround = false
                    local altitudeAGL = 0

                    if groundHeight then
                        altitudeAGL = pos.y - groundHeight
                        isOnGround = math.abs(altitudeAGL) < 5
                    else
                        isOnGround = pos.y < 100
                        altitudeAGL = pos.y
                    end

                    local containerType = "standard"
                    if string.find(objName, "^iso_container_small%-") then
                        containerType = "small"
                    end

                    AirDropState.playerCrates[objName] = {
                        unit = staticObj,
                        spawnTime = currentTime,
                        been_airborne = not isOnGround,
                        isStatic = true,
                        containerType = containerType,
                        coalition = staticData.coalition,
                        lastPosition = pos,
                        isOnGround = isOnGround
                    }

                    newContainers = newContainers + 1
                    if not CONFIG.production_mode then
                        local groundStatus = isOnGround and "ON GROUND" or "AIRBORNE"
                        debugMsg("NEW C-130J container detected: " .. objName .. " [" .. containerType .. "] (" .. staticData.coalition .. ") - " .. groundStatus)
                    end
                end
            end
        end
    end

    -- Only log summary if containers were found or added and not in production mode
    if newContainers > 0 and not CONFIG.production_mode then
        debugMsg("Container scan complete. Found " .. foundContainers .. " total containers, " .. newContainers .. " new containers added to tracking.")
    end
end

-- =====================================================================================
-- AIR DROP FUNCTIONS
-- =====================================================================================

-- Function to handle "make" commands - spawn vehicle and despawn nearby crates
local function handleMakeCommand(marker, vehicleType)
    debugMsg("[MAKE] ================ MAKE COMMAND HANDLER =================")
    debugMsg("[MAKE] Vehicle Type: " .. tostring(vehicleType))
    debugMsg("[MAKE] Marker ID: " .. tostring(marker.idx))
    debugMsg("[MAKE] Marker Text: " .. tostring(marker.text))
    debugMsg("[MAKE] Marker Position: x=" .. marker.pos.x .. ", z=" .. marker.pos.z .. ", y=" .. marker.pos.y)

    local cargoConfig = CONFIG.cargo_types[vehicleType]
    if not cargoConfig then
        debugMsg("[ERROR] Invalid vehicle type for make command: " .. tostring(vehicleType))
        debugMsg("[ERROR] Available vehicle types: Tank, APC, Humvee")
        debugMsg("[ERROR] CONFIG.cargo_types keys: " .. table.concat({"Tank", "APC", "Humvee"}, ", "))
        return
    end

    debugMsg("[SUCCESS] Valid vehicle type found: " .. cargoConfig.name .. " (" .. cargoConfig.type .. ")")
    debugMsg("[PROCESS] Processing make command: " .. vehicleType .. " at marker position")

    -- Find nearby landed crates within search radius
    local nearbyCrates = {}
    local searchRadius = 500 -- meters
    local totalTrackedCrates = 0
    local airborneOrLandedCrates = 0

    debugMsg("[SEARCH] Searching for landed crates within " .. searchRadius .. "m radius...")

    for crateName, crateData in pairs(AirDropState.playerCrates) do
        totalTrackedCrates = totalTrackedCrates + 1
        debugMsg("[CRATE] Checking crate: " .. crateName .. " (been_airborne: " .. tostring(crateData.been_airborne) .. ", isOnGround: " .. tostring(crateData.isOnGround) .. ")")

        if crateData.unit and crateData.unit:isExist() then
            if crateData.been_airborne and crateData.isOnGround then
                airborneOrLandedCrates = airborneOrLandedCrates + 1
                
                -- For FARP, only accept container_cargo containers
                local containerTypeMatch = true
                if vehicleType == "FARP" then
                    containerTypeMatch = string.find(crateName, "^container_cargo%-") ~= nil
                    debugMsg("[FARP-CHECK] FARP requires container_cargo, checking " .. crateName .. ": " .. tostring(containerTypeMatch))
                end
                
                if containerTypeMatch then
                    local cratePos = crateData.unit:getPoint()
                    if cratePos then
                        local dx = cratePos.x - marker.pos.x
                        local dz = cratePos.z - marker.pos.z
                        local distance = math.sqrt(dx * dx + dz * dz)

                        debugMsg("[DISTANCE] Crate " .. crateName .. " at distance: " .. math.floor(distance) .. "m")

                        if distance <= searchRadius then
                            table.insert(nearbyCrates, {name = crateName, data = crateData, distance = distance})
                            debugMsg("[FOUND] Found nearby landed crate: " .. crateName .. " (distance: " .. math.floor(distance) .. "m)")
                        else
                            debugMsg("[SKIP] Crate " .. crateName .. " too far: " .. math.floor(distance) .. "m")
                        end
                    else
                        debugMsg("[ERROR] Could not get position for crate: " .. crateName)
                    end
                else
                    debugMsg("[SKIP] Crate " .. crateName .. " wrong type for FARP (need container_cargo)")
                end
            else
                debugMsg("[SKIP] Crate " .. crateName .. " not eligible (not airborne+landed)")
            end
        else
            debugMsg("[ERROR] Crate " .. crateName .. " does not exist or is invalid")
        end
    end

    debugMsg("[SUMMARY] Crate Summary: " .. totalTrackedCrates .. " total tracked, " .. airborneOrLandedCrates .. " airborne+landed, " .. #nearbyCrates .. " nearby")

    -- Check if we have enough materials (varies by item type)
    local requiredCrates = cargoConfig.materials_required or 2
    if #nearbyCrates < requiredCrates then
        debugMsg("[ERROR] Insufficient materials for " .. cargoConfig.name .. " - need " .. requiredCrates .. " landed crates, found " .. #nearbyCrates)
        debugMsg("[ERROR] MANUFACTURING FAILED: Need " .. requiredCrates .. " landed containers near marker to build " .. cargoConfig.name)

        -- Remove the make command marker since we can't fulfill it
        debugMsg("[CLEANUP] Removing unfulfillable make command marker ID: " .. marker.idx)
        trigger.action.removeMark(marker.idx)
        debugMsg("[MAKE] ================ MAKE COMMAND FAILED - INSUFFICIENT MATERIALS =================")
        return
    end

    debugMsg("[SUCCESS] Found " .. #nearbyCrates .. " landed crates near make command marker - sufficient for manufacturing")

    -- Sort crates by distance to use the closest ones
    table.sort(nearbyCrates, function(a, b) return a.distance < b.distance end)

    -- Select the closest crates for manufacturing
    local selectedCrates = {}
    for i = 1, requiredCrates do
        selectedCrates[i] = nearbyCrates[i]
        debugMsg("[MATERIALS] Selected crate " .. i .. ": " .. selectedCrates[i].name .. " (distance: " .. math.floor(selectedCrates[i].distance) .. "m)")
    end

    -- Spawn the item at marker location
    local itemCounter = (AirDropState.makeCounter or 0) + 1
    AirDropState.makeCounter = itemCounter

    local itemName = "Made_" .. vehicleType .. "_" .. itemCounter

    local spawnSuccess = false
    local spawnResult = nil

    if cargoConfig.category == "static" then
        -- Spawn static object (like FARP)
        local staticData = {
            ["type"] = cargoConfig.type,
            ["unitId"] = math.random(10000, 99999),
            ["y"] = marker.pos.z,
            ["x"] = marker.pos.x,
            ["name"] = itemName,
            ["heading"] = 0,
            ["dead"] = false,
        }

        debugMsg("[SPAWN] Attempting to spawn static object: " .. itemName)
        debugMsg("[SPAWN] Static type: " .. cargoConfig.type .. " (" .. cargoConfig.name .. ")")
        debugMsg("[SPAWN] Spawn position: x=" .. marker.pos.x .. ", z=" .. marker.pos.z)
        debugMsg("[SPAWN] Unit ID: " .. staticData.unitId)

        spawnSuccess, spawnResult = pcall(coalition.addStaticObject, country.id.USA, staticData)
    else
        -- Spawn vehicle group
        local vehicleGroupName = "Made_" .. vehicleType .. "_Group_" .. itemCounter
        local vehicleUnitName = "Made_" .. vehicleType .. "_" .. itemCounter
        
        local vehicleGroupData = {
            ["visible"] = false,
            ["taskSelected"] = true,
            ["groupId"] = math.random(1000, 9999),
            ["hidden"] = false,
            ["units"] = {
                [1] = {
                    ["type"] = cargoConfig.type,
                    ["unitId"] = math.random(10000, 99999),
                    ["skill"] = "Average",
                    ["y"] = marker.pos.z,
                    ["x"] = marker.pos.x,
                    ["name"] = vehicleUnitName,
                    ["heading"] = 0,
                    ["playerCanDrive"] = true,
                }
            },
            ["y"] = marker.pos.z,
            ["x"] = marker.pos.x,
            ["name"] = vehicleGroupName,
            ["start_time"] = 0,
            ["task"] = "Ground Nothing",
            ["route"] = {
                ["spans"] = {},
                ["points"] = {
                    [1] = {
                        ["alt"] = 0,
                        ["type"] = "Turning Point",
                        ["ETA"] = 0,
                        ["alt_type"] = "BARO",
                        ["formation_template"] = "",
                        ["y"] = marker.pos.z,
                        ["x"] = marker.pos.x,
                        ["name"] = "",
                        ["ETA_locked"] = true,
                        ["speed"] = 0,
                        ["action"] = "Off Road",
                        ["task"] = {
                            ["id"] = "ComboTask",
                            ["params"] = {
                                ["tasks"] = {}
                            }
                        },
                        ["speed_locked"] = true,
                    }
                }
            }
        }

        debugMsg("[SPAWN] Attempting to spawn vehicle group: " .. vehicleGroupName)
        debugMsg("[SPAWN] Vehicle type: " .. cargoConfig.type .. " (" .. cargoConfig.name .. ")")
        debugMsg("[SPAWN] Spawn position: x=" .. marker.pos.x .. ", z=" .. marker.pos.z)
        debugMsg("[SPAWN] Group ID: " .. vehicleGroupData.groupId .. ", Unit ID: " .. vehicleGroupData.units[1].unitId)

        spawnSuccess, spawnResult = pcall(coalition.addGroup, country.id.USA, Group.Category.GROUND, vehicleGroupData)
    end

    if spawnSuccess then
        debugMsg("[SUCCESS] " .. cargoConfig.name .. " spawned successfully: " .. itemName)
        debugMsg("[MAKE] ITEM MANUFACTURED: " .. cargoConfig.name .. " created from " .. requiredCrates .. " containers!")

        -- Despawn the selected crates used as materials
        local despawnedCount = 0
        debugMsg("[CLEANUP] Processing " .. requiredCrates .. " selected crates for despawn...")
        for i, crateInfo in ipairs(selectedCrates) do
            if crateInfo.data.unit and crateInfo.data.unit:isExist() then
                debugMsg("[CLEANUP] Despawning material crate " .. i .. ": " .. crateInfo.name)
                crateInfo.data.unit:destroy()
                AirDropState.playerCrates[crateInfo.name] = nil
                despawnedCount = despawnedCount + 1
                debugMsg("[SUCCESS] Despawned material crate: " .. crateInfo.name)
            else
                debugMsg("[ERROR] Could not despawn crate: " .. crateInfo.name .. " (does not exist)")
            end
        end

        debugMsg("[CLEANUP] Used " .. despawnedCount .. " crates as materials for manufacturing")
        local remainingCrates = #nearbyCrates - despawnedCount
        if remainingCrates > 0 then
            debugMsg("[INFO] " .. remainingCrates .. " additional crates remain nearby")
        end

        -- Remove the make command marker
        debugMsg("[CLEANUP] Removing make command marker ID: " .. marker.idx)
        trigger.action.removeMark(marker.idx)
        debugMsg("[SUCCESS] Removed make command marker")

    else
        debugMsg("[ERROR] Failed to spawn " .. cargoConfig.name .. ": " .. tostring(spawnResult))
        debugMsg("[ERROR] Error details: " .. tostring(spawnResult))
    end

    debugMsg("[MAKE] ================ MAKE COMMAND COMPLETE =================")
end

-- Function to find map marker by name and handle special "make" commands
local function getMapMarker(markerName)
    debugMsg("Searching for map marker: " .. markerName)

    -- Get all markers from the mission
    local markers = world.getMarkPanels()
    local compareName = string.upper(markerName)

    for _, _mark in pairs(markers) do
        local text = string.upper(_mark.text)
        if text == compareName then
            debugMsg("Found marker '" .. _mark.text .. "' with ID: " .. _mark.idx .. " at position: x=" .. _mark.pos.x .. ", z=" .. _mark.pos.z)
            return _mark
        end
    end

    debugMsg("WARNING: No map marker found with name '" .. markerName .. "'")
    debugMsg("WARNING: No marker found! Please create a map marker named '" .. markerName .. "'")
    return nil
end

-- Function to scan for and process make command markers
local function scanForMakeCommands()
    if not CONFIG.production_mode then
        debugMsg("[SCAN] Scanning for make command markers...")
    end

    local markers = world.getMarkPanels()
    if not markers then
        if not CONFIG.production_mode then
            debugMsg("[ERROR] No markers found on map")
        end
        return
    end

    local foundMakeCommands = 0

    for markerId, _mark in pairs(markers) do
        if _mark and _mark.text then
            local text = string.upper(_mark.text)
            if not CONFIG.production_mode then
                debugMsg("[MARKER] Found marker ID " .. markerId .. " with text: '" .. _mark.text .. "'")
            end

            -- Check for "make" command markers
            if string.find(text, "^MAKE ") then
                foundMakeCommands = foundMakeCommands + 1
                debugMsg("[MAKE] MAKE COMMAND DETECTED: " .. _mark.text)

                local vehicleTypeText = string.gsub(text, "^MAKE ", "")
                local vehicleType = nil

                if not CONFIG.production_mode then
                    debugMsg("[PARSE] Parsing vehicle type: '" .. vehicleTypeText .. "'")
                end

                -- Map marker text to CONFIG cargo types
                if vehicleTypeText == "TANK" then
                    vehicleType = "Tank"
                elseif vehicleTypeText == "APC" then
                    vehicleType = "APC"
                elseif vehicleTypeText == "HUMVEE" then
                    vehicleType = "Humvee"
                elseif vehicleTypeText == "FARP" then
                    vehicleType = "FARP"
                end

                if vehicleType and CONFIG.cargo_types[vehicleType] then
                    debugMsg("[EXECUTE] Processing make command: " .. _mark.text .. " -> " .. vehicleType)
                    handleMakeCommand(_mark, vehicleType)
                else
                    debugMsg("[ERROR] Invalid or unrecognized vehicle type in make command: " .. tostring(vehicleTypeText))
                end
            end
        end
    end

    if foundMakeCommands == 0 and not CONFIG.production_mode then
        debugMsg("[INFO] No make command markers found during scan")
    elseif foundMakeCommands > 0 then
        debugMsg("[COMPLETE] Processed " .. foundMakeCommands .. " make command markers")
    end
end

-- output all world markers for debugging
local function outputAllMapMarkers()
    debugMsg("Listing all world map markers:")
    
    local markers = world.getMarkPanels()
    
    if markers then
        for markerId, marker in pairs(markers) do
            if marker and marker.text and marker.pos then
                debugMsg("Marker ID: " .. markerId .. ", Text: '" .. marker.text .. "', Position: x=" .. marker.pos.x .. ", z=" .. marker.pos.z)
            end
        end
    else
        debugMsg("No markers found on the map.")
    end
end

-- find the nearest airport to a given position
local function getNearestAirport(position)
    debugMsg("Searching for nearest airport to drop zone...")
    
    local nearestAirbase = nil
    local minDistance = math.huge
    
    -- Get all airbases
    local airbases = world.getAirbases()
    
    if airbases then
        for _, airbase in pairs(airbases) do
            if airbase and airbase:isExist() then
                local airbasePos = airbase:getPoint()
                
                -- Calculate distance
                local dx = position.pos.x - airbasePos.x
                local dz = position.pos.z - airbasePos.z
                local distance = math.sqrt(dx * dx + dz * dz)
                
                if distance < minDistance then
                    minDistance = distance
                    nearestAirbase = airbase
                end
            end
        end
    end
    
    if nearestAirbase then
        local airbasePos = nearestAirbase:getPoint()
        debugMsg("Found nearest airport: " .. nearestAirbase:getName() .. " at " .. math.floor(minDistance / 1000) .. "km away")
        return {
            x = airbasePos.x,
            y = airbasePos.y,
            z = airbasePos.z,
            name = nearestAirbase:getName()
        }
    else
        debugMsg("ERROR: No airports found on map!")
        return nil
    end
end

-- Function to calculate heading between two points
local function getHeading(from, to)
    local dx = to.pos.x - from.x
    local dz = to.pos.z - from.z
    local angle = math.atan2(dz, dx)
    return angle
end

-- Function to clean up old groups
local function cleanupOldGroups()
    local currentTime = timer.getTime()
    for groupName, groupData in pairs(AirDropState.spawnedGroups) do
        -- Remove groups older than 30 minutes
        if currentTime - groupData.spawnTime > 1800 then
            local grp = Group.getByName(groupName)
            if grp and grp:isExist() then
                grp:destroy()
                debugMsg("Cleaned up old group: " .. groupName)
            end
            AirDropState.spawnedGroups[groupName] = nil
        end
    end
end

-- Function to spawn C-130 and fly to drop zone
local function spawnDropAircraft(vehicleType, qty)
    vehicleType = vehicleType or "Tank"  -- Default to Tank if not specified
    qty = qty or 2  -- Default to 2 if not specified (minimum drop)

    local cargoConfig = CONFIG.cargo_types[vehicleType]

    if not cargoConfig then
        debugMsg("ERROR: Invalid vehicle type: " .. tostring(vehicleType))
        return false
    end

    if qty < 2 or qty > 8 or qty % 2 ~= 0 then
        debugMsg("ERROR: Invalid quantity: " .. tostring(qty) .. " (must be 2, 4, 6, or 8)")
        return false
    end

    -- Calculate number of aircraft needed (each C-130 carries 2 units)
    local aircraftQty = qty / 2

    debugMsg("========== Starting Air Drop Mission: " .. qty .. " x " .. cargoConfig.name .. " (" .. aircraftQty .. " aircraft) ==========")

    -- Generate a unique marker label that isn't already in use
    local phoneticAlphabet = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango"}
    local markerLabel = nil
    local attempts = 0
    local maxAttempts = #phoneticAlphabet

    -- Helper function to check if a marker label is in use
    local function isMarkerLabelInUse(label)
        -- Check pending requests
        if AirDropState.pendingDropRequests[label] then
            return true
        end
        
        -- Check active drops (missions currently in progress)
        for groupName, missionData in pairs(AirDropState.activeDrops) do
            if missionData.markerName == label then
                return true
            end
        end
        
        return false
    end

    -- Keep trying until we find an unused marker label
    repeat
        local randomIndex = math.random(1, #phoneticAlphabet)
        local testLabel = "dp-" .. phoneticAlphabet[randomIndex]

        -- Check if this label is already in use (in pending OR active)
        if not isMarkerLabelInUse(testLabel) then
            markerLabel = testLabel
            break
        end

        attempts = attempts + 1
    until markerLabel ~= nil or attempts >= maxAttempts

    -- If all labels are in use, append a number
    if not markerLabel then
        local counter = 1
        repeat
            markerLabel = "dp-zulu-" .. counter
            counter = counter + 1
        until not isMarkerLabelInUse(markerLabel)
    end

    -- Store this pending drop request in the state system
    AirDropState.pendingDropRequests[markerLabel] = {
        vehicleType = vehicleType,
        qty = qty,
        aircraftQty = aircraftQty,
        cargoConfig = cargoConfig,
        requestTime = timer.getTime()
    }

    -- output the marker so the user can use it.
    debugMsg("Drop requested: " .. qty .. " " .. cargoConfig.name .. "s (" .. aircraftQty .. " C-130s). Create marker: " .. markerLabel)
    debugMsg("Waiting for user to place marker: " .. markerLabel)

    return true
end

-- Internal function to execute the actual aircraft spawn once marker is found
local function executeAircraftSpawn(dropMarker, vehicleType, qty, markerName)
    local cargoConfig = CONFIG.cargo_types[vehicleType]
    
    -- Calculate number of aircraft needed (each C-130 carries 2 units)
    local aircraftQty = qty / 2
    
    debugMsg("========== Executing Air Drop Spawn: " .. qty .. " x " .. cargoConfig.name .. " (" .. aircraftQty .. " aircraft) ==========")
    debugMsg("Target marker: " .. markerName)
    -- Step 1: Find nearest airport
    local airport = getNearestAirport(dropMarker)
    if not airport then
        debugMsg("ERROR: No airport found for spawning!")
        return false
    end
    
    -- Step 2: Calculate spawn position (offset from airport runway)
    local heading = getHeading(airport, dropMarker)
    local spawnOffset = 500  -- Spawn 500m from airport center
    local spawnX = airport.x + math.cos(heading) * spawnOffset
    local spawnZ = airport.z + math.sin(heading) * spawnOffset
    
    -- Step 3: Create group counter and name
    AirDropState.groupCounter = AirDropState.groupCounter + 1
    local groupName = "AirDrop_C130_" .. AirDropState.groupCounter
    
    debugMsg("Creating C-130 group: " .. groupName)
    
    -- Step 4: Create group data structure
    local groupData = {
        ["visible"] = false,
        ["tasks"] = {},
        ["uncontrollable"] = false,
        ["task"] = "Transport",
        ["taskSelected"] = true,
        ["route"] = {
            ["points"] = {
                -- Waypoint 1: Spawn point
                [1] = {
                    ["alt"] = CONFIG.spawn_altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["alt_type"] = "BARO",
                    ["speed"] = CONFIG.cruise_speed,
                    ["y"] = spawnZ,
                    ["x"] = spawnX,
                    ["speed_locked"] = true,
                },
                -- Waypoint 2: Drop point
                [2] = {
                    ["alt"] = CONFIG.spawn_altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["alt_type"] = "BARO",
                    ["speed"] = CONFIG.cruise_speed,
                    ["y"] = dropMarker.pos.z,
                    ["x"] = dropMarker.pos.x,
                    ["speed_locked"] = true,
                },
                -- Waypoint 3: Exit point (continue past drop)
                [3] = {
                    ["alt"] = CONFIG.spawn_altitude,
                    ["type"] = "Turning Point",
                    ["action"] = "Turning Point",
                    ["alt_type"] = "BARO",
                    ["speed"] = CONFIG.cruise_speed,
                    ["y"] = dropMarker.pos.z + math.sin(heading) * 10000,
                    ["x"] = dropMarker.pos.x + math.cos(heading) * 10000,
                    ["speed_locked"] = true,
                }
            }
        },
        ["groupId"] = math.random(1000, 9999),
        ["hidden"] = false,
        ["units"] = {},
        ["y"] = spawnZ,
        ["x"] = spawnX,
        ["name"] = groupName,
        ["start_time"] = 0,
    }
    
    -- Step 5: Create units dynamically based on quantity
    local formationPositions = {
        [1] = {x = 0, z = 0},       -- Lead aircraft at front (tip of diamond)
        [2] = {x = -50, z = -50},   -- Left wing (left point of diamond)
        [3] = {x = 50, z = -50},    -- Right wing (right point of diamond)
        [4] = {x = 0, z = -100}     -- Trail aircraft at rear (back point of diamond)
    }
    
    for i = 1, aircraftQty do
        local unitPos = formationPositions[i]
        local unit = {
            ["type"] = CONFIG.aircraft_type,
            ["unitId"] = math.random(10000, 99999),
            ['callsign'] = {
                ["name"] = "DropBear-1-" .. i,
                ["number"] = i,
                ["modulation"] = 0,
                ["tone"] = 0
            },
            ["skill"] = "High",
            ["y"] = spawnZ + unitPos.z,
            ["x"] = spawnX + unitPos.x,
            ["name"] = groupName .. "_Unit_" .. i,
            ["heading"] = heading,
            ["speed"] = CONFIG.cruise_speed,
            ["alt"] = CONFIG.spawn_altitude,
            ["alt_type"] = "BARO",
            ["payload"] = {
                ["pylons"] = {},
                ["fuel"] = 20830,
                ["flare"] = 60,
                ["chaff"] = 120,
                ["gun"] = 100
            }
        }
        groupData.units[i] = unit
        debugMsg("Created unit " .. i .. " of " .. aircraftQty .. " at offset: x=" .. unitPos.x .. ", z=" .. unitPos.z)
    end
    
    -- Step 6: Spawn the group
    debugMsg("Spawning C-130 at airport: " .. airport.name)
    local success, result = pcall(coalition.addGroup, country.id.USA, Group.Category.AIRPLANE, groupData)
    
    -- If primary aircraft type fails, try fallback
    if not success then
        debugMsg("Primary aircraft type failed, trying fallback: " .. CONFIG.aircraft_fallback)
        for i = 1, aircraftQty do
            groupData.units[i].type = CONFIG.aircraft_fallback
        end
        success, result = pcall(coalition.addGroup, country.id.USA, Group.Category.AIRPLANE, groupData)
    end
    
    if success and result then
        debugMsg("✓ C-130 formation spawned successfully: " .. groupName .. " (" .. aircraftQty .. " aircraft carrying " .. qty .. " units)")
        debugMsg("C-130 formation (" .. aircraftQty .. " aircraft) inbound from " .. airport.name .. " carrying " .. qty .. " " .. cargoConfig.name .. "s!")
        
        -- Store spawned group in spawnedGroups (basic tracking)
        AirDropState.spawnedGroups[groupName] = {
            group = result,
            spawnTime = timer.getTime()
        }
        
        -- Store active drop mission in activeDrops (mission state tracking)
        AirDropState.activeDrops[groupName] = {
            markerName = markerName,
            vehicleType = vehicleType,
            qty = qty,
            aircraftQty = aircraftQty,
            status = "en_route",  -- Status: en_route, dropping, complete
            spawnTime = timer.getTime(),
            dropMarker = dropMarker,
            airport = airport.name
        }
        
        debugMsg("Active drop mission registered: " .. groupName .. " -> " .. markerName)
        
        -- Schedule cargo drop when reaching waypoint - check all aircraft
        timer.scheduleFunction(function(args)
            -- Safety check: ensure arguments exist
            if not args or not args.groupName or not args.dropMarker or not args.vehicleType or not args.aircraftQty or not args.totalUnits then
                debugMsg("ERROR: Invalid arguments in cargo drop timer function")
                return nil
            end
            
            local cargoConfig = CONFIG.cargo_types[args.vehicleType]
            if not cargoConfig then
                debugMsg("ERROR: Invalid vehicle type in timer: " .. tostring(args.vehicleType))
                return nil
            end
            
            local maxAircraft = args.aircraftQty
            
            local grp = Group.getByName(args.groupName)
            if grp and grp:isExist() then
                local units = grp:getUnits()
                if units then
                    local anyUnitAtDropZone = false
                    local tanksDropped = args.tanksDropped or 0
                    
                    -- Check if formation is at drop zone (use lead aircraft for timing)
                    if units[1] and units[1]:isExist() then
                        local leadPos = units[1]:getPoint()
                        if leadPos and leadPos.x and leadPos.z then
                            local dx = leadPos.x - args.dropMarker.pos.x
                            local dz = leadPos.z - args.dropMarker.pos.z
                            local distance = math.sqrt(dx * dx + dz * dz)
                            
                            debugMsg("Formation lead distance to drop zone: " .. math.floor(distance) .. "m")
                            
                            -- When formation reaches drop zone, drop all 3 tanks at once
                            if distance < 1000 and tanksDropped == 0 then
                                debugMsg("Formation reached drop zone - checking surviving aircraft...")
                                
                                -- Count surviving aircraft in the formation
                                local survivingAircraft = 0
                                local aliveUnits = {}
                                
                                for i = 1, maxAircraft do
                                    if units[i] and units[i]:isExist() then
                                        survivingAircraft = survivingAircraft + 1
                                        table.insert(aliveUnits, i)
                                        debugMsg("C-130 #" .. i .. " is alive and ready to drop")
                                    else
                                        debugMsg("C-130 #" .. i .. " is not available (destroyed or missing)")
                                    end
                                end
                                
                                debugMsg("Surviving aircraft: " .. survivingAircraft .. " out of " .. maxAircraft)
                                local unitsToDeliver = survivingAircraft * 2  -- Each C-130 carries 2 units
                                local unitPlural = unitsToDeliver == 1 and cargoConfig.name or cargoConfig.name .. "s"
                                debugMsg("Formation dropping " .. unitsToDeliver .. " " .. unitPlural .. " from " .. survivingAircraft .. " surviving aircraft!")
                                
                                -- Update mission status to "dropping"
                                if AirDropState.activeDrops[args.groupName] then
                                    AirDropState.activeDrops[args.groupName].status = "dropping"
                                    debugMsg("Mission status updated: " .. args.groupName .. " -> dropping")
                                end
                                
                                -- Drop 2 vehicles per surviving aircraft
                                local vehicleCounter = 0
                                for j = 1, survivingAircraft do
                                    local aircraftNum = aliveUnits[j]  -- Get the actual aircraft number
                                    
                                    -- Each aircraft drops 2 vehicles
                                    for k = 1, 2 do
                                        vehicleCounter = vehicleCounter + 1
                                        
                                        -- Calculate position offset for this vehicle
                                        -- Spread vehicles in a line, centered on drop marker
                                        local totalVehicles = survivingAircraft * 2
                                        local offsetX = (vehicleCounter - math.ceil(totalVehicles/2)) * 40  -- 40m spacing between vehicles
                                        local vehicleDropX = args.dropMarker.pos.x + offsetX
                                        local vehicleDropZ = args.dropMarker.pos.z

                                        -- Blue smoke for each vehicle
                                        -- trigger.action.smoke({x = vehicleDropX, y = args.dropMarker.y, z = vehicleDropZ}, trigger.smokeColor.Blue)
                                        
                                        -- Spawn vehicle
                                        local cargoCounter = (AirDropState.cargoCounter or 0) + vehicleCounter
                                        local cargoGroupName = "Cargo_" .. args.vehicleType .. "_Group_" .. cargoCounter
                                        local cargoUnitName = "Cargo_" .. args.vehicleType .. "_" .. cargoCounter
                                    
                                    -- Create vehicle group data
                                    local vehicleGroupData = {
                                        ["visible"] = false,
                                        ["taskSelected"] = true,
                                        ["groupId"] = math.random(1000, 9999),
                                        ["hidden"] = false,
                                        ["units"] = {
                                            [1] = {
                                                ["type"] = cargoConfig.type,  -- Use the vehicle type from config
                                                ["unitId"] = math.random(10000, 99999),
                                                ["skill"] = "Average",
                                                ["y"] = vehicleDropZ,
                                                ["x"] = vehicleDropX,
                                                ["name"] = cargoUnitName,
                                                ["heading"] = 0,  -- All vehicles face same direction
                                                ["playerCanDrive"] = true,
                                            }
                                        },
                                        ["y"] = vehicleDropZ,
                                        ["x"] = vehicleDropX,
                                        ["name"] = cargoGroupName,
                                        ["start_time"] = 0,
                                        ["task"] = "Ground Nothing",
                                        ["route"] = {
                                            ["spans"] = {},
                                            ["points"] = {
                                                [1] = {
                                                    ["alt"] = 0,
                                                    ["type"] = "Turning Point",
                                                    ["ETA"] = 0,
                                                    ["alt_type"] = "BARO",
                                                    ["formation_template"] = "",
                                                    ["y"] = vehicleDropZ,
                                                    ["x"] = vehicleDropX,
                                                    ["name"] = "",
                                                    ["ETA_locked"] = true,
                                                    ["speed"] = 0,
                                                    ["action"] = "Off Road",
                                                    ["task"] = {
                                                        ["id"] = "ComboTask",
                                                        ["params"] = {
                                                            ["tasks"] = {}
                                                        }
                                                    },
                                                    ["speed_locked"] = true,
                                                }
                                            }
                                        }
                                    }
                                    
                                    -- Spawn vehicle group
                                    local vehicleSuccess, vehicleResult = pcall(coalition.addGroup, country.id.USA, Group.Category.GROUND, vehicleGroupData)
                                    
                                    if vehicleSuccess then
                                        debugMsg("✓ " .. cargoConfig.name .. " #" .. vehicleCounter .. " spawned successfully from C-130 #" .. aircraftNum .. " (unit " .. k .. " of 2): " .. cargoGroupName)
                                        tanksDropped = tanksDropped + 1
                                        
                                        -- Remove the specific marker after first successful vehicle spawn
                                        if tanksDropped == 1 and args.dropMarker.idx then
                                            debugMsg("First vehicle spawned successfully - removing drop marker ID: " .. args.dropMarker.idx)
                                            trigger.action.removeMark(args.dropMarker.idx)
                                            debugMsg("Drop marker cleared - vehicles deployed!")
                                        end
                                    else
                                        debugMsg("✗ Failed to spawn " .. cargoConfig.name .. " #" .. vehicleCounter .. " from C-130 #" .. aircraftNum .. ": " .. tostring(vehicleResult))
                                    end
                                    end  -- End of k loop (2 vehicles per aircraft)
                                end  -- End of j loop (aircraft)
                                
                                -- Update counter for next mission
                                AirDropState.cargoCounter = (AirDropState.cargoCounter or 0) + vehicleCounter
                                
                                -- Final success message based on actual deliveries
                                local lostAircraft = maxAircraft - survivingAircraft
                                local totalDelivered = survivingAircraft * 2  -- Each surviving aircraft delivers 2 units
                                if survivingAircraft == maxAircraft then
                                    local vehiclePlural = totalDelivered == 1 and cargoConfig.name or cargoConfig.name .. "s"
                                    debugMsg("All " .. totalDelivered .. " " .. vehiclePlural .. " delivered successfully!")
                                elseif survivingAircraft > 0 then
                                    local vehiclePlural = totalDelivered == 1 and cargoConfig.name or cargoConfig.name .. "s"
                                    local aircraftPlural = lostAircraft == 1 and "aircraft" or "aircraft"
                                    debugMsg(totalDelivered .. " " .. vehiclePlural .. " delivered (" .. lostAircraft .. " " .. aircraftPlural .. " lost)!")
                                else
                                    debugMsg("No vehicles delivered - all " .. maxAircraft .. " aircraft lost!")
                                end
                                
                                -- Update mission status to "complete"
                                if AirDropState.activeDrops[args.groupName] then
                                    AirDropState.activeDrops[args.groupName].status = "complete"
                                    AirDropState.activeDrops[args.groupName].deliveredCount = totalDelivered
                                    debugMsg("Mission status updated: " .. args.groupName .. " -> complete (" .. totalDelivered .. " delivered)")
                                end
                                
                                -- Schedule C-130 formation despawn after 30 seconds
                                timer.scheduleFunction(function(despawnArgs)
                                    local despawnGroup = Group.getByName(despawnArgs.groupName)
                                    if despawnGroup and despawnGroup:isExist() then
                                        debugMsg("Despawning C-130 formation: " .. despawnArgs.groupName)
                                        despawnGroup:destroy()
                                        debugMsg("C-130 formation RTB (returning to base)")
                                    else
                                        debugMsg("C-130 formation already gone: " .. despawnArgs.groupName)
                                    end
                                    
                                    -- Clean up from both tracking systems
                                    if AirDropState.spawnedGroups[despawnArgs.groupName] then
                                        AirDropState.spawnedGroups[despawnArgs.groupName] = nil
                                        debugMsg("Removed from spawnedGroups: " .. despawnArgs.groupName)
                                    end
                                    
                                    if AirDropState.activeDrops[despawnArgs.groupName] then
                                        AirDropState.activeDrops[despawnArgs.groupName] = nil
                                        debugMsg("Removed from activeDrops: " .. despawnArgs.groupName)
                                    end
                                    
                                    return nil
                                end, {groupName = args.groupName}, timer.getTime() + 30)
                                
                                return nil  -- Stop scheduled function after all drops complete
                            end
                            
                            -- Continue checking if not at drop zone yet
                            return timer.getTime() + 3
                        end
                    end
                    
                    return timer.getTime() + 3
                else
                    debugMsg("C-130 formation units no longer exist")
                    return nil  -- Stop if units don't exist
                end
            else
                debugMsg("C-130 formation group no longer exists") 
                return nil  -- Stop if group doesn't exist
            end
        end, {groupName = groupName, dropMarker = dropMarker, vehicleType = vehicleType, aircraftQty = aircraftQty, totalUnits = qty}, timer.getTime() + 10)
        
        return true
    else
        debugMsg("✗ Failed to spawn C-130: " .. tostring(result))
        debugMsg("ERROR: Failed to spawn C-130 aircraft")
        return false
    end
end


-- =====================================================================================
-- RADIO FUNCTIONS
-- =====================================================================================

local function createRadioMenu()
    -- Create main menu for Blue coalition
    local mainMenu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "Call Air Drop")


    -- Add submenu for different vehicle types
    local tankMenu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "Drop Tanks", mainMenu)
    local apcMenu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "Drop APCs", mainMenu)
    local humveeMenu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "Drop Humvees", mainMenu)

    -- Create quantity submenus for each vehicle type

    -- Tank quantity menus (each C-130 carries 2 tanks)
    local tank1Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "1 C-130 (2 Tanks)", tankMenu)
    local tank2Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "2 C-130s (4 Tanks)", tankMenu)
    local tank3Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "3 C-130s (6 Tanks)", tankMenu)
    local tank4Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "4 C-130s (8 Tanks)", tankMenu)

    -- APC quantity menus (each C-130 carries 2 APCs)
    local apc1Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "1 C-130 (2 APCs)", apcMenu)
    local apc2Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "2 C-130s (4 APCs)", apcMenu)
    local apc3Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "3 C-130s (6 APCs)", apcMenu)
    local apc4Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "4 C-130s (8 APCs)", apcMenu)

    -- Humvee quantity menus (each C-130 carries 2 Humvees)
    local humvee1Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "1 C-130 (2 Humvees)", humveeMenu)
    local humvee2Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "2 C-130s (4 Humvees)", humveeMenu)
    local humvee3Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "3 C-130s (6 Humvees)", humveeMenu)
    local humvee4Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "4 C-130s (8 Humvees)", humveeMenu)

    -- Add commands for Tank drops (qty represents total tanks to deliver)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", tank1Menu, 
        function() spawnDropAircraft("Tank", 2) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", tank2Menu, 
        function() spawnDropAircraft("Tank", 4) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", tank3Menu, 
        function() spawnDropAircraft("Tank", 6) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", tank4Menu, 
        function() spawnDropAircraft("Tank", 8) end)

    -- Add commands for APC drops (qty represents total APCs to deliver)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", apc1Menu, 
        function() spawnDropAircraft("APC", 2) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", apc2Menu, 
        function() spawnDropAircraft("APC", 4) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", apc3Menu, 
        function() spawnDropAircraft("APC", 6) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", apc4Menu, 
        function() spawnDropAircraft("APC", 8) end)

    -- Add commands for Humvee drops (qty represents total Humvees to deliver)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", humvee1Menu, 
        function() spawnDropAircraft("Humvee", 2) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", humvee2Menu, 
        function() spawnDropAircraft("Humvee", 4) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", humvee3Menu, 
        function() spawnDropAircraft("Humvee", 6) end)
    missionCommands.addCommandForCoalition(coalition.side.BLUE, "Request Drop", humvee4Menu, 
        function() spawnDropAircraft("Humvee", 8) end)

    -- Add debug commands to the main menu for troubleshooting
    if CONFIG.debug == true then
        debugMsg("Adding debug commands to radio menu")
        local c130Menu = missionCommands.addSubMenuForCoalition(coalition.side.BLUE, "C130j Air Drop")
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: Show All Objects", c130Menu, 
            function() debugShowAllObjects() end)
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: Show Tracked Containers", c130Menu, 
            function() debugShowTrackedContainers() end)
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: Search 'CDS'", c130Menu, 
            function() debugSearchObjects("cds") end)
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: Search 'Container'", c130Menu, 
            function() debugSearchObjects("container") end)
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: Search 'ISO'", c130Menu, 
            function() debugSearchObjects("iso") end)
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: List All Markers", c130Menu, 
            function() outputAllMapMarkers() end)
        missionCommands.addCommandForCoalition(coalition.side.BLUE, "DEBUG: Test Make Commands", c130Menu, 
            function() scanForMakeCommands() end)

        debugMsg("Radio menu created with vehicle and quantity options - 'Call Air Drop' menu available")
    end

end


-- =====================================================================================
-- MARKER MONITORING SYSTEM
-- =====================================================================================

-- Consolidated monitoring function for all pending operations
local function masterMonitor()
    -- Check pending drop requests
    for markerLabel, requestData in pairs(AirDropState.pendingDropRequests) do
        local dropMarker = getMapMarker(markerLabel)
        
        if dropMarker then
            debugMsg("[SUCCESS] Marker found for pending drop: " .. markerLabel)
            debugMsg("Drop marker detected! Spawning C-130s to " .. markerLabel, true)
            
            -- Execute the aircraft spawn, passing the markerName
            executeAircraftSpawn(dropMarker, requestData.vehicleType, requestData.qty, markerLabel)
            
            -- Remove this request from pending list
            AirDropState.pendingDropRequests[markerLabel] = nil
        else
            -- Check if request has timed out (5 minutes)
            local requestAge = timer.getTime() - requestData.requestTime
            if requestAge > 300 then
                debugMsg("Drop request timed out: " .. markerLabel)
                AirDropState.pendingDropRequests[markerLabel] = nil
            end
        end
    end
    
    -- Scan for make commands
    scanForMakeCommands()
    
    -- Continue monitoring
    return timer.getTime() + CONFIG.scan_frequency
end


-- =====================================================================================
-- SCRIPT INITIALIZATION
-- =====================================================================================

-- Initialize the script
local function initialize()
    debugMsg("========================================")
    debugMsg("Air Drop Script v0.2 Initializing...")
    debugMsg("========================================")

    -- Create radio menu after a short delay
    timer.scheduleFunction(createRadioMenu, {}, timer.getTime() + 2)
    
    -- Register event handler for unit spawning
    world.addEventHandler(onEvent)
    debugMsg("Event handler registered for crate spawn detection")
    
    -- Start the consolidated monitoring system
    timer.scheduleFunction(masterMonitor, {}, timer.getTime() + CONFIG.scan_frequency)
    debugMsg("Master monitoring system started - checking every " .. CONFIG.scan_frequency .. " seconds")
    
    -- Start consolidated crate scanning and monitoring
    timer.scheduleFunction(function()
        scanAndMonitorPlayerCrates()
        return timer.getTime() + CONFIG.monitor_frequency
    end, {}, timer.getTime() + CONFIG.monitor_frequency)
    debugMsg("Consolidated crate monitoring started - checking every " .. CONFIG.monitor_frequency .. " seconds")
    
    -- Schedule periodic cleanup of old groups
    timer.scheduleFunction(function()
        cleanupOldGroups()
        return timer.getTime() + 300  -- Run every 5 minutes
    end, {}, timer.getTime() + 300)
    
    AirDropState.initialized = true

    debugMsg("Air Drop script loaded successfully!", true)
    debugMsg("Event-based crate detection active - containers should be detected when spawned", true)
    debugMsg("Available vehicles: M1 Abrams Tanks, M113 APCs, M1025 HMMWVs", true)
    
    if CONFIG.production_mode then
        debugMsg("Running in PRODUCTION MODE - reduced debug output", true)
    end
    
    debugMsg("Scan frequency: " .. CONFIG.scan_frequency .. "s, Monitor frequency: " .. CONFIG.monitor_frequency .. "s", true)

end

-- Start initialization
initialize()