--[[
	Uma2Roblox Studio plugin
	Install: Studio > Plugins tab > Plugins Folder, copy this file there, then close and reopen the place.

	As soon as an Uma_<id>_<costume>_*.glb is imported with File > Import 3D, the plugin fits its RootPart,
	fixes cheek/mayu transparency and imports its animations (each step has its option). Then:
	  * select the imported model(s) and click "Apply Uma Toon"
	      - CastShadow off on every MeshPart (no shadows from the model)
	      - SmoothPlastic, no reflectance; the GLB's normals already point up, so Roblox
	        lighting is uniform and the baked anime cel shading shows unchanged
	      - outline hull parts made non-collidable / non-queryable
	      - model turned to face Roblox's front (-Z) and scaled to the target height
	      - RootPart fitted to the body (soles to top of head, head-wide), pivot at the soles
	      - tagged with UmaCharaId / UmaCostume attributes
	  * with "Import its mini animations" on, import and Apply build KeyframeSequences from the
	    animations the app ported, into the ServerStorage.RBX_ANIMSAVES folder linked to that rig
	    (Animation Editor)
	  * "Integrate SmartBone 2 into this place" sets up SmartBone 2 spring physics (hair, tail, skirt...):
	      - takes the SmartBone 2 library from the selection (point it out in the Explorer), from anywhere in
	        the place, or inserts it from the asset id entered in the panel; moves it to ReplicatedStorage
	      - writes StarterPlayerScripts.UmaChibiSmartBone, which at runtime gives every rig tagged "UmaChibi"
	        SmartBone physics on its Sp_* bones (ears left to their animations)
	      - tags the selected rigs (else every Uma rig in the place) "UmaChibi"; import and Apply tag them too
	  * with "Import the game's swing-bone physics" on, import and Apply also fetch the costume's own CySpring
	    values from the app (per-bone stiffness, drag, gravity, radius, angle limit, and the body colliders
	    each chain collides with); the UmaChibiSmartBone runtime maps them to SmartBone per chain
	  * "Sync with Uma2Roblox app" tells the app which characters are now in this place,
	    so its list only shows characters that still need porting.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Lighting = game:GetService("Lighting")

local SYNC_URL = "http://localhost:34891/uma2roblox"
local SETTINGS_KEY = "Uma2Roblox_Settings_v1"

local TOON_TINT_DEFAULT = 0.6
local TOON_EMISSIVE_DEFAULT = 0.5

local cfg = plugin:GetSetting(SETTINGS_KEY) or {}
cfg.highlightOutline = cfg.highlightOutline or false
if cfg.autoAnimations == nil then
	cfg.autoAnimations = true
end
if cfg.autoTransparency == nil then
	cfg.autoTransparency = true
end
cfg.transparentParts = cfg.transparentParts or "cheek,mayu"
cfg.rootMotionScale = cfg.rootMotionScale or 1
if cfg.smoothBlinks == nil then
	cfg.smoothBlinks = true
end
if cfg.fitOnImport == nil then
	cfg.fitOnImport = true
end
if cfg.tagUmaChibi == nil then
	cfg.tagUmaChibi = true
end
if cfg.importPhysics == nil then
	cfg.importPhysics = true
end
cfg.smartBoneAssetId = tonumber(cfg.smartBoneAssetId) or 0
if cfg.includeFaceLock == nil then
	cfg.includeFaceLock = true
end
if cfg.playableRig == nil then
	cfg.playableRig = true
end
if cfg.toonLight == nil then
	cfg.toonLight = true
end
cfg.toonTint = tonumber(cfg.toonTint) or TOON_TINT_DEFAULT
cfg.toonEmissive = tonumber(cfg.toonEmissive) or TOON_EMISSIVE_DEFAULT
cfg.emissiveMaskId = tonumber(cfg.emissiveMaskId) or 0
local function saveSettings()
	plugin:SetSetting(SETTINGS_KEY, cfg)
end

---------------------------------------------------------------- helpers
local function parseName(name)
	local id, costume = string.match(name, "^Uma_(%d+)_(%w+)")
	return id and tonumber(id), costume
end

local function selectedModels()
	local found, seen = {}, {}
	for _, inst in ipairs(Selection:Get()) do
		local m = inst
		if not m:IsA("Model") then
			m = inst:FindFirstAncestorWhichIsA("Model")
		end
		-- climb to the outermost model that still looks like an Uma import
		while m and m.Parent and m.Parent:IsA("Model") and parseName(m.Parent.Name) do
			m = m.Parent
		end
		if m and not seen[m] then
			seen[m] = true
			table.insert(found, m)
		end
	end
	return found
end

local function record(name, fn)
	local ok, id = pcall(function()
		return ChangeHistoryService:TryBeginRecording(name)
	end)
	local success, err = pcall(fn)
	if ok and id then
		ChangeHistoryService:FinishRecording(id, Enum.FinishRecordingOperation.Commit)
	else
		ChangeHistoryService:SetWaypoint(name)
	end
	if not success then
		warn("[Uma2Roblox] " .. tostring(err))
	end
end

-- Roblox draws a part with Transparency 0 in the opaque pass, where a texture's alpha only
-- cuts out hard (or shows the background colour). Any Transparency > 0 moves it to the
-- transparent pass, which blends the texture's alpha properly. 0.02 is invisible to the eye.
local TRANSPARENT_PASS = 0.02

local function isTransparentPart(part)
	local n = string.lower(part.Name)
	for word in string.gmatch(string.lower(cfg.transparentParts), "[^,%s]+") do
		if string.find(n, word, 1, true) then
			return true
		end
	end
	return false
end

local function fixTransparency(root)
	local n = 0
	local list = root:IsA("BasePart") and { root } or root:GetDescendants()
	for _, d in ipairs(list) do
		if d:IsA("MeshPart") and isTransparentPart(d) and d.Transparency < TRANSPARENT_PASS then
			d.Transparency = TRANSPARENT_PASS
			n += 1
		end
	end
	return n
end

local function isOutline(part)
	return string.find(string.lower(part.Name), "outline") ~= nil
end

-- Roblox's front is -Z of the pivot. Turn the pivot (not the parts) so it agrees with where the face is.
local function faceFront(model)
	local eyes = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and string.find(string.lower(d.Name), "eye") and not isOutline(d) then
			table.insert(eyes, d)
		end
	end
	if #eyes == 0 then
		return
	end
	local pivot = model:GetPivot()
	local bbCf = model:GetBoundingBox()
	local eyePos = Vector3.zero
	for _, e in ipairs(eyes) do
		eyePos += e.Position
	end
	eyePos /= #eyes
	local eyeLocal = pivot:PointToObjectSpace(eyePos)
	local centerLocal = pivot:PointToObjectSpace(bbCf.Position)
	if eyeLocal.Z > centerLocal.Z then
		-- face points to local +Z -> rotate the pivot 180 degrees about Y
		local newPivot = pivot * CFrame.Angles(0, math.pi, 0)
		if model.PrimaryPart then
			model.PrimaryPart.PivotOffset = model.PrimaryPart.CFrame:ToObjectSpace(newPivot)
		else
			model.WorldPivot = newPivot
		end
	end
end

-- The importer's RootPart is a big box around the whole scene, centred on the hip. Fit it to the body instead, as a
-- character's HumanoidRootPart: a slim column (truss-like, square) only as wide as the torso (the distance between
-- the upper arms' roots, not the chibi head or the arms' T-pose span), from ROOT_LIFT of the body's height above
-- the soles up to the top of the head. The gap below is the Humanoid's HipHeight: the legs float over steps
-- instead of catching on them, and the Humanoid still stands the soles on the ground. Bones and joints hang off
-- the RootPart, so their offsets are moved the other way: nothing else moves, and animations stay valid (a pure
-- translation of the root; its rotation is kept). The pivot goes to the soles, so PivotTo puts the feet on the ground.
local ROOT_LIFT = 0.2
local ROOT_NAMES = { "HumanoidRootPart", "RootPart" }

local function rootOf(model)
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	for _, n in ipairs(ROOT_NAMES) do
		local rp = model:FindFirstChild(n)
		if rp and rp:IsA("BasePart") then
			return rp
		end
	end
	return nil
end

local function isHeadPart(part) -- the mini face mesh is the whole head skin: mtl_mchr0001_00_face0
	return string.match(string.lower(part.Name), "_face%d+$") ~= nil
end

local function isBodyPart(part)
	return string.find(string.lower(part.Name), "bdy", 1, true) ~= nil
end

local function isHairPart(part)
	return string.find(string.lower(part.Name), "hair", 1, true) ~= nil
end

local function fitRootToBody(model)
	local rp = rootOf(model)
	if not rp then
		return false
	end
	local rootCf = rp.CFrame
	-- extents in root space of the parts that pass `keep` (box corners)
	local function extents(keep)
		local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d ~= rp and not isOutline(d) and keep(d) then
				local h = d.Size / 2
				for _, sx in ipairs({ -1, 1 }) do
					for _, sy in ipairs({ -1, 1 }) do
						for _, sz in ipairs({ -1, 1 }) do
							local p = rootCf:PointToObjectSpace(d.CFrame:PointToWorldSpace(h * Vector3.new(sx, sy, sz)))
							lo, hi = lo:Min(p), hi:Max(p)
						end
					end
				end
			end
		end
		if lo.X == math.huge then
			return nil
		end
		return lo, hi
	end
	-- everything but hair (and the outline hull, which is pushed out past the mesh)
	local lo, hi = extents(function(d)
		return not isHairPart(d)
	end)
	if not lo then
		return false
	end
	local bodyLo = extents(isBodyPart)
	local sole = bodyLo and bodyLo.Y or lo.Y
	local headLo, headHi = extents(isHeadPart)
	if not headLo then -- no head mesh found: the middle third of the model, full height
		local w = hi - lo
		headLo = Vector3.new(lo.X + w.X / 3, lo.Y, lo.Z + w.Z / 3)
		headHi = Vector3.new(hi.X - w.X / 3, hi.Y, hi.Z - w.Z / 3)
	end
	-- torso width: between the upper arms' roots; without arm bones, half the head
	local width = (headHi.X - headLo.X) / 2
	local armL, armR = model:FindFirstChild("Arm_L", true), model:FindFirstChild("Arm_R", true)
	if armL and armR and armL:IsA("Bone") and armR:IsA("Bone") then
		width = (rootCf:PointToObjectSpace(armL.WorldPosition) - rootCf:PointToObjectSpace(armR.WorldPosition)).Magnitude
	end
	local height = headHi.Y - sole
	local lift = height * ROOT_LIFT
	local size = Vector3.new(width, height - lift, width)
	local center = Vector3.new((headLo.X + headHi.X) / 2, sole + lift + size.Y / 2, (headLo.Z + headHi.Z) / 2)

	local offset = CFrame.new(center)
	local inv = offset:Inverse()
	local oldPivot = model:GetPivot()
	for _, c in ipairs(rp:GetChildren()) do
		if c:IsA("Attachment") then -- includes Bones
			c.CFrame = inv * c.CFrame
		end
	end
	for _, j in ipairs(model:GetDescendants()) do
		if j:IsA("JointInstance") then
			if j.Part0 == rp then
				j.C0 = inv * j.C0
			end
			if j.Part1 == rp then
				j.C1 = inv * j.C1
			end
		end
	end
	rp.Size = size
	rp.CFrame = rootCf * offset
	-- the Animation Editor caches the old joint offsets here and would restore them; it rebuilds this folder
	local cache = model:FindFirstChild("InitialPoses")
	if cache then
		cache:Destroy()
	end
	local newPivot = CFrame.new(rp.CFrame:PointToWorldSpace(Vector3.new(0, -size.Y / 2 - lift, 0))) * oldPivot.Rotation
	if model.PrimaryPart == rp then
		rp.PivotOffset = rp.CFrame:ToObjectSpace(newPivot)
	else
		model.WorldPivot = newPivot
	end
	model:SetAttribute("UmaRootLift", lift / model:GetScale()) -- unscaled: the HipHeight at scale 1
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.HipHeight = lift
	end
	return true
end

-- Alpha-blended face sprites (cheek blush, eyebrows, tears). Eyes and mouth are opaque quads painted with the
-- face's skin around them, so they are lit exactly like the face skin, or their quads show.
local ALPHA_SPRITE_WORDS = { "mayu", "cheek", "tear" }
local function isAlphaSprite(part)
	local n = string.lower(part.Name)
	for _, w in ipairs(ALPHA_SPRITE_WORDS) do
		if string.find(n, w, 1, true) then
			return true
		end
	end
	return false
end

-- Toon light. The app points every normal straight up, so Roblox lights the whole model evenly: the sun hits it
-- flat-on (washed out at the usual Lighting.Brightness of 2-3) and in shade only the blue sky light is left (the
-- grey/blue look). A SurfaceAppearance on each textured part fixes both: its Color darkens the lit side
-- (toonTint), and a low emissive (toonEmissive, with a plain white mask) gives shade a floor in the texture's own
-- colours. Shadows still fall on the rig, just softer. Final colour = texture * tint * (Roblox light + emissive).
-- Alpha sprites keep the plain mesh texture (Transparency 0.02, see fixTransparency): in a SurfaceAppearance their
-- transparent area shows (the cheek quad spans the whole face) and the emissive ignores alpha.
local AssetService = game:GetService("AssetService")

-- One 4x4 white image, uploaded to the user's account the first time it is needed and remembered in the settings.
local function emissiveMask()
	if cfg.emissiveMaskId > 0 then
		return "rbxassetid://" .. cfg.emissiveMaskId
	end
	local ok, result, assetId = pcall(function()
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(4, 4) })
		img:DrawRectangle(Vector2.zero, Vector2.new(4, 4), Color3.new(1, 1, 1), 0, Enum.ImageCombineType.Overwrite)
		return AssetService:CreateAssetAsync(img, Enum.AssetType.Image, {
			Name = "Uma2Roblox emissive mask",
			Description = "Plain white emissive mask for Uma2Roblox toon rigs",
		})
	end)
	if not ok or result ~= Enum.CreateAssetResult.Success or not assetId then
		warn("[Uma2Roblox] could not upload the emissive mask image (" .. tostring(result) .. "); toon light without emissive")
		return nil
	end
	cfg.emissiveMaskId = assetId
	saveSettings()
	return "rbxassetid://" .. assetId
end

-- Returns how many parts got the toon light.
local function applyToonLight(model)
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("MeshPart") and d.TextureID ~= "" and not isOutline(d) then
			table.insert(parts, d)
		end
	end
	if #parts == 0 then
		return 0
	end
	local mask = cfg.toonEmissive > 0 and emissiveMask() or nil
	local tint = Color3.new(cfg.toonTint, cfg.toonTint, cfg.toonTint)
	local n = 0
	for _, p in ipairs(parts) do
		local sa = p:FindFirstChild("UmaToonLight")
		if isAlphaSprite(p) then
			if sa then
				sa:Destroy()
			end
		else
			if not (sa and sa:IsA("SurfaceAppearance")) then
				sa = Instance.new("SurfaceAppearance")
				sa.Name = "UmaToonLight"
			end
			sa.ColorMapContent = Content.fromUri(p.TextureID)
			sa.Color = tint
			sa.EmissiveMaskContent = mask and Content.fromUri(mask) or Content.none
			sa.EmissiveStrength = cfg.toonEmissive
			sa.EmissiveTint = Color3.new(1, 1, 1)
			sa.AlphaMode = Enum.AlphaMode.Overlay
			sa.Parent = p
			n += 1
		end
	end
	return n
