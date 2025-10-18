-- Air Drop 0.2 By Burning Skies MYTH
-- Pure DCS Lua
-- Description: This script adds Air Drop radio commands that will spawn C-130's and deliver units to a designated
--              map marker to drop cargo.

-- To use this script:
-- 1. Place it in your mission's MISSION SCRIPTS folder
-- 2. Load the script in the mission editor using the "Do Script" action
-- 3. Use the radio menu to call in drops
-- 4. Place map markers named "dp-alpha", "dp-bravo", etc. for drop zones (these are generated dynamically)
-- 5. Get good.


-- =====================================================================================
-- CONFIG (Editable Section)
-- =====================================================================================

local CONFIG = {
    debug = true,  -- Set to false to disable debug messages
    
    -- Aircraft settings
    aircraft_type = "C-130",  -- Aircraft type to spawn
    aircraft_fallback = "KC130",  -- Fallback if C-130 not available
    spawn_altitude = 1000,    -- Altitude in meters (approximately 3280 feet)
    cruise_speed = 130,       -- Speed in m/s (approximately 250 knots)
    
    -- Cargo settings
    cargo_types = {
        ["Tank"] = {
            name = "M1 Abrams Tank",
            type = "M-1 Abrams",
            mass = 60000  -- Mass in kg for an M1 Abrams
        },
        ["APC"] = {
            name = "M113 APC",
            type = "M-113",
            mass = 11000  -- Mass in kg for an M113
        },
        ["Humvee"] = {
            name = "M1025 HMMWV",
            type = "Hummer",
            mass = 2400   -- Mass in kg for a HMMWV
        }
    }
}


-- =====================================================================================
-- DEBUG FUNCTIONS
-- =====================================================================================

-- Debug function that outputs to both log and players if debug is enabled
local function debugMsg(message)
    env.info("[Air Drop] " .. message)
    if CONFIG.debug then
        trigger.action.outText(message, 10)
    end
end


-- =====================================================================================
-- STATE MANAGEMENT
-- =====================================================================================

local AirDropState = {
    spawnedGroups = {},        -- Track all spawned aircraft groups: [groupName] = { group, spawnTime }
    activeDrops = {},          -- Track active drop missions: [groupName] = { markerName, vehicleType, qty, status, spawnTime }
    groupCounter = 0,
    initialized = false,
    pendingDropRequests = {},  -- Store pending drop requests waiting for markers: [markerLabel] = { vehicleType, qty, requestTime }
}


-- =====================================================================================
-- AIR DROP FUNCTIONS
-- =====================================================================================

-- Function to find map marker by name
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
    trigger.action.outText("WARNING: No marker found! Please create a map marker named '" .. markerName .. "'", 15)
    return nil
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
        trigger.action.outText("ERROR: Invalid vehicle type selected!", 10)
        return false
    end
    
    if qty < 2 or qty > 8 or qty % 2 ~= 0 then
        debugMsg("ERROR: Invalid quantity: " .. tostring(qty) .. " (must be 2, 4, 6, or 8)")
        trigger.action.outText("ERROR: Invalid quantity selected! Must be 2, 4, 6, or 8 units.", 10)
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
    
    debugMsg("Generated unique marker label: " .. markerLabel)
    
    -- Store this pending drop request in the state system
    AirDropState.pendingDropRequests[markerLabel] = {
        vehicleType = vehicleType,
        qty = qty,
        aircraftQty = aircraftQty,
        cargoConfig = cargoConfig,
        requestTime = timer.getTime()
    }
    
    -- output the marker so the user can use it.
    trigger.action.outText("Drop requested: " .. qty .. " " .. cargoConfig.name .. "s (" .. aircraftQty .. " C-130s). Create marker: " .. markerLabel, 15)
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
        trigger.action.outText("ERROR: No airport found for spawning!", 15)
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
        trigger.action.outText("C-130 formation (" .. aircraftQty .. " aircraft) inbound from " .. airport.name .. " carrying " .. qty .. " " .. cargoConfig.name .. "s!", 10)
        
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
                                trigger.action.outText("Formation dropping " .. unitsToDeliver .. " " .. unitPlural .. " from " .. survivingAircraft .. " surviving aircraft!", 8)
                                
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
                                            trigger.action.outText("Drop marker cleared - vehicles deployed!", 5)
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
                                    trigger.action.outText("All " .. totalDelivered .. " " .. vehiclePlural .. " delivered successfully!", 10)
                                elseif survivingAircraft > 0 then
                                    local vehiclePlural = totalDelivered == 1 and cargoConfig.name or cargoConfig.name .. "s"
                                    local aircraftPlural = lostAircraft == 1 and "aircraft" or "aircraft"
                                    trigger.action.outText(totalDelivered .. " " .. vehiclePlural .. " delivered (" .. lostAircraft .. " " .. aircraftPlural .. " lost)!", 10)
                                else
                                    trigger.action.outText("No vehicles delivered - all " .. maxAircraft .. " aircraft lost!", 10)
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
                                        trigger.action.outText("C-130 formation RTB (returning to base)", 8)
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
        trigger.action.outText("ERROR: Failed to spawn C-130 aircraft", 10)
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

    debugMsg("Radio menu created with vehicle and quantity options - 'Call Air Drop' menu available")
end


-- =====================================================================================
-- MARKER MONITORING SYSTEM
-- =====================================================================================

-- Timer function to monitor for markers matching pending drop requests
local function monitorPendingDropMarkers()
    -- Check all pending drop requests
    for markerLabel, requestData in pairs(AirDropState.pendingDropRequests) do
        local dropMarker = getMapMarker(markerLabel)
        
        if dropMarker then
            debugMsg("✓ Marker found for pending drop: " .. markerLabel)
            trigger.action.outText("Drop marker detected! Spawning C-130s to " .. markerLabel, 10)
            
            -- Execute the aircraft spawn, passing the markerName
            executeAircraftSpawn(dropMarker, requestData.vehicleType, requestData.qty, markerLabel)
            
            -- Remove this request from pending list
            AirDropState.pendingDropRequests[markerLabel] = nil
        else
            -- Check if request has timed out (5 minutes)
            local requestAge = timer.getTime() - requestData.requestTime
            if requestAge > 300 then
                debugMsg("Drop request timed out: " .. markerLabel)
                trigger.action.outText("Drop request expired: " .. markerLabel, 10)
                AirDropState.pendingDropRequests[markerLabel] = nil
            end
        end
    end
    
    -- Continue monitoring every 3 seconds
    return timer.getTime() + 3
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

    -- Start the marker monitoring system
    timer.scheduleFunction(monitorPendingDropMarkers, {}, timer.getTime() + 3)
    debugMsg("Marker monitoring system started - checking every 3 seconds")
    
    -- Schedule periodic cleanup of old groups
    timer.scheduleFunction(function()
        cleanupOldGroups()
        return timer.getTime() + 300  -- Run every 5 minutes
    end, {}, timer.getTime() + 300)
    
    AirDropState.initialized = true

    debugMsg("Air Drop script loaded successfully!")
    debugMsg("Create a map marker named 'drop' and use F10 radio menu to call in C-130s")
    debugMsg("Available vehicles: M1 Abrams Tanks, M113 APCs, M1025 HMMWVs")

end

-- Start initialization
initialize()