-- Discord: nopr__  Roblox: StasRost
-- Game link: https://www.roblox.com/games/82461444165313/Projectile

--[[
This is a BETA gun system, so some checks were skipped because I'm lazy (for example, the player can shoot even when the humanoid is dead).
However, the gun system itself works without errors on both the client and the server.

I apologize for my English; I am using a translator.
]]

-- Services
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

-- Controllers
local PlayerController = require(script.Parent.Parent.PlayerController)
local CameraController = require(script.Parent.Parent.CameraController)

-- Utils
local Network = require(ReplicatedStorage.Modules.Network)
local Projectile = require(ReplicatedStorage.Modules.Projectile)
local Maid = require(ReplicatedStorage.Modules.Utils.Maid)
local Promise = require(ReplicatedStorage.Modules.Utils.Promise)

local player = game.Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Constants
local RANDOM = Random.new()
local SPREAD_VELOCITY_MAGNITUDE = 16
local AIM_SPREAD_REDUCE = .3 -- 30% spread reduce
local NORMAL_CAMERA_FOV = 70

local GunClient = {}
GunClient.__index = GunClient

-- Creating GunClient object and setup gun settings
function GunClient.new(tool: Tool, settings: {})
	local self = setmetatable({}, GunClient)
	self._maid = Maid.new()
	self._tool = tool
	self._settings = settings -- dictionary that contains all gun info

	self._isEquipped = false
	self._isReloading = false
	self._currentAmmo = settings.Ammo
	self._currentAmmoInMag = settings.AmmoInMag

	self._aimFOV = settings.AimFOV
	self._aimSpeed = settings.AimSpeed
	self._aimAlpha = 0 -- using for Spread reduce and FieldOfView (increase, decrease)
	self._spreads = settings.Spread -- dictionary of Spread Modes {[string]: number}

	self._reloadTime = settings.ReloadTime

	self._firePart = settings.FirePart
	self._fireMode = settings.FireMode
	self._fireRate = settings.FireRate
	self._lastFire = 0

	self._animationIds = settings.Animations
	self._animationTracks = {} -- using for caching loaded AnimationTracks

	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude

	self._firePromise = nil

	return self
end

function GunClient:Equip()
	-- _isEquipped using for checks, like: canFire? canReload?, etc.
	self._isEquipped = true

	-- _rayParams for use in Projectile:CreateProjectile(..., self._rayParams)
	self._rayParams.FilterDescendantsInstances = {PlayerController:GetCharacter()} -- Add LocalPlayer's Character Model to ignore list

	-- Toggle third person camera
	CameraController:ToggleThirdPerson(true)

	-- Disable mouse icon (if we want custom crosshair)
	UserInputService.MouseIconEnabled = false

	-- Stop all AnimationTracks and set properties to default on _maid:Destroy()
	-- _maid for handy cleaning; prevents memory leaks
	self._maid:GiveTask(function()	
		camera.FieldOfView = NORMAL_CAMERA_FOV
		
		-- Remove third person camera
		CameraController:ToggleThirdPerson(false)

		-- show mouse icon
		UserInputService.MouseIconEnabled = true
		
		for _, animTrack in pairs(self._animationTracks) do -- Get all cached AnimationTrack
			animTrack:Stop() -- Stop AnimationTrack from playing
		end
	end)

	-- Get LocalPlayer's Humanoid
	local humanoid = PlayerController:GetHumanoid()
	if not humanoid then return end

	local equipAnim = self:_getAnimationTrack(humanoid, "Equip") -- Get "Equip" Animation Track
	local holdAnim = self:_getAnimationTrack(humanoid, "Hold") -- Get "Hold" Animation Track
	if equipAnim then
		equipAnim:Play()
		equipAnim.Ended:Once(function() -- Fire function once equipAnim ended playing
			if not self._isEquipped then return end -- Do not play the "Hold" animation if the weapon is not equipped
			holdAnim:Play()
		end)
	else -- Play the "Hold" animation immediately if the "Equip" animation was not found
		holdAnim:Play()
	end

	local aimFOV = self._aimFOV
	local aimSpeed = self._aimSpeed

	-- For smooth aiming
	-- _maid for handy cleaning; prevents memory leaks
	self._maid:GiveTask(RunService.RenderStepped:Connect(function(dt) -- Add .RenderStepped connection to self._maid
		if self._isAiming then
			-- if self._isAiming then increase self._aimAlpha
			self._aimAlpha = math.clamp(self._aimAlpha + dt / aimSpeed, 0, 1)
		else
			-- if self._isAiming then decrease self._aimAlpha
			self._aimAlpha = math.clamp(self._aimAlpha - dt / aimSpeed, 0, 1)
		end
		-- Change camera FOV (Lerp)
		camera.FieldOfView = NORMAL_CAMERA_FOV + (aimFOV - NORMAL_CAMERA_FOV) * self._aimAlpha
	end))