end

local function applyToon(model)
	local id, costume = parseName(model.Name)
	local count = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("MeshPart") then
			count += 1
			d.CastShadow = false
			d.Material = Enum.Material.SmoothPlastic
			d.MaterialVariant = ""
			d.Reflectance = 0
			d.CanCollide = false
			d.CanTouch = false
			d.Massless = (d ~= model.PrimaryPart)
			if cfg.autoTransparency and isTransparentPart(d) and d.Transparency < TRANSPARENT_PASS then
				d.Transparency = TRANSPARENT_PASS
			end
			if isOutline(d) then
				d.CanQuery = false
				pcall(function()
					d.DoubleSided = false -- the hull only works with back-face culling
				end)
			end
		elseif d:IsA("SurfaceAppearance") then
			-- keep the baked colour map, drop anything that would add Roblox PBR shading
			pcall(function()
				d.MetalnessMap = ""
				d.NormalMap = ""
				d.RoughnessMap = ""
			end)
		end
	end

	local lit = 0
	if cfg.toonLight then
		lit = applyToonLight(model)
	else -- turned off: back to the plain mesh textures
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("SurfaceAppearance") and d.Name == "UmaToonLight" then
				d:Destroy()
			end
		end
	end

	faceFront(model)
	if fitRootToBody(model) then
		model:SetAttribute("UmaRootFitted", true)
	end

	local hl = model:FindFirstChild("UmaOutlineHighlight")
	if cfg.highlightOutline then
		hl = hl or Instance.new("Highlight")
		hl.Name = "UmaOutlineHighlight"
		hl.FillTransparency = 1
		hl.OutlineTransparency = 0
		hl.OutlineColor = Color3.fromRGB(40, 28, 33)
		hl.DepthMode = Enum.HighlightDepthMode.Occluded
		hl.Parent = model
	elseif hl then
		hl:Destroy()
	end

	if id then
		model:SetAttribute("UmaCharaId", id)
		model:SetAttribute("UmaCostume", costume)
	end
	model:SetAttribute("UmaToon", true)
	if not model:GetAttribute("UmaSource") then
		model:SetAttribute("UmaSource", model.Name) -- the .glb name, used to fetch its animations
	end
	return count, lit
end

---------------------------------------------------------------- animations
-- The app sends, per bone and frame, the bone's world-space *delta* rotation (relative to the pose
-- the model was exported in) and its world position, both in the GLB's coordinate space.
-- Here we fit GLB space -> this model's space from the rest bone positions (any axis flip / scale
-- the importer applied), then turn the world targets into Bone.Transform values in Poses.

local function fetchJson(path)
	local res = HttpService:RequestAsync({ Url = SYNC_URL .. path, Method = "GET" })
	if not res.Success then
		error(string.format("%s%s -> %d %s", SYNC_URL, path, res.StatusCode, res.StatusMessage))
	end
	return HttpService:JSONDecode(res.Body)
end

-- all 24 axis-aligned proper rotations
local AXIS_ROTATIONS = {}
do
	local axes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	for i = 1, 3 do
		for j = 1, 3 do
			if j ~= i then
				for _, si in ipairs({ 1, -1 }) do
					for _, sj in ipairs({ 1, -1 }) do
						local x = axes[i] * si
						local y = axes[j] * sj
						local z = x:Cross(y)
						table.insert(AXIS_ROTATIONS, CFrame.fromMatrix(Vector3.zero, x, y, z))
					end
				end
			end
		end
	end
end

