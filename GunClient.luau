-- Discord: nopr__  Roblox: StasRost
-- Game link: https://www.roblox.com/games/82461444165313/Projectile

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

local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local player = game.Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Constants
local RANDOM = Random.new()
local SPREAD_VELOCITY_MAGNITUDE = 16
local AIM_SPREAD_REDUCE = .3 -- 30% spread reduce
local NORMAL_CAMERA_FOV = 70

local GunClient = {}
GunClient.__index = GunClient

-- Creating GunClient object
function GunClient.new(tool: Tool, settings: {})
	local self = setmetatable({}, GunClient)
	self._maid = Maid.new()
	self._tool = tool
	self._settings = settings
	
	self._isEquipped = false
	self._isReloading = false
	self._currentAmmo = settings.Ammo
	self._currentAmmoInMag = settings.AmmoInMag
	
	self._aimFOV = settings.AimFOV
	self._aimSpeed = settings.AimSpeed
	self._aimAlpha = 0
	self._spreads = settings.Spread
	
	self._reloadTime = settings.ReloadTime
	
	self._firePart = settings.FirePart
	self._fireMode = settings.FireMode
	self._fireRate = settings.FireRate
	self._lastFire = 0
	
	self._animationIds = settings.Animations
	self._animationTracks = {}
	
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
	
	self._firePromise = nil
	
	return self
end

function GunClient:Equip()
	self._isEquipped = true
	
	self._rayParams.FilterDescendantsInstances = {PlayerController:GetCharacter()}
	
	CameraController:ToggleThirdPerson(true)
	
	UserInputService.MouseIconEnabled = false

  -- Stop all AnimationTracks
	self._maid:GiveTask(function()
		for _, animTrack in pairs(self._animationTracks) do
			animTrack:Stop()
		end
	end)
	
	local humanoid = PlayerController:GetHumanoid()
	if not humanoid then return end
	
	local equipAnim = self:_getAnimationTrack(humanoid, "Equip")
	if equipAnim then
		equipAnim:Play()
		equipAnim.Ended:Once(function()
          local holdAnim = self:_getAnimationTrack(humanoid, "Hold")
	        if holdAnim then
		          holdAnim:Play()
	        end
      end)
	end
	
	local aimFOV = self._aimFOV
	local aimSpeed = self._aimSpeed

  -- For smooth aiming
	self._maid:GiveTask(RunService.RenderStepped:Connect(function(dt)
		if self._isAiming then
			self._aimAlpha = math.clamp(self._aimAlpha + dt / aimSpeed, 0, 1)
		else
			self._aimAlpha = math.clamp(self._aimAlpha - dt / aimSpeed, 0, 1)
		end

		camera.FieldOfView = NORMAL_CAMERA_FOV + (aimFOV - NORMAL_CAMERA_FOV) * self._aimAlpha
	end))
end

function GunClient:Unequip()
	self:_onUnequip()
end

function GunClient:Fire(_, inputState, _)
	if not self._isEquipped then return end
	
	if inputState == Enum.UserInputState.Begin then
    -- Cancel _firePromise with fire loop (for Burst / Auto fireMode)
		self:_cancelActivePromise("_firePromise")
		
		if self._fireMode == "Single" then
			self:_fire(UserInputService:GetMouseLocation())
		elseif self._fireMode == "Burst" then

      -- Run Burst fireMode loop
			self._firePromise = Promise.new(function()
				for _ = 1, 3 do
					self:_fire(UserInputService:GetMouseLocation())
					task.wait(60/self._fireRate)
				end
			end)
			
		elseif self._fireMode == "Auto" then

      -- Run Auto fireMode loop
			self._firePromise = Promise.new(function()
				while true do
					self:_fire(UserInputService:GetMouseLocation())
					task.wait(60/self._fireRate)
				end
			end)
			
		end
	elseif inputState == Enum.UserInputState.End then
    -- End fire loop (if exists)
		self:_cancelActivePromise("_firePromise")
	end
end

-- Just aiming
function GunClient:Aim(_, inputState, _)
	if not self._isEquipped then return end
	
	local humanoid = PlayerController:GetHumanoid()
	if not humanoid then return end
	
	local aimAnim = self:_getAnimationTrack(humanoid, "Aim")
	
	if inputState == Enum.UserInputState.Begin then
		if self._isReloading then return end
		
		self._isAiming = true
		aimAnim:Play()
	elseif inputState == Enum.UserInputState.End then
		self._isAiming = false
		aimAnim:Stop()
	end
end