end

function GunClient:Unequip()
	-- fire :_onUnequip(), because player unequip gun
	self:_onUnequip()
end

-- This method fires on ContextActionService's action
function GunClient:Fire(_, inputState, _)
	if not self._isEquipped then return end

	if inputState == Enum.UserInputState.Begin then
		-- Cancel _firePromise with fire loop (for Burst / Auto fireMode)
		self:_cancelActivePromise("_firePromise")

		if self._fireMode == "Single" then
			self:_fire(UserInputService:GetMouseLocation()) -- Fire self:_fire() method with current mouse position on the screen
		elseif self._fireMode == "Burst" then

			-- Run Burst fireMode loop
			-- We use Promise because we are calling a loop that we want to stop if something happens (no ammo, gun unequip, etc.)
			self._firePromise = Promise.new(function()
				for _ = 1, 3 do -- Burst Fire Mode = 3 shoots / click
					self:_fire(UserInputService:GetMouseLocation()) -- Fire self:_fire() method with current mouse position on the screen
					task.wait(60/self._fireRate) -- wait for fire cooldown (60 seconds / fireRate)
				end
			end)

		elseif self._fireMode == "Auto" then

			-- Run "Auto FireMode" loop within Promise
			self._firePromise = Promise.new(function()
				-- We use Promise because we are calling a loop that we want to stop if something happens (no ammo, gun unequip, etc.)
				while true do
					self:_fire(UserInputService:GetMouseLocation()) -- Fire self:_fire() method with current mouse position on the screen
					task.wait(60/self._fireRate) -- wait for fire cooldown (60 seconds / fireRate)
				end
			end)

		end
	elseif inputState == Enum.UserInputState.End then -- Player released the left mouse button
		-- cancel active Promise with loop within
		self:_cancelActivePromise("_firePromise")
	end
end

-- This method fires on ContextActionService's action
function GunClient:Aim(_, inputState, _)
	if not self._isEquipped then return end

	local humanoid = PlayerController:GetHumanoid()
	if not humanoid then return end

	-- Get "Aim" AnimationTrack from cache OR load new
	local aimAnim = self:_getAnimationTrack(humanoid, "Aim")

	if inputState == Enum.UserInputState.Begin then -- Player hold RightMouseButton
		if self._isReloading then return end

		-- Start aiming
		self._isAiming = true
		aimAnim:Play()
	elseif inputState == Enum.UserInputState.End then -- Player release RightMouseButton
		-- End Aiming
		self._isAiming = false
		aimAnim:Stop()
	end
end