local function collectBones(model)
	local byName, list = {}, {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Bone") then
			table.insert(list, d)
			if not byName[d.Name] then
				byName[d.Name] = d
			end
		end
	end
	return byName, list
end

-- glTF space -> Roblox world: p_roblox = t + R * (s * p_gltf)
local function fitSpace(skeleton, bonesByName)
	local g, p = {}, {}
	for _, b in ipairs(skeleton) do
		local bone = bonesByName[b.name]
		if bone then
			table.insert(g, Vector3.new(b.world[1], b.world[2], b.world[3]))
			table.insert(p, bone.WorldPosition)
		end
	end
	if #g < 3 then
		error("bones of the imported model don't match the exported skeleton")
	end
	local cg, cp = Vector3.zero, Vector3.zero
	for i = 1, #g do
		cg += g[i]
		cp += p[i]
	end
	cg /= #g
	cp /= #p
	local best
	for _, R in ipairs(AXIS_ROTATIONS) do
		local num, den = 0, 0
		for i = 1, #g do
			local a = R:VectorToWorldSpace(g[i] - cg)
			num += a:Dot(p[i] - cp)
			den += a:Dot(a)
		end
		local sc = den > 0 and num / den or 1
		if sc > 0 then
			local err = 0
			for i = 1, #g do
				local d = (p[i] - cp) - R:VectorToWorldSpace(g[i] - cg) * sc
				err += d:Dot(d)
			end
			if not best or err < best.err then
				best = { R = R, s = sc, err = err }
			end
		end
	end
	best.t = cp - best.R:VectorToWorldSpace(cg * best.s)
	return best
end

local function boneOrder(list)
	-- parents before children
	local depth = {}
	local function d(b)
		if depth[b] then
			return depth[b]
		end
		local p = b.Parent
		depth[b] = (p and p:IsA("Bone")) and d(p) + 1 or 0
		return depth[b]
	end
	table.sort(list, function(a, b)
		return d(a) < d(b)
	end)
	return list
end

-- Face expression keys are 180-degree turns. At exactly 180 degrees the rotation axis is ill-conditioned: the
-- Animator reads float noise in the pose (~1e-8) as the axis and plays a 180-degree turn about a wrong axis
-- (measured 39 degrees off), so the swapped-in sprite lands tilted into the face. Rebuild such turns from a
-- clean axis with an angle just under 180 degrees (0.06 degrees short: far below anything visible).
local TURN_MARGIN = 1e-3
local function wellConditionedTurn(rot)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rot:GetComponents()
	local cosA = math.clamp((r00 + r11 + r22 - 1) / 2, -1, 1)
	if cosA > math.cos(math.pi - 0.01) then
		return rot -- not near 180 degrees: well conditioned as it is
	end
	-- for a turn of ~180 degrees, R + I = 2 a a^T: its longest column points along the axis a
	local best
	for _, col in ipairs({
		Vector3.new(r00 + 1, r10, r20),
		Vector3.new(r01, r11 + 1, r21),
		Vector3.new(r02, r12, r22 + 1),
	}) do
		if not best or col.Magnitude > best.Magnitude then
			best = col
		end
	end
	return CFrame.fromAxisAngle(best.Unit, math.pi - TURN_MARGIN)
end

-- Roblox's Animator multiplies pose translations by the model's scale (Model:ScaleTo / GetScale), so poses
-- must hold *unscaled* offsets. Dividing by the scale at build time makes the same KeyframeSequence correct
-- at any model scale, including if the model is rescaled later.
local function buildSequence(anim, fit, bonesByName, order, modelScale)
	modelScale = (modelScale and modelScale > 0) and modelScale or 1
	local data = {}
	for _, b in ipairs(anim.bones) do
		data[b.name] = b
	end
	-- only bones that move (have data) or are ancestors of such bones need Poses
	local needed = {}
	for _, bone in ipairs(order) do
		if data[bone.Name] and bonesByName[bone.Name] == bone then
			local x = bone
			while x and x:IsA("Bone") and not needed[x] do
				needed[x] = true
				x = x.Parent
			end
		end
	end
	local restWorld = {}
	for _, bone in ipairs(order) do
		restWorld[bone] = bone.WorldCFrame
	end

	local ks = Instance.new("KeyframeSequence")
	ks.Name = anim.name
	ks.Loop = anim.loop
	-- <x>_s (start) and <x>_e (end) are one-shot Action tracks; <x>_loop is a looping Idle track
	ks.Priority = anim.loop and Enum.AnimationPriority.Idle or Enum.AnimationPriority.Action
	local R, Rinv = fit.R, fit.R:Inverse()
	-- Constant (face) bones are keyed only around changes. Roblox does not hold a Constant pose until the next
	-- key: across the gap it already shows the NEXT key's value. So every change also gets a key on the frame
	-- before it, holding the old value; otherwise a sprite turns out (or in) as soon as the previous key
	-- passes, and several expressions show at once.
	local lastLocal = {} -- constant bones: value of their last key
	local keyedAt = {} -- constant bones: frame of their last key
	local prevPoseOf -- previous frame's bone -> Pose
	local function newPose(bone, localCf, constant)
		local pose = Instance.new("Pose")
		pose.Name = bone.Name
		local rot = localCf.Rotation
		if constant then
			rot = wellConditionedTurn(rot)
		end
		pose.CFrame = CFrame.new(localCf.Position / modelScale) * rot
		if constant then
			pose.EasingStyle = Enum.PoseEasingStyle.Constant
		end
		return pose
	end
	for f = 0, anim.frames - 1 do
		local kf = Instance.new("Keyframe")
		kf.Time = f / anim.fps
		local partPoses, poseOf, worldAt = {}, {}, {}
		for _, bone in ipairs(order) do
			local parent = bone.Parent
			local parentWorld
			if parent:IsA("Bone") then
				parentWorld = worldAt[parent]
			elseif parent:IsA("BasePart") then
				parentWorld = parent.CFrame
			else
				parentWorld = CFrame.identity
			end
			local base = parentWorld * bone.CFrame
			local desired = base
			local d = (bonesByName[bone.Name] == bone) and data[bone.Name] or nil
			if d then
				-- rotation: world delta from the app, conjugated into this model's axes
				local qi = f * 4
				local D = CFrame.new(0, 0, 0, d.rot[qi + 1], d.rot[qi + 2], d.rot[qi + 3], d.rot[qi + 4])
				local rot = (R * D * Rinv) * restWorld[bone].Rotation
				-- position: keep the rig's own bone offset; only bones with position curves get a delta,
				-- which is scaled to this rig and turned with the parent's current rotation
				local pos = base.Position
				if d.dpos then
					local pi = f * 3
					local dv = R:VectorToWorldSpace(
						Vector3.new(d.dpos[pi + 1], d.dpos[pi + 2], d.dpos[pi + 3])
							* (fit.s * (d.constant and 1 or cfg.rootMotionScale))
					)
					if parent:IsA("Bone") then
						local parentDelta = worldAt[parent].Rotation * restWorld[parent].Rotation:Inverse()
						dv = parentDelta:VectorToWorldSpace(dv)
					end
					pos += dv
				end
				desired = CFrame.new(pos) * rot
			end
			worldAt[bone] = desired
			local localCf = base:ToObjectSpace(desired)
			local skip = false
			if d and d.constant then
				-- face expression bones: instant 180-degree swaps (Constant easing), no key while nothing changes
				local prev = lastLocal[bone]
				local same = prev ~= nil
					and (prev.Position - localCf.Position).Magnitude < 1e-4
					and prev.LookVector:Dot(localCf.LookVector) > 0.9999
					and prev.UpVector:Dot(localCf.UpVector) > 0.9999
				skip = same and f < anim.frames - 1
				if prev ~= nil and not same and needed[bone] and keyedAt[bone] ~= f - 1 then
					-- hold the old value up to the frame before the change (see above)
					local holdParent = prevPoseOf and prevPoseOf[parent]
					if holdParent then
						newPose(bone, prev, true).Parent = holdParent
					end
				end
				if not skip then
					lastLocal[bone] = localCf
					keyedAt[bone] = f
				end
			end
			if needed[bone] and not skip then
				local pose = newPose(bone, localCf, d and d.constant)
				local parentPose = poseOf[parent]
				if not parentPose then
					parentPose = partPoses[parent]
					if not parentPose then
						parentPose = Instance.new("Pose")
						parentPose.Name = parent.Name
						parentPose.Parent = kf
						partPoses[parent] = parentPose
					end
				end
				pose.Parent = parentPose
				poseOf[bone] = pose
			end
		end
		kf.Parent = ks
		prevPoseOf = poseOf
		if f % 8 == 7 then
			task.wait()
		end
	end
	return ks
end

local function animSaveFolder(model)
	local ServerStorage = game:GetService("ServerStorage")
	local saves = ServerStorage:FindFirstChild("RBX_ANIMSAVES")
	if not saves then
		saves = Instance.new("Model")
		saves.Name = "RBX_ANIMSAVES"
		saves.Parent = ServerStorage
	end
	-- The Animation Editor ties a save folder to its rig through the ObjectValue's Value (and the rig's own
	-- "AnimSaves" link), not its name: copies and re-imports of a rig share a name, so the folder must belong to
	-- THIS rig instance, the selected one. In order:
	--  1. a folder whose Value is this rig (the fullest one, if there are several)
	--  2. the folder the rig's AnimSaves link points to, if that folder's rig is gone (the rig is a copy of a
	--     deleted one and carries its link): re-pointed at this rig
	--  3. a new folder
	-- A folder is never taken over by name: a same-named folder of a deleted rig (still in Studio's undo history)
	-- belongs to that rig. Afterwards the rig's AnimSaves link points at the chosen folder, and other folders that
	-- also point at this rig are merged into it, so the plugin and the Animation Editor use the same one.
	local function live(inst)
		return inst ~= nil and inst:IsDescendantOf(game)
	end
	local mine, others = nil, {}
	for _, child in ipairs(saves:GetChildren()) do
		if child:IsA("ObjectValue") and child.Value == model then
			table.insert(others, child)
			if not mine or #child:GetChildren() > #mine:GetChildren() then
				mine = child
			end
		end
	end
	local link = model:FindFirstChild("AnimSaves")
	if not mine then
		local linked = link and link:IsA("ObjectValue") and link.Value
		if linked and linked:IsA("ObjectValue") and linked.Parent == saves and not live(linked.Value) then
			linked.Value = model
			mine = linked
		end
	end
	if not mine then
		mine = Instance.new("ObjectValue")
		mine.Name = model.Name
		mine.Value = model
		mine.Parent = saves
	end
	for _, other in ipairs(others) do
		if other ~= mine then
			for _, clip in ipairs(other:GetChildren()) do
				if not mine:FindFirstChild(clip.Name) then
					clip.Parent = mine
				end
			end
			if #other:GetChildren() == 0 then
				other:Destroy()
			else -- same-named clips in both: keep the duplicate folder, but unlink it from this rig
				other.Value = nil
			end
		end
	end
	if not (link and link:IsA("ObjectValue")) then
		link = Instance.new("ObjectValue")
		link.Name = "AnimSaves"
		link.Parent = model
	end
	link.Value = mine
	return mine
end

-- Smooth out blinks: a jump straight between open and closed eyes gets one frame of an in-between sprite.
-- Sprites are counted from 1 in the eye atlas' reading order (left to right, top to bottom), so bone
-- Face_Eye_<side>_<nn> is sprite nn + 1. Sprites not listed (#4, #11 and the symbols #12-15) are never touched.
local BLINK_OPEN = { 1, 2, 3, 5, 6, 7 }
local BLINK_CLOSED = { 8, 9, 10 }
local BLINK_BETWEEN = 3
local EYE_SPRITES = 15

local function asSet(list)
	local s = {}
	for _, v in ipairs(list) do
		s[v] = true
	end
	return s
end

-- quaternions as { x, y, z, w }
local function qmul(a, b)
	return {
		a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
		a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
		a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
		a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
	}
end
local function qconj(a)
	return { -a[1], -a[2], -a[3], a[4] }
end
local function qat(rot, f)
	local i = f * 4
	return { rot[i + 1], rot[i + 2], rot[i + 3], rot[i + 4] }
end

-- Face bones carry the head's rotation, times a 180-degree turn while toggled (see the app's face_tracks).
-- Works on the app's data before the keyframes are built. Returns how many sprite changes were smoothed.
local function smoothBlinks(anim, headName)
	local data = {}
	for _, b in ipairs(anim.bones) do
		data[b.name] = b
	end
	local frames = anim.frames
	local head = data[headName]
	local function H(f)
		return head and qat(head.rot, f) or { 0, 0, 0, 1 }
	end
	local function turned(entry, f) -- relative to the head, a turn of more than 90 degrees
		return math.abs(qmul(qconj(H(f)), qat(entry.rot, f))[4]) < 0.7071
	end
	local open, closed = asSet(BLINK_OPEN), asSet(BLINK_CLOSED)
	local smoothed = 0
	for _, side in ipairs({ "L", "R" }) do
		local bones = {}
		for k = 0, EYE_SPRITES - 1 do
			bones[k] = data[string.format("Face_Eye_%s_%02d", side, k)]
		end
		local between = bones[BLINK_BETWEEN - 1]
		if bones[0] and between then
			-- sprite shown on each frame (1-based; the first sprite rests on the face, the others turn out)
			local shown, Q = {}, nil
			for f = 0, frames - 1 do
				local s = 1
				for k = 0, EYE_SPRITES - 1 do
					local e = bones[k]
					if e and turned(e, f) then
						Q = Q or qmul(qconj(H(f)), qat(e.rot, f)) -- the turn itself
						if k > 0 then
							s = k + 1
						end
					end
				end
				shown[f] = s
			end
			local new = table.clone(shown)
			for f = 1, frames - 1 do
				local a, b = shown[f - 1], shown[f]
				if open[a] and closed[b] and f >= 2 and shown[f - 2] == a then
					new[f - 1] = BLINK_BETWEEN -- closing: the last open frame half-closes
				elseif closed[a] and open[b] and f + 1 < frames and shown[f + 1] == b then
					new[f] = BLINK_BETWEEN -- opening: the first open frame is still half-closed
				end
			end
			local changed = false
			for f = 0, frames - 1 do
				if new[f] ~= shown[f] then
					changed = true
					smoothed += 1
				end
			end
			if changed and Q then
				for k = 0, EYE_SPRITES - 1 do
					local e = bones[k]
					if e then
						local rot = {}
						for f = 0, frames - 1 do
							local s = new[f]
							local on = (k == 0 and s ~= 1) or (k > 0 and s == k + 1)
							local q = on and qmul(H(f), Q) or H(f)
							table.move(q, 1, 4, f * 4 + 1, rot)
						end
						e.rot = rot
					end
				end
			end
		end
	end
	return smoothed
end

-- Face sprite lock. Within a clip the face bones only ever sit at 0 or 180 degrees (Constant keys), but Roblox
-- blends bone Transforms whenever tracks overlap: the fade of AnimationTrack:Play/Stop (0.1 s by default),
-- AdjustWeight, and the hand-off between the _s / _loop / _e tracks. A blend of 0 and 180 degrees is a turn,
-- so the eyes, mouth and mayu visibly rotate. A LocalScript snaps every Face_* bone of rigs tagged
-- "UmaChibiFace" back to 0 or 180 degrees each frame, after the Animator has run.
local FACE_TAG = "UmaChibiFace"
local FACE_SCRIPT = "UmaChibiFaceLock"
local FACE_RUNTIME = [==[
-- Generated by the Uma2Roblox plugin (written when it imports animations; importing again rewrites this script).
-- Face sprites (Face_<part>_<n> bones: eyes, mouth, mayu...) swap expressions with instant 180-degree turns.
-- Roblox blends bone poses whenever animation tracks fade in or out (Play/Stop fadeTime, 0.1 s by default) or
-- are weighted, which turns the sprites visibly. Every frame, after the Animator, this snaps each face bone of
-- rigs tagged "UmaChibiFace" to whichever of 0 or 180 degrees the blend is closer to.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local TAG = "UmaChibiFace"
local PREFIX = "Face_"
local TURN = math.pi - 1e-3 -- the plugin keys the turn just under 180 degrees (a clean rotation axis)
local REST_COS = math.cos(1e-3) -- closer than this to 0 / 180 degrees: already snapped, left alone
local TURN_COS = math.cos(math.pi - 2e-3)

local rigs = {} -- model -> { bones }, connections

local function isFaceBone(inst)
	return inst:IsA("Bone") and string.sub(inst.Name, 1, #PREFIX) == PREFIX
end

local function add(model)
	if rigs[model] or not model:IsA("Model") then
		return
	end
	local entry = { bones = {} }
	for _, d in ipairs(model:GetDescendants()) do
		if isFaceBone(d) then
			table.insert(entry.bones, d)
		end
	end
	entry.added = model.DescendantAdded:Connect(function(d) -- streaming can deliver bones later
		if isFaceBone(d) then
			table.insert(entry.bones, d)
		end
	end)
	rigs[model] = entry
end

local function remove(model)
	local entry = rigs[model]
	if entry then
		entry.added:Disconnect()
		rigs[model] = nil
	end
end

-- The bone's local animation Transform, snapped: a rotation of angle A about axis a becomes the rest pose if
-- A < 90 degrees, else the 180-degree turn about a. nil if it needs no change.
local function snapped(t)
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = t:GetComponents()
	local c = (r00 + r11 + r22 - 1) / 2
	if c > REST_COS or c < TURN_COS then
		return nil
	end
	if c >= 0 then
		return CFrame.new(t.Position)
	end
	-- axis: (R + R^T) / 2 - cos(A) I = (1 - cos A) a a^T, whose longest column lies along a (well conditioned near
	-- 180 degrees); its sign from the skew part (R - R^T) / 2 = sin(A) [a]x
	local best
	for _, col in ipairs({
		Vector3.new(r00 - c, (r10 + r01) / 2, (r20 + r02) / 2),
		Vector3.new((r01 + r10) / 2, r11 - c, (r21 + r12) / 2),
		Vector3.new((r02 + r20) / 2, (r12 + r21) / 2, r22 - c),
	}) do
		if not best or col.Magnitude > best.Magnitude then
			best = col
		end
	end
	if best.Magnitude < 1e-6 then
		return nil
	end
	local axis = best.Unit
	if axis:Dot(Vector3.new(r21 - r12, r02 - r20, r10 - r01)) < 0 then
		axis = -axis
	end
	return CFrame.new(t.Position) * CFrame.fromAxisAngle(axis, TURN)
end

-- PreSimulation runs after the Animator has written this frame's Transforms; they hold until the next frame.
RunService.PreSimulation:Connect(function()
	for model, entry in pairs(rigs) do
		if model:IsDescendantOf(workspace) then
			for _, bone in ipairs(entry.bones) do
				local s = snapped(bone.Transform)
				if s then
					bone.Transform = s
				end
			end
		end
	end
end)

CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(remove)
for _, model in ipairs(CollectionService:GetTagged(TAG)) do
	add(model)
end
]==]

-- Tags the rig and writes the runtime into StarterPlayerScripts. The script is replaced, not edited, as with
-- SmartBone (a new Source in an existing script did not always reach playtests).
-- Returns "current" (already there and up to date), "added" or "updated".
local function installFaceLockScript()
	local sps = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
	local old = sps:FindFirstChild(FACE_SCRIPT)
	if old and old:IsA("LuaSourceContainer") and old.Source == FACE_RUNTIME then
		return "current"
	end
	if old then
		old:Destroy()
	end
	local runtime = Instance.new("LocalScript")
	runtime.Name = FACE_SCRIPT
	runtime.Source = FACE_RUNTIME
	runtime.Parent = sps
	return old and "updated" or "added"
end

-- true if the model has face sprite bones (it was tagged)
local function tagFaceLock(model)
	local CollectionService = game:GetService("CollectionService")
	local hasFace = false
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Bone") and string.sub(d.Name, 1, 5) == "Face_" then
			hasFace = true
			break
		end
	end
	if hasFace and not CollectionService:HasTag(model, FACE_TAG) then
		CollectionService:AddTag(model, FACE_TAG)
	end
	return hasFace
end

local function installFaceLock(model)
	tagFaceLock(model)
	if cfg.includeFaceLock then
		installFaceLockScript()
	end
end

-- Playable character. Imported animations make the rig a character the Animate script can drive (it keeps its
-- name; copy it to StarterPlayer as StarterCharacter): the root part becomes HumanoidRootPart (before the
-- KeyframeSequences are built, as their root Pose is named after it), the AnimationController goes, and a Humanoid
-- with an Animator takes its place. R15, so the Humanoid holds the root at HipHeight (the lift fitRootToBody left
-- under the root) and the soles on the ground. Only the root collides; the meshes are massless and pass through.
local function makePlayable(model)
	local rp = rootOf(model)
	if not rp then
		return false
	end
	rp.Name = "HumanoidRootPart"
	model.PrimaryPart = rp
	rp.Transparency = 1
	rp.CanCollide = true
	rp.Massless = false
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("AnimationController") then
			d:Destroy()
		elseif d:IsA("BasePart") and d ~= rp then
			d.CanCollide = false
			d.CanTouch = false
			d.Massless = true
		end
	end
	if fitRootToBody(model) then -- again, also for rigs fitted by older versions (head-wide, from the soles)
		model:SetAttribute("UmaRootFitted", true)
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum then
		hum = Instance.new("Humanoid")
		hum.Parent = model
	end
	hum.RigType = Enum.HumanoidRigType.R15
	hum.RequiresNeck = false -- no Neck joint: bones, not Motor6Ds
	hum.BreakJointsOnDeath = false
	hum.AutomaticScalingEnabled = false
	local lift = model:GetAttribute("UmaRootLift")
	if lift then
		hum.HipHeight = lift * model:GetScale()
	end
	if not hum:FindFirstChildOfClass("Animator") then
		Instance.new("Animator").Parent = hum
	end
	return true
end

-- The rig's own animations for the place's Animate script, in its format (a StringValue per animation set holding
-- Animation instances, each with an optional Weight NumberValue), in a "UmaAnimate" folder on the rig:
--   idle    the costume's own idle if it has one (alt outfits), else the character's idle01 (its _loop clip)
--   Emotes.Emote<n>  one per non-idle clip set of the character (res, mot, act, ..., from every outfit), in an
--           "Emotes" folder: Animation "Start" (<x>_s) then "Loop" (<x>_loop), played by /e Emote<n> (/e Emote = a
--           random one). Numbered res first, then mot, act, others; this outfit, the base outfit, then the others.
--           The StringValue's Value says which clip it is ("res01", "mot01", "res01 (costume 20)").
-- AnimationIds start empty; "Upload rig animations" fills them in, and importing again keeps them for clips that
-- did not change.
local ANIMATE_FOLDER = "UmaAnimate"
local EMOTES_FOLDER = "Emotes"

-- FNV-1a of a string, as hex: tells an uploaded clip from a changed one when the rig is imported again.
local function fingerprint(s)
	local h = 2166136261
	for i = 1, #s, 4096 do
		for _, b in ipairs({ string.byte(s, i, math.min(i + 4095, #s)) }) do
			h = bit32.bxor(h, b)
			h = (bit32.lshift(h, 24) + h * 403) % 4294967296 -- h * 16777619 (2^24 + 403), mod 2^32
		end
	end
	return string.format("%08x", h)
end

local function buildAnimateFolder(model, names, holder)
	local id, costume = parseName(model.Name)
	id = model:GetAttribute("UmaCharaId") or id
	costume = model:GetAttribute("UmaCostume") or costume or "00"
	local have = {}
	for _, n in ipairs(names) do
		have[n] = true
	end
	-- clips of this character: kind ("idle"/"res"/"mot"/"act"/...) -> number -> { [costume] = clip name prefix }
	local found = { idle = {} }
	local families = {} -- every non-idle <x>_s/_loop family, any costume: emotes
	for _, n in ipairs(names) do
		local base = string.match(n, "^(.-)_s$") or string.match(n, "^(.-)_loop$")
		local cid, c, kind, num
		if base then
			cid, c, kind, num = string.match(base, "chr(%d+)_(%w+)_(%a+)(%d+)$")
		end
		if cid and (not id or tonumber(cid) == id) then
			local k = tonumber(num)
			if kind == "idle" then
				if c == costume or c == "00" then
					found.idle[k] = found.idle[k] or {}
					found.idle[k][c] = base
				end
			elseif not families[base] then
				families[base] = { kind = kind, num = k, costume = c }
			end
		end
	end
	local function pick(byCostume)
		return byCostume[costume] or byCostume["00"]
	end
	-- Rebuilding must not lose ids already uploaded: an Animation keeps its id when its clip is unchanged (same
	-- fingerprint as when it was uploaded); a changed clip starts empty again so it gets uploaded anew.
	local kept = {}
	local old = model:FindFirstChild(ANIMATE_FOLDER)
	if old then
		for _, a in ipairs(old:GetDescendants()) do
			local clip = a:IsA("Animation") and a:GetAttribute("UmaClip")
			if clip and a.AnimationId ~= "" then
				kept[clip] = { id = a.AnimationId, hash = a:GetAttribute("UmaClipHash"), to = a:GetAttribute("UmaUploadedTo") }
			end
		end
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = ANIMATE_FOLDER
	local function animation(parent, name, clip, weight)
		local a = Instance.new("Animation")
		a.Name = name
		a.AnimationId = ""
		a:SetAttribute("UmaClip", clip)
		local k = kept[clip]
		local ks = holder and holder:FindFirstChild(clip)
		if k and (k.hash == nil or (ks and ks:GetAttribute("UmaClipHash") == k.hash)) then
			a.AnimationId = k.id
			a:SetAttribute("UmaClipHash", k.hash)
			a:SetAttribute("UmaUploadedTo", k.to)
		end
		if weight then
			local w = Instance.new("NumberValue")
			w.Name = "Weight"
			w.Value = weight
			w.Parent = a
		end
		a.Parent = parent
		return a
	end
	-- idle: the costume's own lowest-numbered idle, else idle01 of the base outfit
	local idleClip
	local nums = {}
	for k in pairs(found.idle) do
		table.insert(nums, k)
	end
	table.sort(nums)
	for _, k in ipairs(nums) do
		if found.idle[k][costume] then
			idleClip = found.idle[k][costume]
			break
		end
	end
	idleClip = idleClip or (found.idle[1] and pick(found.idle[1]))
	if not idleClip and #nums > 0 then
		idleClip = pick(found.idle[nums[1]])
	end
	local count = 0
	if idleClip then
		local set = Instance.new("StringValue")
		set.Name = "idle"
		set.Parent = folder
		-- the _loop clip is the idle cycle (_s is only the short lead-in, ~0.5 s); _s if there is no _loop
		local suffix = have[idleClip .. "_loop"] and "_loop" or "_s"
		animation(set, string.match(idleClip, "_(idle%d+)$") .. suffix, idleClip .. suffix, 1)
		count += 1
	end
	-- emotes: res first (reactions), then mot, act and any other kind; this costume, then the base outfit, then
	-- the character's other outfits. Value = what the clip is ("res01", "mot01", "res01 (costume 20)").
	local kindRank = { res = 1, mot = 2, act = 3 }
	local function costumeRank(c)
		return c == costume and 0 or c == "00" and 1 or 2
	end
	local list = {}
	for base, f in pairs(families) do
		f.base = base
		table.insert(list, f)
	end
	table.sort(list, function(a, b)
		local ka, kb = kindRank[a.kind] or 9, kindRank[b.kind] or 9
		if ka ~= kb then
			return ka < kb
		elseif a.kind ~= b.kind then
			return a.kind < b.kind
		elseif costumeRank(a.costume) ~= costumeRank(b.costume) then
			return costumeRank(a.costume) < costumeRank(b.costume)
		elseif a.costume ~= b.costume then
			return a.costume < b.costume
		end
		return a.num < b.num
	end)
	local emotes
	for i, f in ipairs(list) do
		if not emotes then
			emotes = Instance.new("Folder")
			emotes.Name = EMOTES_FOLDER
			emotes.Parent = folder
		end
		local set = Instance.new("StringValue")
		set.Name = "Emote" .. i
		set.Value = string.format("%s%02d", f.kind, f.num)
			.. ((f.costume ~= costume and f.costume ~= "00") and (" (costume " .. f.costume .. ")") or "")
		set.Parent = emotes
		if have[f.base .. "_s"] then
			animation(set, "Start", f.base .. "_s")
			count += 1
		end
		if have[f.base .. "_loop"] then
			animation(set, "Loop", f.base .. "_loop")
			count += 1
		end
	end
	folder.Parent = model
	return count
end

local function importAnimations(model, report)
	local source = model:GetAttribute("UmaSource") or model.Name
	local index = fetchJson("/anims?model=" .. HttpService:UrlEncode(source))
	if not index.animations or #index.animations == 0 then
		report(source .. ": no animations ported yet (enable 'Port mini animations' in the app).")
		return 0
	end
	-- a character with a Humanoid; else at least an AnimationController, so the rig can play
	if cfg.playableRig then
		makePlayable(model)
	elseif not model:FindFirstChildWhichIsA("Humanoid", true) and not model:FindFirstChildWhichIsA("AnimationController") then
		local ac = Instance.new("AnimationController")
		ac.Parent = model
		Instance.new("Animator").Parent = ac
	end
	local bonesByName, list = collectBones(model)
	for _, b in ipairs(list) do
		b.Transform = CFrame.identity
	end
	local fit = fitSpace(index.skeleton, bonesByName)
	local order = boneOrder(list)
	local holder = animSaveFolder(model)
	local eye = bonesByName["Face_Eye_L_00"]
	local headName = eye and eye.Parent and eye.Parent.Name or "Head"
	local n, blinks = 0, 0
	for i, name in ipairs(index.animations) do
		report(string.format("%s: animation %d/%d %s", source, i, #index.animations, name))
		local anim = fetchJson("/anim?model=" .. HttpService:UrlEncode(source) .. "&name=" .. HttpService:UrlEncode(name))
		if cfg.smoothBlinks then
			blinks += smoothBlinks(anim, headName)
		end
		local ks = buildSequence(anim, fit, bonesByName, order, model:GetScale())
		local okJson, json = pcall(HttpService.JSONEncode, HttpService, anim)
		if okJson then
			ks:SetAttribute("UmaClipHash", fingerprint(json .. "|" .. tostring(model:GetScale())))
		end
		local old = holder:FindFirstChild(ks.Name)
		if old then
			old:Destroy()
		end
		ks.Parent = holder
		n += 1
	end
	if blinks > 0 then
		report(string.format("%s: smoothed %d blink frame(s)", source, blinks))
	end
	if eye then -- the rig has face sprites: keep them from turning in animation blends
		installFaceLock(model)
	end
	if holder.Value ~= model then -- never leave animations where the Animation Editor won't find them
		warn(string.format("[Uma2Roblox] %s: save folder pointed elsewhere; re-linked it to this rig", model.Name))
		holder.Value = model
	end
	if cfg.playableRig then
		local tracks = buildAnimateFolder(model, index.animations, holder)
		local pending = 0
		for _, a in ipairs(model[ANIMATE_FOLDER]:GetDescendants()) do
			if a:IsA("Animation") and a.AnimationId == "" then
				pending += 1
			end
		end
		if pending > 0 then
			report(string.format("%s: %d track(s) in %s, %d without an AnimationId; click 'Upload rig animations'",
				source, tracks, ANIMATE_FOLDER, pending))
		else
			report(string.format("%s: %d track(s) in %s, uploaded ids kept", source, tracks, ANIMATE_FOLDER))
		end
	end
	return n, holder
end

-- Uploads the rig's UmaAnimate tracks that have no AnimationId yet and writes the returned ids into them. Assets
-- go to the place's owner (its group, or the user who owns it), not whoever is editing; an unpublished place has
-- no owner, so they go to the editing user. Needs Studio's "CreateAssetAsync Luau API" beta feature.
local BETA_HINT = 'Turn on File > Beta Features > "CreateAssetAsync Luau API", restart Studio, then try again.'

local function placeOwner()
	if game.CreatorId and game.CreatorId > 0 then
		if game.CreatorType == Enum.CreatorType.Group then
			return game.CreatorId, Enum.AssetCreatorType.Group, "group " .. game.CreatorId
		end
		return game.CreatorId, Enum.AssetCreatorType.User, "user " .. game.CreatorId
	end
	return nil, nil, "you (the place is not published, so it has no owner)"
end

local function pendingUploads(model)
	local list = {}
	local folder = model:FindFirstChild(ANIMATE_FOLDER)
	if folder then
		for _, a in ipairs(folder:GetDescendants()) do
			if a:IsA("Animation") and a.AnimationId == "" and a:GetAttribute("UmaClip") then
				table.insert(list, a)
			end
		end
	end
	return list
end

local function uploadRigAnimations(model, report)
	local list = pendingUploads(model)
	if #list == 0 then
		return 0, {}
	end
	local holder = animSaveFolder(model)
	local creatorId, creatorType, ownerText = placeOwner()
	local source = model:GetAttribute("UmaSource") or model.Name
	local done, failed, uploaded = 0, {}, {}
	for i, a in ipairs(list) do
		local clip = a:GetAttribute("UmaClip")
		local ks = holder:FindFirstChild(clip)
		if not (ks and ks:IsA("KeyframeSequence")) then
			table.insert(failed, clip .. ": not in " .. holder:GetFullName() .. " (import the animations again)")
			continue
		end
		report(string.format("%s: uploading %d/%d %s", source, i, #list, clip))
		local copy = ks:Clone()
		-- idle repeats through the Animate script's DidLoop; an emote's Start plays once, then its Loop holds
		copy.Loop = a.Name ~= "Start"
		local params = {
			Name = string.sub(string.gsub(source, "^Uma_", "") .. " " .. a.Parent.Name .. " " .. a.Name, 1, 50),
			Description = "Uma2Roblox: " .. clip,
		}
		if creatorId then
			params.CreatorId = creatorId
			params.CreatorType = creatorType
		end
		local ok, result, assetId = pcall(function()
			return AssetService:CreateAssetAsync(copy, Enum.AssetType.Animation, params)
		end)
		copy:Destroy()
		if ok and result == Enum.CreateAssetResult.Success and assetId then
			table.insert(uploaded, { a = a, id = "rbxassetid://" .. tostring(assetId), hash = ks:GetAttribute("UmaClipHash") })
		else
			local why = tostring(ok and result or result)
			local l = string.lower(why)
			if string.find(l, "beta", 1, true) or string.find(l, "not enabled", 1, true)
				or string.find(l, "not available", 1, true) or string.find(l, "createassetasync", 1, true) then
				why ..= "\n" .. BETA_HINT
			end
			table.insert(failed, clip .. ": " .. why)
			if not ok then
				break -- an API error (beta off, no permission) fails every upload the same way
			end
		end
	end
	-- The uploads yield for seconds each, so the ids are written afterwards in one short undo step (a recording
	-- held open across the network waits can be cut off by other edits and take the ids with it), then checked.
	record("Uma2Roblox: set uploaded animation ids", function()
		for _, u in ipairs(uploaded) do
			if not u.a:IsDescendantOf(model) then -- the folder was rebuilt meanwhile: use its Animation for the clip
				local clip = u.a:GetAttribute("UmaClip")
				for _, b in ipairs(pendingUploads(model)) do
					local ks = holder:FindFirstChild(clip)
					if b:GetAttribute("UmaClip") == clip and b.Name == u.a.Name
						and ks and ks:GetAttribute("UmaClipHash") == u.hash then
						u.a = b
						break
					end
				end
			end
			local a = u.a
			if a:IsDescendantOf(model) then
				a.AnimationId = u.id
				a:SetAttribute("UmaClipHash", u.hash)
				a:SetAttribute("UmaUploadedTo", ownerText)
			end
		end
	end)
	for _, u in ipairs(uploaded) do
		local a = u.a
		local clip = a:GetAttribute("UmaClip")
		if not a:IsDescendantOf(model) then
			table.insert(failed, string.format("%s: uploaded as %s, but its Animation left %s during the upload "
				.. "(re-imported?); paste the id in by hand", clip, u.id, ANIMATE_FOLDER))
		elseif a.AnimationId ~= u.id then
			table.insert(failed, string.format("%s: uploaded as %s, but setting AnimationId did not stick (it reads '%s')",
				clip, u.id, a.AnimationId))
		else
			done += 1
		end
	end
	return done, failed
end

-- The game's own swing-bone (CySpring) physics, as the app reads it from the costume's cloth prefabs: per Sp_
-- bone stiffness, drag, gravity, collision radius and angle limit, plus the body colliders the chains hit.
-- Written onto the rig as plain game values (UmaSpring* attributes on the bones, lengths in GLB metres, colliders
-- as JSON in bone space); the UmaChibiSmartBone runtime turns them into SmartBone settings, scaled to the rig's
-- size at that moment, so the rig can be rescaled later.
local SPRING_ATTRS = { "UmaSpringStiffness", "UmaSpringDrag", "UmaSpringGravity", "UmaSpringRadius", "UmaSpringLimit", "UmaSpringPart",
	"UmaSpringCollideWith" }

local function importPhysics(model)
	local source = model:GetAttribute("UmaSource") or model.Name
	local ok, data = pcall(fetchJson, "/physics?model=" .. HttpService:UrlEncode(source))
	if not ok then
		return nil, tostring(data)
	end
	local bonesByName = collectBones(model)
	for _, b in pairs(bonesByName) do
		for _, a in ipairs(SPRING_ATTRS) do
			b:SetAttribute(a, nil)
		end
	end
	local fit = fitSpace(data.skeleton, bonesByName)
	local bones = 0
	for _, chain in ipairs(data.chains or {}) do
		local root = bonesByName[chain.root]
		if root then -- the game's colliders for this chain (SmartBone would otherwise use all of them on every chain)
			root:SetAttribute("UmaSpringCollideWith", table.concat(chain.colliders or {}, ","))
		end
		for _, b in ipairs(chain.bones) do
			local bone = bonesByName[b.name]
			if bone then
				bone:SetAttribute("UmaSpringStiffness", b.stiffness)
				bone:SetAttribute("UmaSpringDrag", b.drag)
				bone:SetAttribute("UmaSpringGravity", b.gravity)
				bone:SetAttribute("UmaSpringRadius", b.radius)
				bone:SetAttribute("UmaSpringPart", chain.part)
				if b.limit then -- cone angle: the widest of the x/y limits (z is twist)
					local l = b.limit
					bone:SetAttribute("UmaSpringLimit", math.max(l[1], l[2], l[4], l[5]))
				end
				bones += 1
			end
		end
	end
	local cols = {}
	for _, c in ipairs(data.colliders or {}) do
		local bone = bonesByName[c.bone]
		if bone and not c.inner then -- SmartBone has no keep-inside colliders
			local function loc(v)
				local w = fit.R:VectorToWorldSpace(Vector3.new(v[1], v[2], v[3]))
				local p = bone.WorldCFrame:VectorToObjectSpace(w)
				return { p.X, p.Y, p.Z }
			end
			table.insert(cols, { name = c.name, bone = c.bone, type = c.type, a = loc(c.a), b = c.b and loc(c.b), radius = c.radius })
		end
	end
	model:SetAttribute("UmaSpringColliders", HttpService:JSONEncode(cols))
	model:SetAttribute("UmaStudsPerMetre", fit.s)
	model:SetAttribute("UmaPhysicsScale", model:GetScale())
	return bones, #cols
end

local function scanPlace()
	local list, seen = {}, {}
	local roots = { workspace, game:GetService("ReplicatedStorage"), game:GetService("ServerStorage"), game:GetService("StarterPlayer") }
	for _, root in ipairs(roots) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Model") then
				local id = d:GetAttribute("UmaCharaId")
				local costume = d:GetAttribute("UmaCostume")
				if not id then
					id, costume = parseName(d.Name)
				end
				if id then
					local key = tostring(id) .. "_" .. tostring(costume or "00")
					if not seen[key] then
						seen[key] = true
						table.insert(list, { id = id, costume = costume or "00" })
					end
				end
			end
		end
	end
	return list
end

---------------------------------------------------------------- SmartBone 2
-- SmartBone 2 simulates a BasePart tagged "SmartBone" whose "Roots" attribute lists its root bones. Rather than
-- baking that into each rig, rigs only carry the "UmaChibi" tag: a LocalScript generated here finds each tagged
-- rig at runtime, points SmartBone at its spring bones (the Sp_* chains of the original game: hair, tail,
-- ribbons, skirt/jacket, bust) and tags its RootPart. Copies and re-imports keep working, as tags travel with them.
local CollectionService = game:GetService("CollectionService")
local UMA_TAG = "UmaChibi"
local SMARTBONE_SCRIPT = "UmaChibiSmartBone"

local SMARTBONE_RUNTIME = [==[
-- Generated by the Uma2Roblox plugin ("Integrate SmartBone 2"); clicking that button again rewrites this script.
-- Every model tagged "UmaChibi" gets SmartBone 2 spring physics on its Sp_* bones, the swing bones of the
-- original game (hair, tail, ribbons, skirt/jacket, bust). Rigs the plugin imported the game's own swing-bone
-- physics for (UmaSpring* attributes) get per-chain values and the game's colliders; others get SETTINGS below.
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TAG = "UmaChibi"
local ROOT_PREFIX = "Sp_"
-- Sp_ chains left out (plain substrings of the bone name). The ears are driven by the ear animations.
local EXCLUDE = { "Ear" }
-- SmartBone object settings (see SmartBone.Dependencies.DefaultObjectSettings), set on each rig's RootPart
-- unless it already has that attribute. SmartBone's own defaults are made for full-size accessories: on a
-- 2-4 stud mini, its gravity and constant upward force pull the rest pose out of shape.
local SETTINGS = {
	AnchorsRotate = true, -- the first bone of each chain swings too (single-bone chains: bust, side hair)
	RestAxisFromChild = true, -- Uma bones rest unrotated; needs the plugin's patch of SmartBone
	Force = Vector3.zero,
	Gravity = Vector3.new(0, -3, 0),
	Stiffness = 0.6,
	Damping = 0.2,
}
-- Most a spring bone may swing away from its parent's direction, in degrees (set on each Sp_ bone unless set)
local ROTATION_LIMIT = 60
-- The game's CySpring values -> SmartBone. Stiffness and drag are per chain (the mean over its bones, set on the
-- chain's root bone); gravity, collision radius and angle limit per bone. Lengths scale with the rig.
local GAME = {
	stiffness = function(k) -- game 90 (skirt) .. 150 (hair) .. 900 (ears): 0.47 .. 0.6 .. 0.9
		return k / (k + 100)
	end,
	damping = function(drag) -- game 200 (tail) .. 500 (hair) .. 900 (braids): 0.08 .. 0.2 .. 0.36
		return math.clamp(drag / 2500, 0.05, 0.6)
	end,
	gravity = 0.006, -- studs/s^2 per game gravity unit, per stud of rig per GLB metre (hair 300 -> ~3.3 on a 2-stud mini)
	minLimit = 20, -- degrees: the game's limits are per axis around its own bone axes, this is one cone
	colliders = true, -- the game's body colliders (head, chest, arms, hips, thighs, knees) push the chains out
}

local SmartBone = require(--[[SMARTBONE_PATH]])

local function isSpring(inst)
	return inst:IsA("Bone") and string.sub(inst.Name, 1, #ROOT_PREFIX) == ROOT_PREFIX
end

local function excluded(name)
	for _, word in ipairs(EXCLUDE) do
		if string.find(name, word, 1, true) then
			return true
		end
	end
	return false
end

-- Root of each Sp_ chain: a Sp_ bone with no Sp_ bone above it. The whole chain below it is simulated.
local function findRoots(rootPart)
	local roots, seen = {}, {}
	for _, d in ipairs(rootPart:GetDescendants()) do
		if isSpring(d) and not excluded(d.Name) and not seen[d.Name] then
			local p, nested = d.Parent, false
			while p and p:IsA("Bone") do
				if isSpring(p) then
					nested = true
					break
				end
				p = p.Parent
			end
			if not nested then
				seen[d.Name] = true
				table.insert(roots, d.Name)
			end
		end
	end
	table.sort(roots)
	return roots
end

local watching = {}
local colliderSets = {} -- model -> { folder, connection }

local function setDefault(inst, name, value)
	if inst:GetAttribute(name) == nil then -- attributes set by hand win
		inst:SetAttribute(name, value)
	end
end

-- Studs per GLB metre for this rig now (the plugin measured it at import; the rig may have been rescaled since)
local function studsPerMetre(model)
	local spm = model:GetAttribute("UmaStudsPerMetre")
	return spm and spm * model:GetScale() / (model:GetAttribute("UmaPhysicsScale") or 1)
end

local function removeColliders(model)
	local set = colliderSets[model]
	if set then
		set.connection:Disconnect()
		set.folder:Destroy()
		colliderSets[model] = nil
	end
end

-- The game's colliders as invisible SmartCollider parts that follow their (animated) body bones every frame.
-- A ColliderKey keeps them to this rig's chains.
local function buildColliders(model, rp, s)
	removeColliders(model)
	local ok, list = pcall(HttpService.JSONDecode, HttpService, model:GetAttribute("UmaSpringColliders") or "[]")
	if not ok or #list == 0 then
		return 0
	end
	local key = rp:GetAttribute("ColliderKey") or HttpService:GenerateGUID(false)
	rp:SetAttribute("ColliderKey", key)
	local folder = Instance.new("Folder")
	folder.Name = "UmaSpringColliders " .. model.Name
	local items = {}
	for _, c in ipairs(list) do
		local bone = rp:FindFirstChild(c.bone, true)
		if bone and bone:IsA("Bone") then
			local a = Vector3.new(c.a[1], c.a[2], c.a[3]) * s
			local part = Instance.new("Part")
			part.Name = c.name
			part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
			part.CastShadow, part.Transparency = false, 1
			local offset
			if c.type == "capsule" and c.b then -- SmartBone capsule: segment of length Size.X along local Z
				local b = Vector3.new(c.b[1], c.b[2], c.b[3]) * s
				local len = (b - a).Magnitude
				offset = len > 1e-4 and CFrame.lookAt((a + b) / 2, b) or CFrame.new(a)
				part.Size = Vector3.new(math.max(len, 1e-3), 2 * c.radius * s, 2 * c.radius * s)
				part:SetAttribute("ColliderShape", "Capsule")
			else
				offset = CFrame.new(a)
				part.Size = Vector3.one * (2 * c.radius * s)
				part:SetAttribute("ColliderShape", "Sphere")
			end
			part:SetAttribute("ColliderKey", key)
			part.CFrame = bone.TransformedWorldCFrame * offset
			part.Parent = folder
			CollectionService:AddTag(part, "SmartCollider")
			table.insert(items, { part, bone, offset })
		end
	end
	folder.Parent = workspace.CurrentCamera -- local to this client
	local connection = RunService.PreSimulation:Connect(function()
		for _, it in ipairs(items) do
			it[1].CFrame = it[2].TransformedWorldCFrame * it[3]
		end
	end)
	colliderSets[model] = { folder = folder, connection = connection }
	return #items
end

-- Per-chain and per-bone SmartBone settings from the game's values; false if the rig has none.
local function applyGamePhysics(model, rp, roots)
	local s = studsPerMetre(model)
	if not s then
		return false
	end
	local any = false
	for _, name in ipairs(roots) do
		local root = rp:FindFirstChild(name, true)
		if root then
			local k, drag, n = 0, 0, 0
			for _, b in ipairs({ root, unpack(root:GetDescendants()) }) do
				if b:IsA("Bone") and b:GetAttribute("UmaSpringStiffness") then
					k += b:GetAttribute("UmaSpringStiffness")
					drag += b:GetAttribute("UmaSpringDrag") or 0
					n += 1
				end
			end
			if n > 0 then
				setDefault(root, "Stiffness", GAME.stiffness(k / n))
				setDefault(root, "Damping", GAME.damping(drag / n))
				-- only the colliders the game gives this chain (the hair's "stay behind the back" spheres would
				-- otherwise swallow the bust and the front of the skirt)
				setDefault(root, "SpringColliders", GAME.colliders and root:GetAttribute("UmaSpringCollideWith") or "")
				any = true
			end
		end
	end
	for _, d in ipairs(rp:GetDescendants()) do
		if isSpring(d) and d:GetAttribute("UmaSpringStiffness") then
			setDefault(d, "Radius", (d:GetAttribute("UmaSpringRadius") or 0) * s)
			setDefault(d, "Gravity", Vector3.new(0, -(d:GetAttribute("UmaSpringGravity") or 0) * GAME.gravity * s, 0))
			local limit = d:GetAttribute("UmaSpringLimit")
			setDefault(d, "RotationLimit", limit and math.clamp(limit, GAME.minLimit, 180) or 180)
		end
	end
	if any and GAME.colliders then
		buildColliders(model, rp, s)
	end
	return any
end

local function rootOf(model)
	return model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("RootPart")
end

local function enable(model)
	local rp = rootOf(model)
	if not (rp and rp:IsA("BasePart")) or CollectionService:HasTag(rp, "SmartBone") then
		return
	end
	if rp:GetAttribute("Roots") == nil then -- an attribute set by hand wins
		local roots = findRoots(rp)
		if #roots == 0 then
			return
		end
		rp:SetAttribute("Roots", table.concat(roots, ","))
	end
	for k, v in pairs(SETTINGS) do
		setDefault(rp, k, v)
	end
	applyGamePhysics(model, rp, string.split(rp:GetAttribute("Roots"), ","))
	for _, d in ipairs(rp:GetDescendants()) do
		if isSpring(d) then
			setDefault(d, "RotationLimit", ROTATION_LIMIT)
		end
	end
	CollectionService:AddTag(rp, "SmartBone") -- after the colliders: SmartBone gathers them when it sets up
end

local function disable(model)
	local rp = rootOf(model)
	if rp then
		CollectionService:RemoveTag(rp, "SmartBone")
	end
	removeColliders(model)
end

-- Only rigs in Workspace move; templates in ReplicatedStorage are left alone until they are put in Workspace.
local function watch(model)
	if not model:IsA("Model") or watching[model] then
		return
	end
	watching[model] = true
	local function update()
		if model:IsDescendantOf(workspace) then
			local t0 = os.clock()
			while not rootOf(model) and model.Parent and os.clock() - t0 < 30 do
				task.wait(0.5) -- streaming: the root part can arrive after the model
			end
			if model:IsDescendantOf(workspace) and CollectionService:HasTag(model, TAG) then
				enable(model)
			end
		else
			disable(model)
		end
	end
	model.AncestryChanged:Connect(function()
		if model.Parent == nil then
			watching[model] = nil
		end
		task.spawn(update)
	end)
	task.spawn(update)
end

if not SmartBone.Running then
	SmartBone.Start()
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(watch)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(disable)
for _, model in ipairs(CollectionService:GetTagged(TAG)) do
	watch(model)
end
]==]

-- SmartBone 2 turns each bone so that its +Y axis points at its child, i.e. it expects bones to point +Y along
-- the chain (Blender's convention). The importer's bones all rest unrotated, so a hanging chain flipped ~180
-- degrees and twisted the hair and skirt. These patches make SmartBone measure each bone against the direction
-- to its child at rest instead, and grow the tail bone it adds to a chain's last bone along the parent -> bone
-- line. SmartBone also reads the animated pose from the bones' CFrames, which it writes itself: the springs
-- then pull toward wherever the bones already are, and chains never come back to rest. With the patch the
-- animated pose is the rest pose taken at load times the animation's Transform.
-- They only act on RootParts with the RestAxisFromChild attribute (set by the UmaChibi runtime), so other
-- SmartBone objects in the game behave exactly as before. Checked against SmartBone 2 v0.5.2.
local SB_MARK = "-- Uma2Roblox patch"
local SB_PATCHES = {
	{
		path = {},
		find = "local ParentBone = BoneTree.Bones[ParentIndex]",
		add = "\n\t" .. SB_MARK .. ": rest pose, and rest direction to this bone in its parent's space\n"
			.. '\tif BoneTree.RootPart:GetAttribute("RestAxisFromChild") then\n'
			.. "\t\tBone.RestCFrame = BoneObject.CFrame\n"
			.. "\t\tif BoneObject.CFrame.Position.Magnitude > 1e-5 then\n"
			.. "\t\t\tBone.RestAxis = BoneObject.CFrame.Position.Unit\n"
			.. "\t\tend\n"
			.. "\tend",
	},
	{
		path = { "Components", "Bone" },
		find = "return QueryTransformedWorldCFrameNonSmartbone(BoneObject)",
		replace = SB_MARK .. ": animated pose = rest pose * animation, not the CFrame SmartBone wrote\n"
			.. "\t\tif Bone.RestCFrame then\n"
			.. "\t\t\tlocal P = BoneObject.Parent\n"
			.. '\t\t\tlocal ParentCFrame = P:IsA("Bone") and QueryTransformedWorldCFrameNonSmartbone(P) or P.CFrame\n'
			.. "\t\t\treturn ParentCFrame * Bone.RestCFrame * BoneObject.Transform\n"
			.. "\t\tend\n"
			.. "\t\treturn QueryTransformedWorldCFrameNonSmartbone(BoneObject)",
	},
	{
		path = { "Components", "Bone" },
		find = "return ParentBone.AnimatedWorldCFrame * BoneObject.TransformedCFrame",
		replace = SB_MARK .. ": animated pose = rest pose * animation\n"
			.. "\tif Bone.RestCFrame then\n"
			.. "\t\treturn ParentBone.AnimatedWorldCFrame * Bone.RestCFrame * BoneObject.Transform\n"
			.. "\tend\n"
			.. "\treturn ParentBone.AnimatedWorldCFrame * BoneObject.TransformedCFrame",
	},
	{
		path = {},
		find = "local BoneTree = BoneTreeClass.new(RootBone, RootPart, Utilities.GatherObjectSettings(RootPart))",
		replace = "local TreeSettings = Utilities.GatherObjectSettings(RootPart)\n"
			.. "\t" .. SB_MARK .. ": per-chain settings (Stiffness, Damping, ...) from attributes on the chain's root bone\n"
			.. '\tif RootPart:GetAttribute("RestAxisFromChild") then\n'
			.. "\t\tfor Key, Value in TreeSettings do\n"
			.. "\t\t\tlocal Override = RootBone:GetAttribute(Key)\n"
			.. "\t\t\tif Override ~= nil and typeof(Override) == typeof(Value) then\n"
			.. "\t\t\t\tTreeSettings[Key] = Override\n"
			.. "\t\t\tend\n"
			.. "\t\tend\n"
			.. "\tend\n"
			.. "\tlocal BoneTree = BoneTreeClass.new(RootBone, RootPart, TreeSettings)",
	},
	{
		path = {},
		find = "BoneTree:Constrain(self.ColliderObjects, UpdateHz)",
		replace = SB_MARK .. ": per-chain colliders, named in the chain root's SpringColliders attribute\n"
			.. "\t\tlocal TreeColliders = self.ColliderObjects\n"
			.. "\t\tif BoneTree.ColliderFilter == nil then\n"
			.. '\t\t\tlocal Names = BoneTree.Root and BoneTree.Root:GetAttribute("SpringColliders")\n'
			.. "\t\t\tBoneTree.ColliderFilter = false\n"
			.. '\t\t\tif typeof(Names) == "string" then\n'
			.. "\t\t\t\tBoneTree.ColliderFilter = {}\n"
			.. '\t\t\t\tfor _, Name in string.split(Names, ",") do\n'
			.. "\t\t\t\t\tBoneTree.ColliderFilter[Name] = true\n"
			.. "\t\t\t\tend\n"
			.. "\t\t\tend\n"
			.. "\t\tend\n"
			.. "\t\tif BoneTree.ColliderFilter then\n"
			.. "\t\t\tTreeColliders = {}\n"
			.. "\t\t\tfor _, ColliderObject in self.ColliderObjects do\n"
			.. "\t\t\t\tif BoneTree.ColliderFilter[ColliderObject.m_Object.Name] then\n"
			.. "\t\t\t\t\ttable.insert(TreeColliders, ColliderObject)\n"
			.. "\t\t\t\tend\n"
			.. "\t\t\tend\n"
			.. "\t\tend\n"
			.. "\t\tBoneTree:Constrain(TreeColliders, UpdateHz)",
	},
	{
		path = { "Components", "Bone" },
		find = "self.LocalTransformOffset = Root.Bone.CFrame * self.LocalTransform",
		replace = SB_MARK .. ": the spring's rest target hangs off the root's rest pose, not the CFrame SmartBone wrote\n"
			.. "\tself.LocalTransformOffset = (Root.RestCFrame or Root.Bone.CFrame) * self.LocalTransform",
	},
	{
		path = {},
		find = "local Start = Bone.WorldCFrame + (Bone.WorldCFrame.UpVector.Unit * (Bone.WorldPosition - ParentWorldPosition).Magnitude)",
		add = "\n\t\t\t" .. SB_MARK .. ": the tail continues the parent -> bone line\n"
			.. '\t\t\tif RootPart:GetAttribute("RestAxisFromChild") and (Bone.WorldPosition - ParentWorldPosition).Magnitude > 1e-5 then\n'
			.. "\t\t\t\tStart = Bone.WorldCFrame + (Bone.WorldPosition - ParentWorldPosition)\n"
			.. "\t\t\tend",
	},
	{
		path = { "Components", "Bone" },
		find = "local Rotation = Utilities.GetRotationBetween(ReferenceCFrame.UpVector, v1).Rotation * ReferenceCFrame.Rotation",
		replace = SB_MARK .. ": measure against the rest direction to this bone, not the parent's +Y\n"
			.. "\t\tlocal RestUp = self.RestAxis and ReferenceCFrame:VectorToWorldSpace(self.RestAxis) or ReferenceCFrame.UpVector\n"
			.. "\t\tlocal Rotation = Utilities.GetRotationBetween(RestUp, v1).Rotation * ReferenceCFrame.Rotation",
	},
}

-- Applies the patches that are not in yet (a copy patched by an older version of this plugin gets the new
-- ones). Returns "patched", "already" or nil plus what is missing; nothing is written unless all apply.
local function patchSmartBone(module)
	local edits, applied = {}, 0
	for _, p in ipairs(SB_PATCHES) do
		local script = module
		for _, name in ipairs(p.path) do
			script = script and script:FindFirstChild(name)
		end
		if not (script and script:IsA("LuaSourceContainer")) then
			return nil, "no " .. table.concat(p.path, ".") .. " module"
		end
		local src = edits[script] or script.Source
		local new = p.replace or (p.find .. p.add)
		if not string.find(src, new, 1, true) then
			local a, b = string.find(src, p.find, 1, true)
			if not a or string.find(src, p.find, b + 1, true) then
				return nil, "unknown SmartBone version (the line to patch in " .. script.Name .. " was not found once)"
			end
			src = string.sub(src, 1, a - 1) .. new .. string.sub(src, b + 1)
			applied += 1
		end
		edits[script] = src
	end
	if applied == 0 then
		return "already"
	end
	for script, src in pairs(edits) do
		if script.Source ~= src then
			script.Source = src
		end
	end
	return "patched"
end

-- A rig the importer made: a RootPart part with Bones under it
local function isRig(model)
	local rp = model:IsA("Model") and rootOf(model)
	return rp and rp:IsA("BasePart") and rp:FindFirstChildWhichIsA("Bone", true) ~= nil
end

local function isUmaModel(model)
	return parseName(model.Name) ~= nil or model:GetAttribute("UmaToon") ~= nil or model:GetAttribute("UmaCharaId") ~= nil
end

local function tagUmaChibi(model)
	if isRig(model) and not CollectionService:HasTag(model, UMA_TAG) then
		CollectionService:AddTag(model, UMA_TAG)
		return true
	end
	return false
end

-- The SmartBone 2 library: a ModuleScript (any name) with its Components and Dependencies.Runtime children
local function isSmartBone(inst)
	if not (inst and inst:IsA("ModuleScript")) then
		return false
	end
	local deps = inst:FindFirstChild("Dependencies")
	return inst:FindFirstChild("Components") ~= nil and deps ~= nil and deps:FindFirstChild("Runtime") ~= nil
end

-- Where to take SmartBone 2 from, in order: a library selected in the Explorer (the user points it out), one
-- already in ReplicatedStorage, one anywhere else in the place, or one inserted from cfg.smartBoneAssetId.
-- Returns the module and a description of where it came from.
local function findSmartBone()
	for _, inst in ipairs(Selection:Get()) do
		local m = inst
		while m and not isSmartBone(m) do
			m = m.Parent ~= game and m.Parent or nil
		end
		if m then
			return m, "the selection (" .. m:GetFullName() .. ")"
		end
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local named = ReplicatedStorage:FindFirstChild("SmartBone")
	if isSmartBone(named) then
		return named, "ReplicatedStorage"
	end
	for _, root in ipairs({ ReplicatedStorage, workspace, game:GetService("ServerStorage"), game:GetService("ServerScriptService"),
		game:GetService("StarterPlayer"), game:GetService("ReplicatedFirst"), game:GetService("Lighting") }) do
		for _, d in ipairs(root:GetDescendants()) do
			if isSmartBone(d) then
				return d, d:GetFullName()
			end
		end
	end
	local id = tonumber(cfg.smartBoneAssetId)
	if id and id > 0 then
		local ok, objects = pcall(function()
			return game:GetObjects("rbxassetid://" .. id)
		end)
		if not ok then
			return nil, "could not insert asset " .. id .. ": " .. tostring(objects)
		end
		for _, o in ipairs(objects) do
			local m = isSmartBone(o) and o or nil
			if not m then
				for _, d in ipairs(o:GetDescendants()) do
					if isSmartBone(d) then
						m = d
						break
					end
				end
			end
			if m then
				return m, "asset " .. id
			end
		end
		return nil, "asset " .. id .. " has no SmartBone 2 ModuleScript (Components + Dependencies.Runtime) in it"
	end
	return nil, nil
end

-- Lua expression that finds `module` from the client: game.ReplicatedStorage:WaitForChild(...) per level
local function requirePath(module)
	local names = {}
	local x = module
	while x and x ~= game:GetService("ReplicatedStorage") do
		table.insert(names, 1, x.Name)
		x = x.Parent
	end
	local expr = 'game:GetService("ReplicatedStorage")'
	for _, n in ipairs(names) do
		expr ..= string.format(":WaitForChild(%q)", n)
	end
	return expr
end

local function integrateSmartBone()
	local module, where = findSmartBone()
	if not module then
		return nil, (where and ("SmartBone 2: " .. where .. ".\n") or "")
			.. "SmartBone 2 not found. Select its ModuleScript in the Explorer, or enter its asset id above, then click again."
	end
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local lines = {}
	if not module:IsDescendantOf(ReplicatedStorage) then
		-- clients require it, and a copy left in Workspace can be streamed or run twice
		local clash = ReplicatedStorage:FindFirstChild(module.Name)
		if clash and clash ~= module then
			return nil, string.format("ReplicatedStorage already has a %s named %s; rename or remove one, then click again.",
				clash.ClassName, module.Name)
		end
		module.Parent = ReplicatedStorage
		table.insert(lines, "SmartBone 2 from " .. where .. " -> ReplicatedStorage." .. module.Name .. ".")
	else
		table.insert(lines, "Using SmartBone 2 at " .. module:GetFullName() .. ".")
	end
	local patched, why = patchSmartBone(module)
	if patched == "patched" then
		table.insert(lines, "Patched SmartBone for the Uma bone axes (only affects rigs with RestAxisFromChild).")
	elseif not patched then
		table.insert(lines, "WARNING: could not patch SmartBone (" .. why .. "); Uma hair and skirts may twist.")
	end

	local sps = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
	-- replaced rather than edited: a new Source written into an existing script did not always reach playtests
	-- (with collaborative editing, Studio can keep running the script's earlier version)
	local source = (string.gsub(SMARTBONE_RUNTIME, "%-%-%[%[SMARTBONE_PATH%]%]", function()
		return requirePath(module)
	end))
	local old = sps:FindFirstChild(SMARTBONE_SCRIPT)
	if old and old:IsA("LocalScript") and old.Source == source then
		table.insert(lines, "StarterPlayerScripts." .. SMARTBONE_SCRIPT .. " already there and up to date.")
	else
		local created = old == nil
		if old then
			old:Destroy()
		end
		local runtime = Instance.new("LocalScript")
		runtime.Name = SMARTBONE_SCRIPT
		runtime.Source = source
		runtime.Parent = sps
		table.insert(lines, (created and "Added" or "Updated") .. " StarterPlayerScripts." .. SMARTBONE_SCRIPT .. ".")
	end

	-- the selected rigs, or else every Uma rig in the place (a selected SmartBone library is not a rig)
	local models = {}
	for _, m in ipairs(selectedModels()) do
		if m ~= workspace and isRig(m) then
			table.insert(models, m)
		end
	end
	local scope = "selected"
	if #models == 0 then
		scope = "Uma"
		for _, root in ipairs({ workspace, game:GetService("ReplicatedStorage"), game:GetService("ServerStorage") }) do
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("Model") and isUmaModel(d) and not (d.Parent and d.Parent:IsA("Model") and isUmaModel(d.Parent)) then
					table.insert(models, d)
				end
			end
		end
	end
	local tagged, already, skipped = 0, 0, 0
	for _, m in ipairs(models) do
		if CollectionService:HasTag(m, UMA_TAG) then
			already += 1
		elseif tagUmaChibi(m) then
			tagged += 1
		else
			skipped += 1
		end
	end
	table.insert(lines, string.format("Tagged %d %s rig(s) '%s' (%d already were%s).", tagged, scope, UMA_TAG, already,
		skipped > 0 and string.format(", %d not a rig", skipped) or ""))
	table.insert(lines, "Press Play: their Sp_* bones (hair, tail, skirt...) swing with SmartBone.")
	return table.concat(lines, "\n")
end

-- File > Import 3D drops the model into Workspace and fills it in over a few frames. Once it stops changing,
-- set it up once (the UmaImportSetup attribute also travels with copies, so pasting one is left alone):
-- fit its RootPart, fix cheek/mayu transparency and import its animations, each as its option says.
local pendingSetup = {}
local function onImportOptions()
	return cfg.fitOnImport or cfg.autoTransparency or cfg.autoAnimations
end
local function setupWhenImported(model)
	if pendingSetup[model] or not model:IsA("Model") or not parseName(model.Name) then
		return
	end
	if model:GetAttribute("UmaImportSetup") ~= nil or model:GetAttribute("UmaToon") ~= nil then
		return
	end
	pendingSetup[model] = true
	task.spawn(function()
		local last, stable, t0 = -1, 0, os.clock()
		while stable < 3 and os.clock() - t0 < 15 and model.Parent do
			task.wait(0.2)
			local n = #model:GetDescendants()
			if n == last then
				stable += 1
			else
				stable, last = 0, n
			end
		end
		pendingSetup[model] = nil
		if not (onImportOptions() and model:IsDescendantOf(workspace) and model:GetAttribute("UmaImportSetup") == nil) then
			return
		end
		local rp = model:FindFirstChild("RootPart")
		if not (rp and rp:IsA("BasePart") and rp:FindFirstChildWhichIsA("Bone")) then
			return -- not a rig from the importer
		end
		model:SetAttribute("UmaImportSetup", true)
		local done = {}
		record("Uma2Roblox: set up imported model", function()
			if cfg.fitOnImport and model:GetAttribute("UmaRootFitted") == nil and fitRootToBody(model) then
				model:SetAttribute("UmaRootFitted", true)
				table.insert(done, "RootPart fitted")
			end
			if cfg.autoTransparency then
				table.insert(done, fixTransparency(model) .. " cheek/mayu part(s) fixed")
			end
			if cfg.toonLight then
				table.insert(done, applyToonLight(model) .. " part(s) toon light")
			end
			if cfg.tagUmaChibi and tagUmaChibi(model) then
				table.insert(done, "tagged " .. UMA_TAG)
			end
		end)
		if cfg.autoAnimations then
			record("Uma2Roblox: import animations", function()
				local ok, n, holder = pcall(importAnimations, model, function() end)
				if ok then
					table.insert(done, string.format("%d animation(s) -> ServerStorage.RBX_ANIMSAVES.%s", n, holder and holder.Name or "?"))
				else
					warn("[Uma2Roblox] " .. model.Name .. ": animations not imported (is the Uma2Roblox app running?) " .. tostring(n))
				end
			end)
		end
		if cfg.importPhysics then
			record("Uma2Roblox: import physics", function()
				local bones, cols = importPhysics(model)
				if bones then
					table.insert(done, string.format("game physics on %d bone(s), %d collider(s)", bones, cols))
				else
					warn("[Uma2Roblox] " .. model.Name .. ": swing-bone physics not imported, SmartBone uses defaults (" .. tostring(cols) .. ")")
				end
			end)
		end
		print("[Uma2Roblox] imported " .. model.Name .. ": " .. (#done > 0 and table.concat(done, ", ") or "nothing to do"))
	end)
end
workspace.ChildAdded:Connect(function(child)
	if onImportOptions() then
		setupWhenImported(child)
	end
end)

---------------------------------------------------------------- UI
local toolbar = plugin:CreateToolbar("Uma2Roblox")
local toggleButton = toolbar:CreateButton("Uma2Roblox", "Uma mini model tools", "rbxassetid://4458901886")
toggleButton.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"Uma2RobloxWidget",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 260, 320, 220, 240)
)
widget.Title = "Uma2Roblox"
toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

local frame = Instance.new("ScrollingFrame")
frame.Size = UDim2.fromScale(1, 1)
frame.BackgroundColor3 = settings().Studio.Theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
frame.BorderSizePixel = 0
frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
frame.CanvasSize = UDim2.new()
frame.ScrollBarThickness = 6
frame.Parent = widget
local pad = Instance.new("UIPadding")
pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop = UDim.new(0, 8), UDim.new(0, 8), UDim.new(0, 8)
pad.Parent = frame
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = frame

local theme = settings().Studio.Theme
local order = 0
local function nextOrder()
	order += 1
	return order
end

local function label(text, height)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, height or 18)
	l.AutomaticSize = height and Enum.AutomaticSize.None or Enum.AutomaticSize.Y
	l.BackgroundTransparency = 1
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Font = Enum.Font.SourceSans
	l.TextSize = 15
	l.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	l.Text = text
	l.LayoutOrder = nextOrder()
	l.Parent = frame
	return l
end

local function button(text, onClick)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 28)
	b.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Button)
	b.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.ButtonText)
	b.Font = Enum.Font.SourceSansSemibold
	b.TextSize = 15
	b.Text = text
	b.LayoutOrder = nextOrder()
	b.AutoButtonColor = true
	b.Parent = frame
	b.MouseButton1Click:Connect(onClick)
	return b
end

-- the main actions: Studio's accent (dialog main button) colour, taller, bold
local function primary(b)
	b.Size = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DialogMainButton)
	b.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DialogMainButtonText)
	b.Font = Enum.Font.SourceSansBold
	b.TextSize = 16
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = b
	return b
end

local function numberRow(text, value, onChange)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 24)
	row.BackgroundTransparency = 1
	row.LayoutOrder = nextOrder()
	row.Parent = frame
	local l = label(text, 24)
	l.Parent = row
	l.Size = UDim2.new(0.6, 0, 1, 0)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(0.4, 0, 1, 0)
	box.Position = UDim2.fromScale(0.6, 0)
	box.Text = tostring(value)
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.SourceSans
	box.TextSize = 15
	box.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground)
	box.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	box.Parent = row
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			onChange(n)
		else
			box.Text = tostring(value)
		end
	end)
end

local function toggleRow(text, value, onChange)
	local b
	b = button((value and "[x] " or "[ ] ") .. text, function()
		value = not value
		b.Text = (value and "[x] " or "[ ] ") .. text
		onChange(value)
	end)
end

label("1. Import Uma_*.glb with File > Import 3D\n2. Select the model(s), then Apply Uma Toon")
toggleRow("Fit RootPart to the body on import", cfg.fitOnImport, function(v)
	cfg.fitOnImport = v
	saveSettings()
end)
toggleRow("Extra Highlight silhouette outline", cfg.highlightOutline, function(v)
	cfg.highlightOutline = v
	saveSettings()
end)
numberRow("Root motion scale (hip movement, 1 = as in game)", cfg.rootMotionScale, function(n)
	cfg.rootMotionScale = math.max(0, n)
	saveSettings()
end)
toggleRow("Import its mini animations (on import and Apply)", cfg.autoAnimations, function(v)
	cfg.autoAnimations = v
	saveSettings()
end)
toggleRow("Make the rig playable when importing animations (Humanoid, HumanoidRootPart, idle/emote tracks)",
	cfg.playableRig, function(v)
		cfg.playableRig = v
		saveSettings()
	end)
toggleRow("Smooth out blinks (sprite #3 between open and closed eyes)", cfg.smoothBlinks, function(v)
	cfg.smoothBlinks = v
	saveSettings()
end)
toggleRow("Toon light: even, not washed out (on import and Apply)", cfg.toonLight, function(v)
	cfg.toonLight = v
	saveSettings()
end)
numberRow("Toon light tint (lower = darker in sun)", cfg.toonTint, function(n)
	cfg.toonTint = math.clamp(n, 0, 1)
	saveSettings()
end)
numberRow("Toon light emissive (higher = lighter shade, softer shadows)", cfg.toonEmissive, function(n)
	cfg.toonEmissive = math.max(0, n)
	saveSettings()
end)
toggleRow("Fix cheek/mayu transparency (on import and Apply)", cfg.autoTransparency, function(v)
	cfg.autoTransparency = v
	saveSettings()
end)

local status = nil
button("Apply Uma Toon to selection", function()
	local models = selectedModels()
	if #models == 0 then
		status.Text = "Select an imported Uma model first."
		return
	end
	local parts = 0
	record("Uma2Roblox: Apply toon", function()
		for _, m in ipairs(models) do
			parts += applyToon(m)
			if cfg.tagUmaChibi then
				tagUmaChibi(m)
			end
		end
	end)
	status.Text = string.format("Applied to %d model(s), %d mesh parts.", #models, parts)
	if cfg.autoAnimations then
		local total = 0
		record("Uma2Roblox: Import animations", function()
			for _, m in ipairs(models) do
				local ok, n = pcall(importAnimations, m, function(msg)
					status.Text = msg
				end)
				if ok then
					total += n
				else
					warn("[Uma2Roblox] animations for " .. m.Name .. ": " .. tostring(n))
				end
			end
		end)
		status.Text = string.format(
			"Applied to %d model(s), %d mesh parts.\n%d animation(s) saved to ServerStorage.RBX_ANIMSAVES (open them in the Animation Editor).",
			#models,
			parts,
			total
		)
	end
	if cfg.importPhysics then
		local withPhysics, missing = 0, {}
		record("Uma2Roblox: import physics", function()
			for _, m in ipairs(models) do
				local bones, err = importPhysics(m)
				if bones then
					withPhysics += 1
				else
					table.insert(missing, m.Name .. ": " .. tostring(err))
				end
			end
		end)
		status.Text ..= string.format("\nGame swing-bone physics on %d model(s).", withPhysics)
			.. (#missing > 0 and ("\nNo physics (SmartBone defaults): " .. table.concat(missing, "; ")) or "")
	end
end)

button("Fix cheek/mayu transparency (selection or whole place)", function()
	local targets = selectedModels()
	if #targets == 0 then
		targets = { workspace, game:GetService("ReplicatedStorage"), game:GetService("ServerStorage") }
	end
	local n = 0
	record("Uma2Roblox: transparency", function()
		for _, t in ipairs(targets) do
			n += fixTransparency(t)
		end
	end)
	status.Text = string.format("Set Transparency = %.2f on %d part(s) matching '%s'.", TRANSPARENT_PASS, n, cfg.transparentParts)
end)

primary(button("Import Uma animations for selection", function()
	local models = selectedModels()
	if #models == 0 then
		status.Text = "Select an imported Uma model first."
		return
	end
	local total, errs = 0, {}
	record("Uma2Roblox: Import animations", function()
		for _, m in ipairs(models) do
			local ok, n = pcall(importAnimations, m, function(msg)
				status.Text = msg
			end)
			if ok then
				total += n
			else
				table.insert(errs, m.Name .. ": " .. tostring(n))
			end
		end
	end)
	status.Text = string.format("%d animation(s) saved to ServerStorage.RBX_ANIMSAVES.", total)
		.. (#errs > 0 and ("\n" .. table.concat(errs, "\n")) or "")
end))

-- Uploading creates assets under the place's owner, so it asks first, right under the button: what would be
-- uploaded and to whom, with Upload / Cancel. Changing the selection cancels the question.
local confirmBox, confirmText, confirmYes, confirmNo
local pendingUpload = nil -- { models, total, ownerText }
local function hideConfirm()
	pendingUpload = nil
	if confirmBox then
		confirmBox.Visible = false
	end
end

local function runUpload(p)
	local done, errs = 0, {}
	for _, m in ipairs(p.models) do -- uploadRigAnimations records its own undo step for the ids
		local okUp, n, failed = pcall(uploadRigAnimations, m, function(msg)
			status.Text = msg
		end)
		if okUp then
			done += n
			for _, f in ipairs(failed) do
				table.insert(errs, m.Name .. ": " .. f)
			end
		else
			table.insert(errs, m.Name .. ": " .. tostring(n))
		end
	end
	status.Text = string.format("Uploaded %d of %d animation(s) (owner: %s); their ids are in %s.", done, p.total,
		p.ownerText, ANIMATE_FOLDER) .. (#errs > 0 and ("\n" .. table.concat(errs, "\n")) or "")
	if #errs > 0 then
		warn("[Uma2Roblox] upload problems:\n" .. table.concat(errs, "\n"))
	end
end

primary(button("Upload rig animations (selection; asks first)", function()
	local models, total = {}, 0
	for _, m in ipairs(selectedModels()) do
		local n = #pendingUploads(m)
		if n > 0 then
			table.insert(models, m)
			total += n
		end
	end
	if total == 0 then
		hideConfirm()
		status.Text = "Nothing to upload: select a rig whose " .. ANIMATE_FOLDER .. " folder has Animations without an "
			.. "AnimationId (import its animations first)."
		return
	end
	local _, _, ownerText = placeOwner()
	pendingUpload = { models = models, total = total, ownerText = ownerText }
	confirmText.Text = string.format("Upload %d animation(s) from %d rig(s) as assets owned by %s?", total, #models,
		ownerText)
	confirmBox.Visible = true
end))

-- the confirmation row, directly under the upload button
confirmBox = Instance.new("Frame")
confirmBox.Size = UDim2.new(1, 0, 0, 0)
confirmBox.AutomaticSize = Enum.AutomaticSize.Y
confirmBox.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground)
confirmBox.BorderSizePixel = 0
confirmBox.Visible = false
confirmBox.LayoutOrder = nextOrder()
confirmBox.Parent = frame
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = confirmBox
	local p = Instance.new("UIPadding")
	p.PaddingLeft, p.PaddingRight, p.PaddingTop, p.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6)
	p.Parent = confirmBox
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = confirmBox
end
confirmText = Instance.new("TextLabel")
confirmText.Size = UDim2.new(1, 0, 0, 0)
confirmText.AutomaticSize = Enum.AutomaticSize.Y
confirmText.BackgroundTransparency = 1
confirmText.TextWrapped = true
confirmText.TextXAlignment = Enum.TextXAlignment.Left
confirmText.Font = Enum.Font.SourceSansSemibold
confirmText.TextSize = 15
confirmText.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
confirmText.LayoutOrder = 1
confirmText.Parent = confirmBox
do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 28)
	row.BackgroundTransparency = 1
	row.LayoutOrder = 2
	row.Parent = confirmBox
	local function rowButton(text, x, main, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.5, -3, 1, 0)
		b.Position = UDim2.new(x, x > 0 and 3 or 0, 0, 0)
		b.BackgroundColor3 = theme:GetColor(main and Enum.StudioStyleGuideColor.DialogMainButton or Enum.StudioStyleGuideColor.Button)
		b.TextColor3 = theme:GetColor(main and Enum.StudioStyleGuideColor.DialogMainButtonText or Enum.StudioStyleGuideColor.ButtonText)
		b.Font = Enum.Font.SourceSansBold
		b.TextSize = 15
		b.Text = text
		b.Parent = row
		b.MouseButton1Click:Connect(onClick)
		return b
	end
	confirmYes = rowButton("Upload", 0, true, function()
		local p = pendingUpload
		hideConfirm()
		if p then
			runUpload(p)
		end
	end)
	confirmNo = rowButton("Cancel", 0.5, false, function()
		hideConfirm()
		status.Text = "Upload cancelled."
	end)
end
Selection.SelectionChanged:Connect(hideConfirm)

button("Sync with Uma2Roblox app", function()
	local list = scanPlace()
	local ok, res = pcall(function()
		HttpService:RequestAsync({
			Url = SYNC_URL .. "/imported",
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode({ models = list }),
		})
		return HttpService:RequestAsync({ Url = SYNC_URL .. "/status", Method = "GET" })
	end)
	if not ok or not res.Success then
		status.Text = "Could not reach the Uma2Roblox app. Is Uma2Roblox.exe running?\n"
			.. tostring(ok and res.StatusMessage or res)
		return
	end
	local data = HttpService:JSONDecode(res.Body)
	local names = {}
	for i, u in ipairs(data.unported or {}) do
		if i > 25 then
			table.insert(names, "…")
			break
		end
		table.insert(names, string.format("%d %s", u.id, u.name or ""))
	end
	status.Text = string.format(
		"%d Uma model(s) found in this place.\n%d character(s) still not ported:\n%s",
		#list,
		#(data.unported or {}),
		table.concat(names, "\n")
	)
end)

label("SmartBone 2 (hair, tail, skirt physics): select its ModuleScript in the Explorer, or leave it anywhere in the place, or enter its asset id below. Rigs get the '" .. UMA_TAG .. "' tag; selected rigs, else all Uma rigs.")
numberRow("SmartBone 2 asset id (0 = none)", cfg.smartBoneAssetId, function(n)
	cfg.smartBoneAssetId = math.max(0, math.floor(n))
	saveSettings()
end)
toggleRow("Tag rigs '" .. UMA_TAG .. "' on import and Apply", cfg.tagUmaChibi, function(v)
	cfg.tagUmaChibi = v
	saveSettings()
end)
toggleRow("Import the game's swing-bone physics (on import and Apply)", cfg.importPhysics, function(v)
	cfg.importPhysics = v
	saveSettings()
end)
button("Integrate SmartBone 2 into this place", function()
	local msg, err
	record("Uma2Roblox: integrate SmartBone 2", function()
		msg, err = integrateSmartBone()
	end)
	status.Text = msg or err or "SmartBone 2 integration failed (see Output)."
end)

label("Face lock: StarterPlayerScripts." .. FACE_SCRIPT .. " keeps face sprites (eyes, mouth, mayu) from turning while animations blend. Rigs with face bones get the '" .. FACE_TAG .. "' tag; selected rigs, else all Uma rigs.")
toggleRow("Include " .. FACE_SCRIPT .. " in StarterPlayerScripts when importing animations", cfg.includeFaceLock, function(v)
	cfg.includeFaceLock = v
	saveSettings()
end)
button("Add " .. FACE_SCRIPT .. " to this place", function()
	local result, tagged, models = nil, 0, {}
	record("Uma2Roblox: add face lock", function()
		result = installFaceLockScript()
		for _, m in ipairs(selectedModels()) do
			if m ~= workspace and isRig(m) then
				table.insert(models, m)
			end
		end
		if #models == 0 then
			for _, root in ipairs({ workspace, game:GetService("ReplicatedStorage"), game:GetService("ServerStorage") }) do
				for _, d in ipairs(root:GetDescendants()) do
					if d:IsA("Model") and isUmaModel(d) and not (d.Parent and d.Parent:IsA("Model") and isUmaModel(d.Parent)) then
						table.insert(models, d)
					end
				end
			end
		end
		for _, m in ipairs(models) do
			if tagFaceLock(m) then
				tagged += 1
			end
		end
	end)
	status.Text = string.format("StarterPlayerScripts.%s %s. %d of %d rig(s) with face bones tagged '%s'.", FACE_SCRIPT,
		result == "current" and "was already up to date" or result, tagged, #models, FACE_TAG)
end)

button("Place: remove PBR reflections (optional)", function()
	record("Uma2Roblox: lighting", function()
		Lighting.EnvironmentSpecularScale = 0
	end)
	status.Text = "Lighting.EnvironmentSpecularScale = 0 (affects the whole place; undo with Ctrl+Z)."
end)

---------------------------------------------------------------- Face editor
-- One face for a whole clip. Each face part (Face_Mayu_L/R, Face_Eye_L/R, Face_Mouth) is a set of sprite bones:
-- its default sprite rests on the face (bone _00; the mouth's is _01, its small smile, as the app's FACE_DEFAULT),
-- any other sprite #n turns bone _<n-1> in and the default bone out, with 180-degree Constant keys (see
-- buildSequence). Apply removes every key of those bones from the clip and keys the
-- chosen sprites once at its first and once at its last keyframe, so the face holds from start to end.
-- The clip is the last one selected: a KeyframeSequence (ServerStorage.RBX_ANIMSAVES) or a rig's UmaAnimate
-- Animation (its UmaClip attribute). The sliders preview on the clip's rig through the face bones' Transform.
do -- (its own scope: the main chunk is near Luau's limit of 200 locals)
local FACE_PARTS = {
	{ group = "Mayu_L", name = "Mayu", side = "Mayu L" },
	{ group = "Mayu_R", name = "Mayu R", side = "Mayu R", follows = "Mayu_L" },
	{ group = "Eye_L", name = "Eye", side = "Eye L" },
	{ group = "Eye_R", name = "Eye R", side = "Eye R", follows = "Eye_L" },
	{ group = "Mouth", name = "Mouth", side = "Mouth" },
}
local FACE_TURN = math.pi - TURN_MARGIN
local FACE_DEFAULT = { Mouth = 1 } -- the sprite each part shows at rest (0 when not listed), as the app builds it

local function defaultOf(t, group)
	return math.min(FACE_DEFAULT[group] or 0, (t.count[group] or 1) - 1)
end

-- whether sprite bone n of a part is turned while sprite `shown` is on: the default turns out, the shown one in
local function turnedFor(n, shown, default)
	if n == default then
		return shown ~= default
	end
	return n == shown
end

local function faceGroupOf(name) -- "Face_Eye_L_08" -> "Eye_L", 8
	local g, n = string.match(name, "^Face_(.+)_(%d+)$")
	return g, n and tonumber(n)
end

-- the clip behind a selected instance, or nil
local function clipOf(inst)
	if inst:IsA("KeyframeSequence") then
		return inst
	end
	local clip = inst:IsA("Animation") and inst:GetAttribute("UmaClip")
	if not clip then
		return nil
	end
	local m = inst:FindFirstAncestorWhichIsA("Model")
	while m do -- the rig: the model whose AnimSaves link names its save folder
		local link = m:FindFirstChild("AnimSaves")
		local holder = link and link:IsA("ObjectValue") and link.Value
		local ks = holder and holder:FindFirstChild(clip)
		if ks and ks:IsA("KeyframeSequence") then
			return ks
		end
		m = m.Parent and m.Parent:FindFirstAncestorWhichIsA("Model")
	end
	local saves = game:GetService("ServerStorage"):FindFirstChild("RBX_ANIMSAVES")
	for _, holder in ipairs(saves and saves:GetChildren() or {}) do
		local ks = holder:FindFirstChild(clip)
		if ks and ks:IsA("KeyframeSequence") then
			return ks
		end
	end
	return nil
end

local function sortedKeyframes(ks)
	local kfs = ks:GetKeyframes()
	table.sort(kfs, function(a, b)
		return a.Time < b.Time
	end)
	return kfs
end

-- What the clip's face is made of: bones[group][index] = bone name, the turn axis of each bone, the face at its
-- start (values[group] = 0-based sprite index), and its rig (for the preview) if that is still in the place.
local function readFace(ks)
	local holder = ks.Parent
	local rig = holder and holder:IsA("ObjectValue") and holder.Value
	if not (rig and rig:IsDescendantOf(game)) then
		rig = nil
	end
	local t = { ks = ks, rig = rig, bones = {}, count = {}, axes = {}, values = {}, rigBones = {} }
	local function addBone(name)
		local g, n = faceGroupOf(name)
		if g then
			t.bones[g] = t.bones[g] or {}
			t.bones[g][n] = name
			t.count[g] = math.max(t.count[g] or 0, n + 1)
		end
		return g
	end
	if rig then
		for _, d in ipairs(rig:GetDescendants()) do
			if d:IsA("Bone") and addBone(d.Name) then
				t.rigBones[d.Name] = d
			end
		end
	end
	local kfs = sortedKeyframes(ks)
	local turnedAtStart = {}
	for i, kf in ipairs(kfs) do
		for _, p in ipairs(kf:GetDescendants()) do
			if p:IsA("Pose") and addBone(p.Name) then
				t.head = t.head or p.Parent.Name
				local axis, angle = p.CFrame:ToAxisAngle()
				if angle > math.pi / 2 then
					t.axes[p.Name] = t.axes[p.Name] or axis
					if i == 1 then
						turnedAtStart[p.Name] = true
					end
				end
			end
		end
	end
	-- the start face: the sprite turned in, else the default resting on the face
	for g, bones in pairs(t.bones) do
		local default = defaultOf(t, g)
		t.values[g] = default
		for n, name in pairs(bones) do
			if n ~= default and turnedAtStart[name] then
				t.values[g] = n
			end
		end
	end
	return t
end

local function faceDescription(t, values)
	local parts = {}
	for _, part in ipairs(FACE_PARTS) do
		if t.count[part.group] then
			table.insert(parts, string.format("%s #%d", part.side, values[part.group] + 1))
		end
	end
	return table.concat(parts, ", ")
end

-- Keys the face on the clip. Returns a summary, or nil and why not.
local function applyFace(t, values)
	local ks = t.ks
	local kfs = sortedKeyframes(ks)
	local headName = t.head or "Head"
	local function headPose(kf)
		for _, p in ipairs(kf:GetDescendants()) do
			if p:IsA("Pose") and p.Name == headName then
				return p
			end
		end
	end
	local first, last
	for _, kf in ipairs(kfs) do
		local h = headPose(kf)
		if h then
			first = first or h
			last = h
		end
	end
	if not first then
		return nil, ks.Name .. " has no '" .. headName .. "' key to hang the face keys on."
	end
	local removed = 0
	for _, kf in ipairs(kfs) do
		for _, p in ipairs(kf:GetDescendants()) do
			if p:IsA("Pose") and t.bones[(faceGroupOf(p.Name))] then
				p:Destroy()
				removed += 1
			end
		end
	end
	for _, head in ipairs(first == last and { first } or { first, last }) do
		for g, bones in pairs(t.bones) do
			local default = defaultOf(t, g)
			local shown = values[g] or default
			for n, name in pairs(bones) do
				local on = turnedFor(n, shown, default)
				local pose = Instance.new("Pose")
				pose.Name = name
				pose.CFrame = on and CFrame.fromAxisAngle(t.axes[name] or Vector3.yAxis, FACE_TURN) or CFrame.identity
				pose.EasingStyle = Enum.PoseEasingStyle.Constant
				pose.Parent = head
			end
		end
	end
	-- The clip changed: a new fingerprint, and the rig's tracks of it lose their upload so "Upload rig animations"
	-- sends the new face (the same as importing a changed clip again).
	local desc = faceDescription(t, values)
	ks:SetAttribute("UmaClipHash", fingerprint((ks:GetAttribute("UmaClipHash") or "") .. "|face|" .. desc))
	ks:SetAttribute("UmaFace", desc)
	local cleared = 0
	local folder = t.rig and t.rig:FindFirstChild(ANIMATE_FOLDER)
	for _, a in ipairs(folder and folder:GetDescendants() or {}) do
		if a:IsA("Animation") and a:GetAttribute("UmaClip") == ks.Name and a.AnimationId ~= "" then
			a.AnimationId = ""
			a:SetAttribute("UmaClipHash", nil)
			a:SetAttribute("UmaUploadedTo", nil)
			cleared += 1
		end
	end
	return string.format("%s: face set to %s for the whole clip (%d old face key(s) replaced).%s", ks.Name, desc,
		removed, cleared > 0 and string.format(
			"\n%d track(s) of this clip in %s.%s now need uploading: click 'Upload rig animations'. Animations elsewhere that use its old asset id need the new id afterwards.",
			cleared, t.rig.Name, ANIMATE_FOLDER) or "")
end

local faceWidget = plugin:CreateDockWidgetPluginGui(
	"Uma2RobloxFace",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, 320, 300, 260, 220)
)
faceWidget.Title = "Uma Face"
local faceButton = toolbar:CreateButton("Uma Face", "Set one face (mayu, eyes, mouth) for a whole clip",
	"rbxassetid://4458901886")
faceButton.ClickableWhenViewportHidden = true
faceButton.Click:Connect(function()
	faceWidget.Enabled = not faceWidget.Enabled
end)
faceWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	faceButton:SetActive(faceWidget.Enabled)
end)
button("Open face editor (one face for a whole clip)", function()
	faceWidget.Enabled = true
end)

local faceFrame = Instance.new("ScrollingFrame")
faceFrame.Size = UDim2.fromScale(1, 1)
faceFrame.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainBackground)
faceFrame.BorderSizePixel = 0
faceFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
faceFrame.CanvasSize = UDim2.new()
faceFrame.ScrollBarThickness = 6
faceFrame.Parent = faceWidget
do
	local p = Instance.new("UIPadding")
	p.PaddingLeft, p.PaddingRight, p.PaddingTop = UDim.new(0, 8), UDim.new(0, 8), UDim.new(0, 8)
	p.Parent = faceFrame
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = faceFrame
end
-- widgets made with the main panel's helpers, moved into this panel
local function inFace(gui)
	gui.Parent = faceFrame
	return gui
end

local face = nil -- readFace() of the current clip
local faceValues = {} -- group -> 0-based sprite index shown
local faceLinked = true -- left and right share one slider
local previewed = {} -- bones whose Transform the preview set
local faceRows = {} -- group -> { row, name label, show(value, count) }

local clipLabel = inFace(label("", nil))
clipLabel.LayoutOrder = 1
local linkButton -- LayoutOrder 2, made below; the slider rows are 3-7, then the buttons and status
local faceStatus
local function showLinked()
	linkButton.Text = (faceLinked and "[x] " or "[ ] ") .. "Same sprite for left and right"
end

local function clearPreview()
	for bone in pairs(previewed) do
		if bone.Parent then
			bone.Transform = CFrame.identity
		end
	end
	previewed = {}
end

local function preview()
	if not (face and face.rig and faceWidget.Enabled) then
		clearPreview()
		return
	end
	for g, bones in pairs(face.bones) do
		local default = defaultOf(face, g)
		local shown = faceValues[g] or default
		for n, name in pairs(bones) do
			local bone = face.rigBones[name]
			if bone and bone.Parent then
				local on = turnedFor(n, shown, default)
				bone.Transform = on and CFrame.fromAxisAngle(face.axes[name] or Vector3.yAxis, FACE_TURN) or CFrame.identity
				previewed[bone] = true
			end
		end
	end
end

local function refreshRows()
	for _, part in ipairs(FACE_PARTS) do
		local r = faceRows[part.group]
		local count = face and face.count[part.group]
		r.row.Visible = count ~= nil and not (faceLinked and part.follows ~= nil)
		r.name.Text = faceLinked and part.name or part.side
		if count then
			r.show(faceValues[part.group] or 0, count)
		end
	end
end

local function setValue(group, v)
	local count = face and face.count[group]
	if not count then
		return
	end
	faceValues[group] = math.clamp(math.floor(v + 0.5), 0, count - 1)
	if faceLinked then -- the left slider drives its right side too
		for _, part in ipairs(FACE_PARTS) do
			if part.follows == group and face.count[part.group] then
				faceValues[part.group] = math.min(faceValues[group], face.count[part.group] - 1)
			end
		end
	end
	refreshRows()
	preview()
end

for i, part in ipairs(FACE_PARTS) do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 24)
	row.BackgroundTransparency = 1
	row.LayoutOrder = 2 + i
	row.Parent = faceFrame
	local name = label(part.name, 24)
	name.Parent = row
	name.Size = UDim2.new(0, 56, 1, 0)
	name.TextYAlignment = Enum.TextYAlignment.Center
	local value = label("", 24)
	value.Parent = row
	value.Size = UDim2.new(0, 50, 1, 0)
	value.Position = UDim2.fromOffset(56, 0)
	value.TextYAlignment = Enum.TextYAlignment.Center
	local function step(text, x, d)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 22, 1, 0)
		b.Position = x
		b.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.Button)
		b.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.ButtonText)
		b.Font = Enum.Font.SourceSansBold
		b.TextSize = 16
		b.Text = text
		b.Parent = row
		b.MouseButton1Click:Connect(function()
			setValue(part.group, (faceValues[part.group] or 0) + d)
		end)
	end
	step("<", UDim2.fromOffset(108, 0), -1)
	step(">", UDim2.new(1, -22, 0, 0), 1)
	-- the slider: click or drag along the track
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -160, 0, 6)
	track.Position = UDim2.new(0, 134, 0.5, -3)
	track.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground)
	track.BorderSizePixel = 0
	track.Active = true
	track.Parent = row
	local hit = Instance.new("TextButton") -- a taller, invisible hit area over the thin track
	hit.Size = UDim2.new(1, 0, 0, 24)
	hit.Position = UDim2.new(0, 0, 0.5, -12)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Parent = track
	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(10, 16)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.DialogMainButton)
	knob.BorderSizePixel = 0
	knob.Parent = track
	local dragging = false
	local function fromX(x)
		local count = face and face.count[part.group]
		if count and count > 1 then
			local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
			setValue(part.group, a * (count - 1))
		end
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			fromX(input.Position.X)
		end
	end)
	hit.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			fromX(input.Position.X)
		end
	end)
	hit.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	hit.MouseLeave:Connect(function()
		dragging = false
	end)
	faceRows[part.group] = {
		row = row,
		name = name,
		show = function(v, count)
			value.Text = string.format("#%d / %d", v + 1, count)
			knob.Position = UDim2.new(count > 1 and v / (count - 1) or 0, 0, 0.5, 0)
		end,
	}
