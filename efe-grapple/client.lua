Citizen.CreateThread(function()
  local sin, cos, atan2, abs, rad, deg = math.sin, math.cos, math.atan2, math.abs, math.rad, math.deg
  local EARLY_STOP_MULTIPLIER = 0.5
  local DEFAULT_GTA_FALL_DISTANCE = 8.3
  local DEFAULT_OPTIONS = {waitTime=0.5, grappleSpeed=20.0}

  Grapple = {}

  --[[ Utility Functions ]]
  local function DirectionToRotation(dir, roll)
    local x, y, z
    z = -deg(atan2(dir.x, dir.y))
    local rotpos = vector3(dir.z, #vector2(dir.x, dir.y), 0.0)
    x = deg(atan2(rotpos.x, rotpos.y))
    y = roll
    return vector3(x, y, z)
  end

  local function RotationToDirection(rot)
    local rotZ = rad(rot.z)
    local rotX = rad(rot.x)
    local cosOfRotX = abs(cos(rotX))
    return vector3(-sin(rotZ) * cosOfRotX, cos(rotZ) * cosOfRotX, sin(rotX))
  end

  local function RayCastGamePlayCamera(dist)
    local camRot = GetGameplayCamRot()
    local camPos = GetGameplayCamCoord()
    local dir = RotationToDirection(camRot)
    local dest = camPos + (dir * dist)
    local ray = StartShapeTestRay(camPos, dest, 17, -1, 0)
    local _, hit, endPos, surfaceNormal, entityHit = GetShapeTestResult(ray)
    if hit == 0 then endPos = dest end
    return hit, endPos, entityHit, surfaceNormal
  end

  function GrappleCurrentAimPoint(dist)
    return RayCastGamePlayCamera(dist)
  end

  -- TODO: This can eventually be removed once the logic is fully tested
  local function DrawSphere(pos, radius, r, g, b, a)
    DrawMarker(28, pos, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, radius, radius, radius, r, g, b, a, false, false, 2, nil, nil, false)
  end

  -- Fill in defaults for any options that aren't present
  local function _ensureOptions(options)
    for k, v in pairs(DEFAULT_OPTIONS) do
      if options[k] == nil then options[k] = v end
    end
  end

  local function _waitForFall(pid, ped, stopDistance)
    SetPlayerFallDistance(pid, 10.0)
    while GetEntityHeightAboveGround(ped) > stopDistance do
      SetPedCanRagdoll(ped, false)
      Wait(0)
    end
    SetPlayerFallDistance(pid, DEFAULT_GTA_FALL_DISTANCE)
    Wait(1500)
    SetPedCanRagdoll(ped, true)
  end

  local function PinRope(rope, ped, boneId, dest)
    PinRopeVertex(rope, 0, dest)
    PinRopeVertex(rope, GetRopeVertexCount(rope) - 1, GetPedBoneCoords(ped, boneId, 0.0, 0.0, 0.0))
  end


  function Grapple.new(dest, options)
    local self = {}
    options = options or {}
    _ensureOptions(options)
    local grappleId = math.random((-2^32)+1, 2^32-1)
    if options.grappleId then
      grappleId = options.grappleId
    end
    local pid = PlayerId()
    if options.plyServerId then
      pid = GetPlayerFromServerId(options.plyServerId)
    end
    local ped = GetPlayerPed(pid)
    local start = GetEntityCoords(ped)
    local notMyPed = options.plyServerId and options.plyServerId ~= GetPlayerServerId(PlayerId())
    local fromStartToDest = dest - start
    local dir = fromStartToDest / #fromStartToDest
    local length = #fromStartToDest
    local finished = false
    local rope
    if pid ~= -1 then
      RopeLoadTextures() -- load rope fix
      rope = AddRope(dest, 0.0, 0.0, 0.0, 0.0, 5, 0.0, 0.0, 1.0, false, false, false, 5.0, false)
      if notMyPed then
        local headingToSet = GetEntityHeading(ped)
        ped = ClonePed(ped, 0, 0, 0)
        SetEntityHeading(ped, headingToSet)
        NetworkConcealPlayer(pid, true, false)
      end
    end

    local function _setupDestroyEventHandler()
      local event = nil
      local eventName = 'mka-grapple:ropeDestroyed:' .. tostring(grappleId)
      RegisterNetEvent(eventName)
      event = AddEventHandler(eventName, function()
        self.destroy(false)
        RemoveEventHandler(event)
      end)
    end

    function self._handleRope(rope, ped, boneIndex, dest)
      Citizen.CreateThread(function ()
        while not finished do
          PinRope(rope, ped, boneIndex, dest)
          Wait(0)
        end
        DeleteChildRope(rope)
        DeleteRope(rope)
      end)
    end

    function self.activateSync()
      if pid == -1 then return end
      local distTraveled = 0.0
      local currentPos = start
      local lastPos = currentPos
      local rotationMultiplier = notMyPed == true and -1 or 1
      local rot = DirectionToRotation(-dir * rotationMultiplier, 0.0)
      local lastRot = rot
      -- Offset pitch 90 degrees so player is facedown
      rot = rot + vector3(90.0 * rotationMultiplier, 0.0, 0.0)
      Wait(options.waitTime * 1000)
      while not finished and distTraveled < length do
        local fwdPerFrame = dir * options.grappleSpeed * GetFrameTime()
        distTraveled = distTraveled + #fwdPerFrame
        if distTraveled > length then
          distTraveled = length
          currentPos = dest
        else
          currentPos = currentPos + fwdPerFrame
        end
        SetEntityCoords(ped, currentPos)
        SetEntityRotation(ped, rot)
        if distTraveled > 3 and HasEntityCollidedWithAnything(ped) == 1 then
          SetEntityCoords(ped, lastPos - (dir * EARLY_STOP_MULTIPLIER))
          SetEntityRotation(ped, lastRot)
          break
        end
        lastPos = currentPos
        lastRot = rot
        Wait(0)
      end
      self.destroy()
      _waitForFall(pid, ped, 3.0)
    end

    function self.activate()
      CreateThread(self.activateSync)
    end

    function self.destroy(shouldTriggerDestroyEvent)
      finished = true
      if pid ~= -1 and notMyPed then
        DeleteEntity(ped)
        NetworkConcealPlayer(pid, false, false)
      end
      if shouldTriggerDestroyEvent or shouldTriggerDestroyEvent == nil then
        -- Should trigger if shouldTriggerDestroyEvent is true or nil (not passed)
        TriggerServerEvent('mka-grapple:destroyRope', grappleId)
      end
    end

    if pid ~= -1 then
      self._handleRope(rope, ped, 0x49D9, dest)
      if notMyPed then
        self.activate()
      end
    end
    if options.plyServerId == nil then
      TriggerServerEvent('mka-grapple:createRope', grappleId, dest)
    else
      _setupDestroyEventHandler()
    end
    return self
  end

  --[[ Test Stuff ]]
  -- Citizen.CreateThread(function ()
  --   while true do
  --     local hit, pos, _, _ = RayCastGamePlayCamera(40)
  --     if hit == 1 then
  --       DrawSphere(pos, 0.1, 255, 0, 0, 255)
  --       if IsControlJustReleased(0, 51) then
  --         local grapple = Grapple.new(pos)
  --         grapple.activate()
  --       end
  --     end
  --     Wait(0)
  --   end
  -- end)

  local grappleGunHash = 177293209
  local grappleGunTintIndex = 2
  local grappleGunSuppressor = "COMPONENT_AT_AR_SUPP_02"
  local grappleGunEquipped = false
  local shownGrappleButton = false


RegisterCommand("grapple", function ()
  TriggerEvent("mka-grapple:useGrapple")
end)

  RegisterNetEvent('mka-grapple:useGrapple')
  AddEventHandler('mka-grapple:useGrapple', function(item)
    grappleGunEquipped = not grappleGunEquipped
    if grappleGunEquipped then
      GiveWeaponToPed(PlayerPedId(), grappleGunHash, 0, 0, 1)
      GiveWeaponComponentToPed(PlayerPedId(), grappleGunHash, grappleGunSuppressor)
      SetPedWeaponTintIndex(PlayerPedId(), grappleGunHash, 2)
      SetAmmoInClip(PlayerPedId(), grappleGunHash, 1)
    else
      RemoveWeaponFromPed(PlayerPedId(), grappleGunHash)
    end
    local ply = PlayerId()
    Citizen.CreateThread(function()
      while grappleGunEquipped do
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if (veh and veh ~= 0) or GetSelectedPedWeapon(PlayerPedId()) ~= grappleGunHash then
          grappleGunEquipped = false
          RemoveWeaponFromPed(PlayerPedId(), grappleGunHash)
          return
        end
        local freeAiming = IsPlayerFreeAiming(ply)
        local hit, pos, _, _ = GrappleCurrentAimPoint(4000)
        if not shownGrappleButton and freeAiming and hit == 1 then
          shownGrappleButton = true
          Citizen.Wait(250)
          --exports["aw3-ui"]:showInteraction('[E] Grapple!', 'inform') 
               exports['qb-drawtext']:DrawText('[E] Grapple','left') 
        elseif shownGrappleButton and (not freeAiming or hit ~= 1) then
          shownGrappleButton = false
          exports["aw3-ui"]:hideInteraction()
        end
        if IsControlJustReleased(0, 51) and freeAiming and grappleGunEquipped then
          hit, pos, _, _ = GrappleCurrentAimPoint(4000)
          --exports["aw3-ui"]:hideInteraction()
                exports['qb-drawtext']:HideText()
          if hit == 1 then
             --exports["aw3-ui"]:hideInteraction() 
                  exports['qb-drawtext']:HideText()
            grappleGunEquipped = false
            -- mCore.functions.playSound('grapple', 0.5)
            Citizen.Wait(50)
            local grapple = Grapple.new(pos, { waitTime = 1.5 })
            grapple.activate()
            Citizen.Wait(50)
            -- TriggerServerEvent('mka-grapple:updateAmmo', item)
            RemoveWeaponFromPed(PlayerPedId(), grappleGunHash)
            shownGrappleButton = false
          end
        end
        Citizen.Wait(0)
      end
    end)
  end)

  RegisterNetEvent('mka-grapple:ropeCreated')
  AddEventHandler('mka-grapple:ropeCreated', function(grappleId, dest)
    if plyServerId == GetPlayerServerId(PlayerId()) then
      return
    end
    TriggerServerEvent("InteractSound:PlayOnSource", "grapple-shot", 0.5) -- change this line, bcz my interact sound is suck
    Grapple.new(dest, {plyServerId=GetPlayerServerId(PlayerId()), grappleId=grappleId})
    -- TriggerServerEvent('mka-grapple:sil')
  end)
end)