-- This method fires on ContextActionService's action
function GunClient:Reload(_, inpuState, _)
	if inpuState ~= Enum.UserInputState.End then return end -- Reloading only occurs when the Player presses the R button (not when releasing it)

	if not self._isEquipped then return end
	if self._isReloading then return end

	-- if _currentAmmoInMag is full then we don't need to Reload
	if self._currentAmmoInMag == self._settings.AmmoInMag then return end
	-- if total _currentAmmo less than 0 then we can't Reload because we don't have ammo :(
	if self._currentAmmo <= 0 then return end

	local humanoid = PlayerController:GetHumanoid()
	if not humanoid then return end

	-- Get "Reload" AnimationTrack from cache OR load new
	local reloadAnim = self:_getAnimationTrack(humanoid, "Reload", true)
	if not reloadAnim then return end -- return, because ALL weapons must have an "Reload" Animation

	-- If Player is aiming, we must stop aiming during the Reload
	if self._isAiming then
		self._isAiming = false

		-- Get "Reload" AnimationTrack from cache
		local aimAnim = self:_getAnimationTrack(humanoid, "Aim")
		if aimAnim then aimAnim:Stop() end -- if we get it then stop "Aim" AnimationTrack from playing
	end

	-- Get time of Reload start for further use in Reload Time Check
	local startReload = workspace:GetServerTimeNow()

	-- This function fires once when reloadAnim has stopped (:Once(), because we don't want the connection from .Stopped to remain in memory)
	reloadAnim.Stopped:Once(function()
		local timeElapsed = (workspace:GetServerTimeNow() - startReload) -- Get time elapsed since the start of the Reload

		-- check for full self._reloadTime passed and calculate ammo to reload
		-- * .8 - forgiveness (reload if passed 80% of _reloadTime)
		if timeElapsed >= self._reloadTime * .8 then
			--The variable at the bottom calculates how many ammo need to be reloaded (if there are ammo remaining in the mag, fewer ammo are required for the Reload).
			local ammoToRefil = ((self._currentAmmoInMag + self._currentAmmo) >= self._settings.AmmoInMag and self._settings.AmmoInMag - self._currentAmmoInMag) or self._currentAmmo

			self._currentAmmo = math.max(0, self._currentAmmo - ammoToRefil) -- math.max() is used to ensure that the ammo count does not drop below 0
			self._currentAmmoInMag = ammoToRefil + self._currentAmmoInMag -- refill ammo in mag
		end

		self._isReloading = false -- indicates that the Player has ended Reloading

		-- Fire RemoteEvent on the Server to signal the ending of the Reload
		Network:FireServer("GunReload", self._tool, "End")
	end)

	self._isReloading = true -- indicates that the Player has started Reloading
	reloadAnim:Play(nil, nil, reloadAnim.Length / self._reloadTime) -- Play "Reload" AnimationTrack at a speed corresponding to the self._reloadTime

	-- Fire RemoteEvent on the Server to signal the start of the Reload
	Network:FireServer("GunReload", self._tool, "Start")
end

function GunClient:Destroy()
	self:_onUnequip()
	-- cleaning object's metatable, so we can't use GunClient methods in future for this object
	setmetatable(self, nil)
end

function GunClient:_onUnequip()
	self._isEquipped = false
	self._isReloading = false
	self._isAiming = false

	-- Cancel active "_firePromise" promise and clean all maid things to prevent memory leaks
	self:_cancelActivePromise("_firePromise")
	self._maid:Destroy()
end

-- Get loaded AnimationTrack from cache or load new
function GunClient:_getAnimationTrack(humanoid, animationName, waitForAnim)
	if self._animationTracks[animationName] then
		-- if we found AnimationTrack in cache then return it
		return self._animationTracks[animationName]
	end

	local animator = humanoid:FindFirstChild("Animator")
	if not animator then return end

	local animationId = self._animationIds[animationName] -- Find the animation ID in the self._animationIds dictionary
	if not animationId then return end -- if not found, return

	local animation = Instance.new("Animation") -- Create Animation instance for further load via :LoadAnimation()
	animation.AnimationId = animationId

	local track = animator:LoadAnimation(animation) -- Load AnimationTrack

	-- Wait for track.Length load if (waitForAnim == true)
	if waitForAnim then
		repeat
			task.wait()
		until track.Length > 0
	end

	-- cache AnimationTrack to dictionary
	self._animationTracks[animationName] = track

	return track
end

function GunClient:_fire(inputPosition)
	-- Fire rate check
	if (workspace:GetServerTimeNow() - self._lastFire) < (60/self._fireRate) then return end
	self._lastFire = workspace:GetServerTimeNow() -- Set _lastFire to current server time

	-- If _currentAmmoInMag <= 0 OR Player start Reloading then we need to stop ACTIVE _firePromise loop
	if self._currentAmmoInMag <= 0 or self._isReloading then
		self:_cancelActivePromise("_firePromise")
		return -- We don't want the code to run further, so we use return
	end
	self._currentAmmoInMag -= 1 -- subtract 1 ammo from mag

	-- Get Player's HumanoidRootPart and HumanoidRootPart.AssemblyLinearVelocity for further use
	local rootPart = PlayerController:GetRootPart()
	if not rootPart then return end
	local rootVelocity = rootPart.AssemblyLinearVelocity

	-- Generate GUID for projectile (so we can find projectile with GUID)
	local guid = HttpService:GenerateGUID(false)

	local clickPos = inputPosition
	local ray = camera:ViewportPointToRay(clickPos.X, clickPos.Y) -- Convert clickPos to Ray in the world
	local origin = self._firePart.Position -- Get tool's FirePart position
	local raycast = workspace:Raycast(ray.Origin, ray.Direction * 1000, self._rayParams) -- Cast Ray from camera to clickPosition (The Ray is emitted from the Camera's position)
	local direction -- normalized vector

	if raycast then
		-- if we hit something then get direction from _firePart.Position to raycast.Position
		direction = (raycast.Position - origin).Unit
	else
		-- if we don't hit anything then get direction from _firePart.Position to the end of the Ray
		direction = ((ray.Origin + ray.Direction * 1000) - origin).Unit
	end

	-- Set spread mode: Idle, Moving, Jumping
	local spread = self._spreads.Idle

	-- First of all, you need to check here whether the Player is jumping
	if (rootVelocity * Vector3.yAxis).Magnitude >= 1 then -- if rootVelocity.Y >= 1 then Player jumps
		spread = self._spreads.Jumping -- set spread to "Jumping" value
		spread = spread * math.min(3, (rootVelocity.Magnitude/SPREAD_VELOCITY_MAGNITUDE)) -- multiply the spread based on the Сharacter's rootVelocity
	elseif rootVelocity.Magnitude >= .5 then -- if rootVelocity.Magnitude >= .5 then Player moves
		spread = self._spreads.Moving -- set spread to "Moving" value
		spread = spread * math.min(3, (rootVelocity.Magnitude/SPREAD_VELOCITY_MAGNITUDE)) -- multiply the spread based on the Сharacter's rootVelocity
	end
	-- decrease spread based on _aimAlpha (the higher the _aimAlpha, the lower the spread)
	spread = spread - (spread * (AIM_SPREAD_REDUCE * self._aimAlpha))
	-- apply spread to direction using CFrame.Angles()
	direction = (CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles(math.rad(RANDOM:NextNumber(-spread, spread)), math.rad(RANDOM:NextNumber(-spread, spread)), 0)).LookVector

	-- Get constants for projectile
	local speed = self._settings.ProjectileSpeed
	local acceleration = self._settings.Acceleration
	local projectilePart = self._settings.ProjectilePart
	local hitFunc = self._settings.Projectile_Hit_Function
	local stepFunc = self._settings.Projectile_Step_Function

	local fireTime = workspace:GetServerTimeNow() -- Get projectile spawn time
	Projectile:SpawnProjectile(player, guid, origin, direction, speed, acceleration, projectilePart, self._rayParams, hitFunc, stepFunc) -- Spawn projectile with all the necessary info

	-- Give the camera a recoil effect
	CameraController:DoRecoil(self._settings.Recoil.X, self._settings.Recoil.Y)

	local humanoid = PlayerController:GetHumanoid()
	if humanoid then
		-- get "Fire" AnimationTrack from cache or load new
		local fireAnim = self:_getAnimationTrack(humanoid, "Fire")
		if fireAnim then fireAnim:Play() end -- if found then play AnimationTrack
	end

	-- Send fire info to Server via RemoteEvent (in custom Network module)
	Network:FireServer("GunFire", self._tool, guid, self._firePart, origin, direction, fireTime)
end

-- Get active Promise and cancel it
function GunClient:_cancelActivePromise(promiseName)
	local promise = self[promiseName]
	if promise and promise:getStatus() == Promise.Status.Started then -- if we found promise and it is active, we will cancel it
		promise:cancel()
		self[promiseName] = nil -- remove the reference to Promise in our GunClient object
	end
end

return GunClient