end

local function setClip(ks)
	clearPreview()
	face = ks and readFace(ks) or nil
	faceValues = face and table.clone(face.values) or {}
	if face then
		-- linked when the clip starts with the same sprite on both sides
		faceLinked = (faceValues.Mayu_L == faceValues.Mayu_R) and (faceValues.Eye_L == faceValues.Eye_R)
		showLinked()
		clipLabel.Text = string.format("Clip: %s\n%s", ks:GetFullName(), face.rig
			and ("Preview on: " .. face.rig:GetFullName())
			or "No rig in the place for this clip's save folder: no preview.")
		if next(face.bones) == nil then
			clipLabel.Text ..= "\nThis clip and its rig have no Face_ sprite bones."
		end
	else
		clipLabel.Text = "Select a clip: a KeyframeSequence in ServerStorage.RBX_ANIMSAVES, or an Animation in a rig's "
			.. ANIMATE_FOLDER .. " folder. The last one selected stays here."
	end
	refreshRows()
	preview()
end

linkButton = inFace(button("", function()
	faceLinked = not faceLinked
	showLinked()
	if faceLinked then -- the right side takes the left side's sprite
		for _, part in ipairs(FACE_PARTS) do
			if part.follows then
				setValue(part.follows, faceValues[part.follows] or 0)
			end
		end
	end
	refreshRows()
	preview()
end))
linkButton.LayoutOrder = 2
showLinked()