function GunClient:Reload(_, inpuState, _)
	if inpuState ~= Enum.UserInputState.End then return end
	
	if not self._isEquipped then return end
	if self._isReloading then return end
	
	if self._currentAmmoInMag == self._settings.AmmoInMag then return end
	if self._currentAmmo <= 0 then return end
	
	local humanoid = PlayerController:GetHumanoid()
	if not humanoid then return end
	
	local reloadAnim = self:_getAnimationTrack(humanoid, "Reload", true)
	if not reloadAnim then return end
	
	if self._isAiming then
		self._isAiming = false
		local aimAnim = self:_getAnimationTrack(humanoid, "Aim")
		if aimAnim then aimAnim:Stop() end
	end
	
	local startReload = workspace:GetServerTimeNow()
	
	reloadAnim.Stopped:Once(function()
		local timeElapsed = (workspace:GetServerTimeNow() - startReload)

      -- check for full reloadTime passed and calculate ammo to reload
		if timeElapsed >= self._reloadTime * .8 then
			local ammoToRefil = ((self._currentAmmoInMag + self._currentAmmo) >= self._settings.AmmoInMag and self._settings.AmmoInMag - self._currentAmmoInMag) or self._currentAmmo
			
			self._currentAmmo = math.max(0, self._currentAmmo - ammoToRefil)
			self._currentAmmoInMag = ammoToRefil + self._currentAmmoInMag
		end
		
		self._isReloading = false
		
		-- End reloading on Server
		Network:FireServer("GunReload", self._tool, "End")
	end)
	
	self._isReloading = true
	reloadAnim:Play(nil, nil, reloadAnim.Length / self._reloadTime)
	
	-- Start reloading on Server
	Network:FireServer("GunReload", self._tool, "Start")
end

function GunClient:Destroy()
	self:_onUnequip()
	setmetatable(self, nil)
end

function GunClient:_onUnequip()
	self._isEquipped = false
	self._isReloading = false
	self._isAiming = false
	
	CameraController:ToggleThirdPerson(false)
	
	UserInputService.MouseIconEnabled = true

  -- Cancel promises and clean all maid things
	self:_cancelActivePromise("_firePromise")
	self._maid:Destroy()
end

-- Get loaded AnimationTrack or load new
function GunClient:_getAnimationTrack(humanoid, animationName, waitForAnim)
	if self._animationTracks[animationName] then
		return self._animationTracks[animationName]
	end
	
	local animator = humanoid:FindFirstChild("Animator")
	if not animator then return end

	local animationId = self._animationIds[animationName]
	if not animationId then return end
	
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId
	
	local track = animator:LoadAnimation(animation)

  -- Wait for track.Length load
	if waitForAnim then
		repeat
			task.wait()
		until track.Length > 0
	end
	
	self._animationTracks[animationName] = track
	
	return track
end

function GunClient:_fire(inputPosition)
  -- Fire rate check
	if (workspace:GetServerTimeNow() - self._lastFire) < (60/self._fireRate) then return end
	self._lastFire = workspace:GetServerTimeNow()

  -- Ammo check. If false then stop _firePromise loop
	if self._currentAmmoInMag <= 0 or self._isReloading then
		self:_cancelActivePromise("_firePromise")
		return
	end
	self._currentAmmoInMag -= 1
	
	local rootPart = PlayerController:GetRootPart()
	if not rootPart then return end
	local rootVelocity = rootPart.AssemblyLinearVelocity
	
	local guid = HttpService:GenerateGUID(false)

  -- Get click position from inputPosition using workspace:Raycast()  
	local clickPos = inputPosition
	local ray = camera:ViewportPointToRay(clickPos.X, clickPos.Y)
	local origin = self._firePart.Position
	local raycast = workspace:Raycast(ray.Origin, ray.Direction * 1000, self._rayParams)
	local direction
	
	if raycast then
		direction = (raycast.Position - origin).Unit
	else
		direction = ((ray.Origin + ray.Direction * 1000) - origin).Unit
	end

  -- Set spread mode: Idle, Moving, Jumping
	local spread = self._spreads.Idle
	
	if (rootVelocity * Vector3.yAxis).Magnitude >= 1 then
		spread = self._spreads.Jumping
		spread = spread * math.min(3, (rootVelocity.Magnitude/SPREAD_VELOCITY_MAGNITUDE)) -- adjust speed based on rootVelocity
	elseif rootVelocity.Magnitude >= .5 then
		spread = self._spreads.Moving
		spread = spread * math.min(3, (rootVelocity.Magnitude/SPREAD_VELOCITY_MAGNITUDE)) -- adjust speed based on rootVelocity
	end
	
	spread = spread - (spread * (AIM_SPREAD_REDUCE * self._aimAlpha)) -- decrease spread based on _aimAlpha
	direction = (CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles(math.rad(RANDOM:NextNumber(-spread, spread)), math.rad(RANDOM:NextNumber(-spread, spread)), 0)).LookVector

	local speed = self._settings.ProjectileSpeed
	local acceleration = self._settings.Acceleration
	local projectilePart = self._settings.ProjectilePart
	local hitFunc = self._settings.Projectile_Hit_Function
	local stepFunc = self._settings.Projectile_Step_Function
	local fireTime = workspace:GetServerTimeNow()

  -- Spawn client-side projectile
	Projectile:SpawnProjectile(player, guid, origin, direction, speed, acceleration, projectilePart, self._rayParams, hitFunc, stepFunc)
	
	CameraController:DoRecoil(self._settings.Recoil.X, self._settings.Recoil.Y)
	
	local humanoid = PlayerController:GetHumanoid()
	if humanoid then
		local fireAnim = self:_getAnimationTrack(humanoid, "Fire")
		if fireAnim then fireAnim:Play() end
	end

  -- Send server fire info
	Network:FireServer("GunFire", self._tool, guid, self._firePart, origin, direction, fireTime)
end

function GunClient:_cancelActivePromise(promiseName)
	local promise = self[promiseName]
	if promise and promise:getStatus() == Promise.Status.Started then
		promise:cancel()
		self[promiseName] = nil
	end
end

return GunClient