inFace(button("Reset sliders to the clip's starting face", function()
	if face and face.ks.Parent then
		setClip(face.ks)
	end
end)).LayoutOrder = 8
local applyButton = primary(inFace(button("Apply to whole clip", function()
	if not (face and face.ks:IsDescendantOf(game)) then
		faceStatus.Text = "Select a clip first."
		return
	end
	if next(face.bones) == nil then
		faceStatus.Text = face.ks.Name .. " has no face sprite bones."
		return
	end
	local msg, err
	record("Uma2Roblox: set clip face", function()
		msg, err = applyFace(face, faceValues)
	end)
	faceStatus.Text = msg or err or "Applying the face failed (see Output)."
end)))
applyButton.LayoutOrder = 9
faceStatus = inFace(label(""))
faceStatus.LayoutOrder = 10

Selection.SelectionChanged:Connect(function()
	for _, inst in ipairs(Selection:Get()) do
		local ks = clipOf(inst)
		if ks then
			if not (face and face.ks == ks) then
				setClip(ks)
			end
			return
		end
	end
end)
faceWidget:GetPropertyChangedSignal("Enabled"):Connect(function()
	if faceWidget.Enabled and face and not face.ks:IsDescendantOf(game) then
		setClip(nil)
	end
	preview()
end)
plugin.Unloading:Connect(clearPreview)
setClip(nil)
end

status = label("")

-- detection: whenever a model named Uma_* (an Import 3D result) shows up, fix its cheek/mayu parts
local pending = {}
workspace.DescendantAdded:Connect(function(d)
	if not cfg.autoTransparency or not d:IsA("MeshPart") or not isTransparentPart(d) then
		return
	end
	local m = d:FindFirstAncestorWhichIsA("Model")
	while m and m.Parent and m.Parent:IsA("Model") do
		m = m.Parent
	end
	if not m or not parseName(m.Name) then
		return
	end
	pending[d] = true
	task.defer(function()
		if pending[d] and d.Parent and d.Transparency < TRANSPARENT_PASS then
			d.Transparency = TRANSPARENT_PASS
		end
		pending[d] = nil
	end)
end)
