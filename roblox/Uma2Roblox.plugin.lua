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
	      - asks where SmartBone 2 comes from: the copy provided with this plugin (v0.5.2), the latest release
	        on GitHub (smartbone-org/SmartBone-2), or the one already in the place (selection, anywhere in the
	        place, or the asset id entered in the panel); puts it in ReplicatedStorage
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

-- Which Uma a rig is: its UmaCharaId / UmaCostume / UmaSource attributes, written as soon as the import is seen,
-- so the rig keeps them when it is renamed (StarterCharacter) or copied; the model name is only the fallback.
local function umaIdentity(model)
	local id, costume = parseName(model.Name)
	id = tonumber(model:GetAttribute("UmaCharaId")) or id
	costume = model:GetAttribute("UmaCostume") or costume or (id and "00")
	return id, costume, model:GetAttribute("UmaSource") or model.Name
end

local function stampIdentity(model)
	local id, costume = parseName(model.Name)
	if id and model:GetAttribute("UmaCharaId") == nil then
		model:SetAttribute("UmaCharaId", id)
		model:SetAttribute("UmaCostume", costume)
	end
	if id and model:GetAttribute("UmaSource") == nil then
		model:SetAttribute("UmaSource", model.Name) -- the .glb name
	end
end

-- Query string the app finds this rig's sidecar with: the .glb name, plus the Uma id and costume so it still
-- finds it when that name is not the .glb's (a rig renamed before it had UmaSource, or a re-export).
local function umaQuery(model)
	local id, costume, source = umaIdentity(model)
	local q = "model=" .. HttpService:UrlEncode(source)
	if id then
		q ..= "&id=" .. id .. "&costume=" .. HttpService:UrlEncode(costume)
	end
	return q, source
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

	stampIdentity(model)
	model:SetAttribute("UmaToon", true)
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
-- The fit is made in the rig's own space (the part its bones hang under), where the glTF axes land on an axis
-- rotation however the rig is turned in the world; fitted in world space, a rig at 30 degrees of yaw got the
-- nearest axis rotation and every collider, tail and animation came out turned by the rest.
local function fitSpace(skeleton, bonesByName)
	local frame = CFrame.identity
	for _, bone in pairs(bonesByName) do
		local part = bone:FindFirstAncestorWhichIsA("BasePart")
		if part then
			frame = part.CFrame
			break
		end
	end
	local g, p = {}, {}
	for _, b in ipairs(skeleton) do
		local bone = bonesByName[b.name]
		if bone then
			table.insert(g, Vector3.new(b.world[1], b.world[2], b.world[3]))
			table.insert(p, frame:PointToObjectSpace(bone.WorldPosition))
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
	best.t = frame:PointToWorldSpace(cp - best.R:VectorToWorldSpace(cg * best.s))
	best.R = frame.Rotation * best.R -- rig space -> world
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

-- Playable character. Imported animations make the rig a character UmaAnimateHandler can drive (it keeps its
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

-- The rig's own animations for UmaAnimateHandler (and older Uma Animate scripts), in the Animate format (a StringValue per animation set holding
-- Animation instances, each with an optional Weight NumberValue), in a "UmaAnimate" folder on the rig:
--   idle    the costume's own idle if it has one (alt outfits), else the character's idle01 (its _loop clip)
--   Emote.Emote<n>  one per non-idle clip set of the character (res, mot, act, ..., from every outfit), in an
--           "Emote" folder: Animation "Start" (<x>_s) then "Loop" (<x>_loop), played by /e Emote<n> (/e Emote = a
--           random one). Numbered res first, then mot, act, others; this outfit, the base outfit, then the others.
--           The StringValue's Value says which clip it is ("res01", "mot01", "res01 (costume 20)").
-- AnimationIds start empty; "Upload rig animations" fills them in, and importing again keeps them for clips that
-- did not change.
local ANIMATE_FOLDER = "UmaAnimate"
local EMOTES_FOLDER = "Emote" -- the rig's own /e command, as UmaAnimateHandler's Dance, Umapyoi

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
	local id, costume = umaIdentity(model)
	costume = costume or "00"
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
	stampIdentity(model)
	local query, source = umaQuery(model)
	local index = fetchJson("/anims?" .. query)
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
		local anim = fetchJson("/anim?" .. query .. "&name=" .. HttpService:UrlEncode(name))
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
	local _, _, source = umaIdentity(model)
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
	"UmaSpringCollideWith", "UmaSpringTail", "UmaSpringAxisX", "UmaSpringAxisY", "UmaSpringLimitX", "UmaSpringLimitY" }

local function importPhysics(model)
	stampIdentity(model)
	local ok, data = pcall(fetchJson, "/physics?" .. (umaQuery(model)))
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
	local function boneSpace(bone, v) -- GLB-space vector -> the bone's space (GLB metres)
		return bone.WorldCFrame:VectorToObjectSpace(fit.R:VectorToWorldSpace(Vector3.new(v[1], v[2], v[3])))
	end
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
					if b.axes then -- the game's own per-axis limits: swing about the bone's x / y in [-min, +max]
						bone:SetAttribute("UmaSpringAxisX", boneSpace(bone, b.axes[1]).Unit)
						bone:SetAttribute("UmaSpringAxisY", boneSpace(bone, b.axes[2]).Unit)
						bone:SetAttribute("UmaSpringLimitX", Vector2.new(l[1], l[4]))
						bone:SetAttribute("UmaSpringLimitY", Vector2.new(l[2], l[5]))
					end
				end
				if b.tail then -- offset to the chain's tip bone, which the rig does not have (GLB metres, bone space)
					bone:SetAttribute("UmaSpringTail", boneSpace(bone, b.tail))
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
				local p = boneSpace(bone, v)
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
	swingLimits = true, -- the game's per-axis angle limits (min/max about each bone's own x and y)
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
			-- the game's lopsided per-axis limits (read by the plugin's SmartBone patch): what stops a strand
			-- tipping into the head, which one symmetric cone cannot
			local lx, ly = d:GetAttribute("UmaSpringLimitX"), d:GetAttribute("UmaSpringLimitY")
			if GAME.swingLimits and lx and ly and math.min(lx.X, lx.Y, ly.X, ly.Y) < 180 then
				setDefault(d, "SwingAxisX", d:GetAttribute("UmaSpringAxisX"))
				setDefault(d, "SwingAxisY", d:GetAttribute("UmaSpringAxisY"))
				setDefault(d, "SwingLimitX", lx)
				setDefault(d, "SwingLimitY", ly)
			end
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

-- Where the tail bone SmartBone adds past a chain's last bone goes (RestTail, studs in bone space; read by the
-- plugin's patch). The rig has no tip bones, so by default SmartBone would point that tail along the parent ->
-- bone line, which for a single-bone strand on the head or hips points up and flips the strand over. The game's
-- tip offset (UmaSpringTail) is used when the rig has it; otherwise a strand straight off a body bone whose
-- parent -> bone line points up (head hair, back of the skirt, waist ribbons) hangs down instead.
local TAIL_FALLBACK = 0.3 -- fallback tail length, as a fraction of the distance from the body bone
local TAIL_UP = 0.4 -- the parent -> bone line counts as pointing up above this (cosine to the rig's up)
local function setTails(model, rp)
	local s = studsPerMetre(model)
	for _, d in ipairs(rp:GetDescendants()) do
		if isSpring(d) and not excluded(d.Name) and not d:FindFirstChildWhichIsA("Bone") then
			local tail = d:GetAttribute("UmaSpringTail")
			if typeof(tail) == "Vector3" and s then
				setDefault(d, "RestTail", tail * s)
			elseif not isSpring(d.Parent) then
				local p = d.Parent
				local line = d.WorldPosition - (p:IsA("Bone") and p.WorldPosition or p.Position)
				if line.Magnitude > 1e-4 and line.Unit:Dot(rp.CFrame.UpVector) > TAIL_UP then
					setDefault(d, "RestTail", d.WorldCFrame:VectorToObjectSpace(-rp.CFrame.UpVector) * line.Magnitude * TAIL_FALLBACK)
				end
			end
		end
	end
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
	setTails(model, rp)
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
-- to its child at rest instead, and grow the tail bone it adds to a chain's last bone toward the bone's RestTail
-- (the game's tip, set by the UmaChibi runtime), else along the parent -> bone line. SmartBone also reads the animated pose from the bones' CFrames, which it writes itself: the springs
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
	{ -- after the patch above (a copy patched by an older plugin has it already), so this one wins
		path = {},
		find = "\t\t\t\tStart = Bone.WorldCFrame + (Bone.WorldPosition - ParentWorldPosition)\n\t\t\tend",
		add = "\n\t\t\t" .. SB_MARK .. ": a tail the rig gives (RestTail, bone space) wins: the strand's real tip\n"
			.. '\t\t\tlocal RestTail = RootPart:GetAttribute("RestAxisFromChild") and Bone:GetAttribute("RestTail")\n'
			.. '\t\t\tif typeof(RestTail) == "Vector3" and RestTail.Magnitude > 1e-5 then\n'
			.. "\t\t\t\tStart = Bone.WorldCFrame + Bone.WorldCFrame:VectorToWorldSpace(RestTail)\n"
			.. "\t\t\tend",
	},
	{ -- the game's per-axis swing limits; SmartBone only has a symmetric cone, which it also never applies to the
		-- first particle below a chain's anchored root (a single-bone bang has no limit at all)
		path = { "Components", "Bone" },
		find = "function Class:Constrain(BoneTree, ColliderObjects, Delta: number) -- Parallel safe",
		replace = SB_MARK .. ": swing limits. A bone with SwingAxisX/Y (unit, its own space) and SwingLimitX/Y\n"
			.. "-- (Vector2 min, max degrees) keeps each child's direction within [-min, +max] of its rest direction about\n"
			.. "-- those axes, measured in the bone's current frame (animated, turned by its own swing).\n"
			.. "local function UmaSwing(Bone)\n"
			.. "\tif Bone.UmaSwing == nil then\n"
			.. "\t\tBone.UmaSwing = false\n"
			.. "\t\tlocal Object = Bone.Bone\n"
			.. '\t\tlocal AX, AY = Object:GetAttribute("SwingAxisX"), Object:GetAttribute("SwingAxisY")\n'
			.. '\t\tlocal LX, LY = Object:GetAttribute("SwingLimitX"), Object:GetAttribute("SwingLimitY")\n'
			.. '\t\tif typeof(AX) == "Vector3" and typeof(AY) == "Vector3" and typeof(LX) == "Vector2" and typeof(LY) == "Vector2" then\n'
			.. "\t\t\tBone.UmaSwing = { AX.Unit, AY.Unit, math.rad(LX.X), math.rad(LX.Y), math.rad(LY.X), math.rad(LY.Y) }\n"
			.. "\t\tend\n"
			.. "\tend\n"
			.. "\treturn Bone.UmaSwing\n"
			.. "end\n"
			.. "\n"
			.. "local function UmaSwingConstraint(self, Position, BoneTree)\n"
			.. "\tlocal Parent = BoneTree.Bones[self.ParentIndex]\n"
			.. "\tlocal Swing = Parent and self.RestAxis and UmaSwing(Parent)\n"
			.. "\tif not Swing then\n"
			.. "\t\treturn Position\n"
			.. "\tend\n"
			.. "\tlocal Frame = Parent.AnimatedWorldCFrame.Rotation\n"
			.. "\tlocal Grand = BoneTree.Bones[Parent.ParentIndex]\n"
			.. "\tif Grand and not Parent.Anchored then -- the parent's own swing turns the frame its limits are in\n"
			.. "\t\tlocal RestDir = Parent.AnimatedWorldCFrame.Position - Grand.AnimatedWorldCFrame.Position\n"
			.. "\t\tlocal NowDir = Parent.Position - Grand.Position\n"
			.. "\t\tif RestDir.Magnitude > 1e-5 and NowDir.Magnitude > 1e-5 then\n"
			.. "\t\t\tFrame = Utilities.GetRotationBetween(RestDir.Unit, NowDir.Unit).Rotation * Frame\n"
			.. "\t\tend\n"
			.. "\tend\n"
			.. "\tlocal Offset = Position - Parent.Position\n"
			.. "\tlocal Length = Offset.Magnitude\n"
			.. "\tif Length < 1e-5 then\n"
			.. "\t\treturn Position\n"
			.. "\tend\n"
			.. "\tlocal Rest = Frame:VectorToWorldSpace(self.RestAxis)\n"
			.. "\tlocal Dir = Offset / Length\n"
			.. "\tfor i = 1, 2 do\n"
			.. "\t\tlocal Axis = Frame:VectorToWorldSpace(Swing[i])\n"
			.. "\t\tlocal A = Rest - Axis * Axis:Dot(Rest)\n"
			.. "\t\tlocal B = Dir - Axis * Axis:Dot(Dir)\n"
			.. "\t\tlocal Angle = math.atan2(Axis:Dot(A:Cross(B)), A:Dot(B))\n"
			.. "\t\tlocal Clamped = math.clamp(Angle, -Swing[2 * i + 1], Swing[2 * i + 2])\n"
			.. "\t\tif Clamped ~= Angle then\n"
			.. "\t\t\tDir = CFrame.fromAxisAngle(Axis, Clamped - Angle):VectorToWorldSpace(Dir)\n"
			.. "\t\tend\n"
			.. "\tend\n"
			.. "\treturn Parent.Position + Dir * Length\n"
			.. "end\n"
			.. "\n"
			.. "function Class:Constrain(BoneTree, ColliderObjects, Delta: number) -- Parallel safe",
	},
	{
		path = { "Components", "Bone" },
		find = "Position = RotationConstraint(self, Position, BoneTree)",
		add = "\n\t" .. SB_MARK .. ": the game's per-axis swing limits\n"
			.. "\tPosition = UmaSwingConstraint(self, Position, BoneTree)",
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

-- SmartBone 2 (MIT License, Copyright (c) 2024 SmartBone; https://github.com/smartbone-org/SmartBone-2):
-- SmartBoneSource.provided() is the copy that comes with this plugin (its v0.5.2 release .rbxm, the same sources as
-- the SmartBone the plugin was tested with), SmartBoneSource.latest() downloads the latest release from GitHub.
-- Both return the SmartBone ModuleScript (not parented) and its version, or nil and why.
--
-- The provided copy is under SmartBone 2's own license:
-- MIT License
--
-- Copyright (c) 2024 SmartBone
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
local SmartBoneSource = {}
do
	local PROVIDED_VERSION = "v0.5.2"
	local REPO = "smartbone-org/SmartBone-2"
	local PROVIDED_RBXM = [==[
PHJvYmxveCGJ/w0KGgoAAAMAAABLAAAAAAAAAAAAAABNRVRBJAAAACIAAAAAAAAA8BMBAAAAEgAAAEV4cGxpY2l0QXV0b0pvaW50cwQAAAB0cnVlSU5TVCAA
AAAvAAAAAAAAAPABAAAAAAYAAABGb2xkZXIABxAADwIAAXACNAYsBgYMSU5TVB4AAAAcAAAAAAAAAPANAQAAAAsAAABMb2NhbFNjcmlwdAABAAAAAAAAMklO
U1Q6AAAAJQEAAAAAAAD/CAIAAAAMAAAATW9kdWxlU2NyaXB0AEMAAQC5LwQCAQACPwQEAhoAAgAXAAEZAKAEAgICAgICAgICUFJPUCoAAAA4AAAAAAAAAPAN
AAAAABMAAABBdHRyaWJ1dGVzU2VyaWFsaXplARwADwIAAFAAAAAAAFBST1AjAAAATQAAAAAAAADwBgAAAAAMAAAAQ2FwYWJpbGl0aWVzIRUADwIAHFAAAAAA
AFBST1AlAAAAIwAAAAAAAADwFAAAAAATAAAARGVmaW5lc0NhcGFiaWxpdGllcwIAAAAAAAAAUFJPUF4AAABnAAAAAAAAAPEPAAAAAAQAAABOYW1lAQwAAABE
ZXBlbmRlbmNpZXMFEADxDWJ1ZwYAAABHaXptb3MKAAAAQ29tcG9uZW50cwkOAHVsbGlzaW9uDQBRZGVycwsaAJBuc3RyYWludHNQUk9QJgAAAE4AAAAAAAAA
8AcAAAAADQAAAFNvdXJjZUFzc2V0SWQbFgAPAgAacAEBAQEBAQFQUk9QGgAAACkAAAAAAAAA0AAAAAAEAAAAVGFncwENAA8CAABQAAAAAABQUk9QIgAAACAA
AAAAAAAA8BEBAAAAEwAAAEF0dHJpYnV0ZXNTZXJpYWxpemUBAAAAAFBST1AfAAAAHQAAAAAAAADwDgEAAAAMAAAAQ2FwYWJpbGl0aWVzIQAAAAAAAAAAUFJP
UB8AAAAdAAAAAAAAAPAOAQAAABMAAABEZWZpbmVzQ2FwYWJpbGl0aWVzAgBQUk9QFAAAABIAAAAAAAAA8AMBAAAACAAAAERpc2FibGVkAgBQUk9QGwAAABkA
AAAAAAAA8AoBAAAADAAAAExpbmtlZFNvdXJjZQEAAAAAUFJPUBoAAAAYAAAAAAAAAPAJAQAAAAQAAABOYW1lAQcAAABSdW50aW1lUFJPUBkAAAAXAAAAAAAA
APAIAQAAAAoAAABSdW5Db250ZXh0EgAAAABQUk9QPwAAAD0AAAAAAAAA8C4BAAAACgAAAFNjcmlwdEd1aWQBJgAAAHszOTQ4RDI4MS1GNkY2LTQwQUQtQkQy
RC0xNkM1M0NCNDFBQzF9UFJPUAYIAAD6EAAAAAAAAPIQAQAAAAYAAABTb3VyY2UB5xAAAGxvY2FsIEFjdG9yOgcA8gIgPSBzY3JpcHQuUGFyZW50CiMAlFJv
b3RPYmplYxEAokNvbGxpZGVyRGUvAENpb25zLAD8AFNtYXJ0Ym9uZU1vZHVsZRYAZENsYXNzChYAxGV0dXAgPSBmYWxzZRUA9AFDT05ORUNUSU9OUyA9IHt9
GADxBmZ1bmN0aW9uIGMoQ29ubjogUkJYU60AAA8AEWUcAPcBKQoJdGFibGUuaW5zZXJ0KEwAICwgJwBeKQplbmRSAPIAbGVhbnVwKCkKCWZvciBfLAAPYgAC
RyBpbiBWAGAgZG8KCQlaAFI6RGlzY4kAAEgAAGcAAAQAA+oAUEJpbmQKBQAiID1qARA6DQCxVG9NZXNzYWdlKCILASUiLOYAMihtX3IBTywgbV9vAQEAGAAB
bAF2Qm9uZSkKCaQBNCA9ID0ALwoJOwABASEADxkAASEKCVIABr4BASoAARQAAGYABx8AAccBtyA9IHJlcXVpcmUoJgBBKQoKCc4AoCA9IHRydWUKCgnsAAog
AcBlbmQpCgpyZXBlYXS0AeNzay53YWl0KCkKdW50aRoCBKgBAKsAAuAB8wNTZXJ2aWNlID0gZ2FtZTpHZXQSAC0oIiUAIyIpfAEzUnVuJgAPOAABBh4ABTEA
AOwAoVBoeXNpY3MgPSD/AAATAQH0AFQubmV3KFoAuURlcGVuZGVuY2llKgAC+wIYLh8AA4wAd0RlYnVnVWk6AQglABEuHwACBgAkVWlmADRJcmldA29Db25m
aWc+AAUCHgAENwBiVXRpbGl0mgAEpwEJbQAFIQAEMgBhU2hvdWxkhAA2ID0gGQHgOklzU3R1ZGlvKCkgb3JIA/MKZmlnLkFMTE9XX0xJVkVfR0FNRV9ERUJV
R+cAyE92ZXJsYXlFdmVudEMBAhkB+AA6V2FpdEZvckNoaWxkKCItACQiKfUBxkZvcmNlRGVzdHJveSME8AEtLSBTbyBtdWNoIHdvcmsgrwMQcw4AkGEgYmFz
aWMgZGEBUyB0b29siwAjSW1gAABNBHAKCUJlZ2luUAADTgSDKC4uLikKCQklAAGyACA6RtMCESIrADIiLCAiAHFlbmQsCglFwgMFpQMCGwAPPQABO0VuZDsA
MFRleAwBDzwAEAAqAAo9ABF9+gDRRnJhbWUgY291bnRlcvsA8AhnZXR0aW5nIGFuaW1hdGVkd29ybGRjZigAgQpzaGFyZWQuNQATQzQAMz0gMBcBCBcAAPwA
+QJmbG93ID0gMTMxMDcyCgppZg4CYHRoZW4KCYkCD3wCBQAcAKApCglpZiBub3QgDgBgLkhhc0lu1AMDPwAEQAABHQACGgABVwECkwUBhwYgLk7iAEY9IGB7
zwQBFABXfSAtIHuYA3cuSUR9YAoKEgBSOkxvYWQzBRYoPQAwKQoKIwIB0gUNswYBzAUPygYAAdUFDFsANFJhd0MAFCgJAAf/BjBbMV02Bg1kADFbMl3uBATX
AgFeA19TdGF0ZWUBBAYhAAKxAqQJRFJBV19CT05FOwEBPgARKDQHJCksIQCPUEhZU0lDQUwqAA+fUk9PVF9QQVJUUAAKz0JPVU5ESU5HX0JPWCkACqBBWElT
X0xJTUlUrwcPoQAHj0NPTExJREVSJgATn19JTkZMVUVOQ/YACwRVAF9fQVdBSysAFJ9CUk9BRFBIQVMwAAtFRklMTGAAD7UADU9OVEFDAAEMQFJPVEHVCA8s
ARFyQUNDRUxFUjAAT0lORk+CAQQSfTsDABUFB7sF8AJpcyBqdXN0IGlmIHdlIGFyZegCEXPBBQC/BT9ub3TfAwcQOssIRWVjdCinBAAdBTZpZiBTAwB2B7FB
dHRyaWJ1dGUoIrAClCIpIH49IG5pbOsDEQkXADBVaSgRAicsIE0DISwgGwABxQIAXAAAJQkRCQ8IAAoAEArdCQvuBwBxAPEGSW5zdGFuY2VBZGRlZFNpZ25h
bCgimgcALwAAiwouIim8AAIPBKY6IEJhc2VQYXJ0oQQDGgBUSXNBKCIeACQiKb4AYnJldHVybp0EIgoJBAsEaAAgS2WPBgNAAAoLAQcjACQiKTgAADkBBxkA
AFkHBU4LANoAB0sBBycAAAgHAE0FhXRvc3RyaW5ncwQxS2V5bAEFGQALYAAPxAASAr4ANSA9IAMIRC5HZXR/ABIoHwAAyAkHuAEBYAUPBQUBAi4AIiwgCAAB
xwFhKSkKCmMo0gUM6AoD0gcI6go7KQoJ7QcBNwoAFAIBSAAGwAkwLkhlXQw0ZWF07AGGUGFyYWxsZWywAoBkZWx0YVRpbRQLDwMHAUIrPSAxXAEPHgABHz4Z
BwMDwQYPMgABND0gMCkCCC4BQFN0ZXAQAFhUcmVlc5UAASQHABoAA2IKFC5oBwLqCDlvciANAQN6AAcxABM6KwAQKEwAAjsLsHN5bmNocm9uaXplVAcXCdAM
C8wCDysEHwCGAgSjAAFbCQELCAAWAAB6AgL1AQvIAgEpAA4TBA+rAAIK2gAxcmF3PQA0KAoJRAQBKQQRLgUHBY4FUTpnZXQo/AYhCQkwAAklAAKNBQ8kAAkJ
LQcPKQAJDyAADQf9Bg9HAAkFcwcPJQAJCnEGDyoACQQIAQYlBw8uABIBJAcPKgASBiMHDy8ACQgjCA8oAAkL+gYPKwAJDfkGAi0AAA4CAe4CDS4CALsKRWxh
eSjmCwhTBnAKZW5kKSkKUFJPUCAAAAAeAAAAAAAAAPAPAQAAAA0AAABTb3VyY2VBc3NldElkGwAAAAAAAAABUFJPUBMAAAARAAAAAAAAAPACAQAAAAQAAABU
YWdzAQAAAABQUk9QKAAAACgBAAAAAAAA/w4CAAAAEwAAAEF0dHJpYnV0ZXNTZXJpYWxpemUBAAEA81AAAAAAAFBST1AjAAAALQIAAAAAAAD/BwIAAAAMAAAA
Q2FwYWJpbGl0aWVzIQABAP//AVAAAAAAAFBST1ApAAAAXwAAAAAAAADwDAIAAAATAAAARGVmaW5lc0NhcGFiaWxpdGllcxsADwIAKFAAAAAAAFBST1AhAAAA
IQEAAAAAAAD/BwIAAAAMAAAATGlua2VkU291cmNlAQABAPNQAAAAAABQUk9QaAIAAFsDAAAAAAAA8AsCAAAABAAAAE5hbWUBCQAAAFNtYXJ0Qm9uZRYA8BdJ
cmlzBwAAAHdpZGdldHMGAAAAQnV0dG9uCAAAAENoZWNrYm94BQwAQG9tYm8fAGBGb3JtYXQTAFBJbnB1dEUA0k1lbnULAAAAUmFkaW8/AAAXADFSb28oAEFU
YWJsbQAxVGV4MABAVHJlZUsA0FdpbmRvdwMAAABBUEkRAOJjb25maWcKAAAAZGVtbx8AAIkAgEludGVybmFsdgBBVHlwZagAEUMtAPEJFQAAAERlZmF1bHRP
YmplY3RTZXR0aW5n1gCGRnJ1c3R1bQwLAFAuc3BlYwYBkFV0aWxpdGllc1QAWUdpem1vCQAyQXJymgAwQm94IAFhQ2Fwc3VstgBCQ2lyY9AAQENvbmWfAIBD
eWxpbmRlcvUAIkxpWQFATWVzaFIAUFBsYW5l4wAwUmF54wBVU3BoZXIOAQA2AWFWb2x1bWVxAACZAAIPADBCb3gHAQINAABoABYODgADbgAA1gACIAACVAAA
bgBQV2VkZ2VGAJBJbU92ZXJsYXk4AFVDZWl2ZRIAAM8AcERlYnVnVWmxAAAKAgDFAAAIAACZAQAMAIFDb2xsaWRlcj0AAwwAAl4BAMoAChMBATAAA5MABuEA
ABYAgFRyaWFuZ2xlRgDwAEF4aXNDb25zdHJhaW50E/MBCRIAAZgBABcAAXsARnNpb24uABAS4wF2aXN0YW5jZRYAGhYWAAJZAAFHAAAwAFlGcmljdEYAAIYA
N1JvcEIAAG8AChIABT8ASlJvdGE/ABAQOgPwAHByaW5nQ29uc3RyYWludFBST1AiCgAAEQsAAAAAAADxLgIAAAAKAAAAU2NyaXB0R3VpZAEmAAAAezY2QTkz
Q0M5LTdCQjUtNDNFQi1BN0JDLTQyMkYxQzA0MUQ5RH0qAPIVODMwMjdBRjctMjM1MC00RjY2LUE3ODAtMzYyREMwNTk5Q0Q3KgDzFDZDNzg3MUU1LTI3MTEt
NDlBMi05ODNFLTAwRkExMEQzRDhCVADyFTNBQjJEOTQ3LUI5NjUtNDA0My05NjA2LUE1MzVBMzAzNEIzRlQA8hU0MzdGODY4NC1EQkU4LTQxMjctODMzNS1D
OEMzMTI5N0ZFODIqAPMVRDkzN0FBMjYtOTA2Ny00NkQyLUJCOEYtQUE2Nzk2NENBQjUzKgCiRjAwODdCMi1BNCoA8gRCLUEzRkMtNkU5NUI2QUZCNkZDKgDy
FTEwNTkyMUJCLUI1OTktNDQ2Qy05RUFBLUQ3QUQ1RTU1NzczOCoA0EM5OUQ4M0VGLTgwRDn8APQDOC05MjYzLUFBQTFFQUVBNDIzqADzEzI5NThGQzMtNDg2
MS00NzMzLTgyRkQtMEMwRTczMTE0RjRQAfIVQ0FCQzcxNzItRjZENS00NjFFLUJFQUUtMUM3MDAzMjcwRjhFfgDyFTUzMEFDMTk4LTA2M0EtNDVGRS05NkQ3
LTRENTUxNkIwRDI3OSoA8hVGMjdCMUU4MS00QzQ3LTQ5MTAtQTg4MC1DRUVGMkYyMEQ5NEEqAPIVNEJCRTEyQ0QtQzcyNC00MzU0LThGNUItRTU1NUU4ODY5
NUYxKgDzFDYyQzdFODlDLTVCQUUtNDM2NS1CODk2LUMyQzU4NTU2RDhGqACwRjE0MEJCNEUtNjJMAvMFNjI3LUJGRDktN0FEQkZCN0RFNzaoANAwQzQ3MEQ3
Mi1BQ0JEoALzA0EtOTFFMC01RDY3NjNBOTJEQSYB9BRFM0E2OTRFMy0xRkQwLTQ1NzUtQTMwQS1FNTA1RTBCQzAzM9IAoEMzNjZBMjMtMDGkAfIGRkQzLTkz
MTgtODdFQzYwNEM4Rjk20gDwATkwNUJDRjI3LUFGMzktNDOqAvMARjMwLUI0REREODE0NzEyVADzFDFFQjRGNzQ2LTAyNEYtNDlDOC05QzM3LTNBRDMzNzk3
RDAz/ADAMzUwMkFDNjAtNTQ49ALzBDkzLTg5MjAtNTk5MkVGRjFDNkZ+APMUNEJFMDA0NDktMUQzNi00MTk3LUIxMjMtMTdEOEVDNzc5RDV2AvMUMTZDRTE0
MTEtMkRBNC00N0Y0LUExMzctNkQxRkVFQ0I4MkJQAWBBMDU5MzUmAfMKQ0UwLTQxNTItQUYyMC05RkVCRkZGMjRCRtIA9BQ4NTY4QjY5Ni0xMTlELTQ4QUYt
ODMxQi1DRDM5MkIxREYzNMoC8xNGMTFEREY3LUI1NUQtNEQ5MC04NDM0LURGQ0FEMEUxNjRDIgLQOEY1M0I3RkEtM0Q4M1AB9AI4LTlGNzMtQjM5QjMxRTQ0
Q6gA8xRCMzJFMjAwMC1GRTlFLTQwQ0EtODI3MS02NUFGMDdBNjQ1QhoE8AJCODZDNkZCQy1GNTcyLTQ4MEwC8gA1RS1DODIwRUY3MDUyMDDOAbBDRTcwRTVE
RC1DOEQE8gY1MTMtOTgxQi0wQkQ3NjIwNjcwRUIqAPMUMkMwQzkyMjctOTNEQy00RDAzLUIxNDctREJCMEY3NDg1N0PCBPQUQjk3MjJGOEUtN0U4Ni00N0Ez
LUI0NzEtNEZGOTRFMUM0OUZuBLAwMTEyMTAwLTE3QioA8wQ2Ri1BQjQ1LUFERkI1NkMwRDU2KgBQRjQ2NkIZA4BEQUVFLTRCNCoA40RGLUU4N0I4NjBENjg2
qADAMENFNUM0QkMtQkREKgDzBDI4LThEOTgtMjIzQ0VEQTk1NUGoALBBMzEwRDg1OC1CMkQE9AVEOTMtQUUwOC01NjNERkMyNDg0OCYBoDdFNTY1QzktM0bI
AIA3RjctQTczQjUBg0NDODI1NjA0qADzFDFCMTkyQ0E2LTc1RDMtNDEyNC1COTlDLUEzMThDNTVEN0VBoAKQREMxQ0Y4OUItVwHzBy00MTY2LUI2OTktN0U2
RjA4RTJBQTNMAtAzQzQ4M0RCMC03RDBDSAPzAzQtQjMwNi1DOUE1MTk3MTY0QaACsDFCQTdGOTE4LUFC0gDzBTVDQi05MkVDLTU0OUREMkQ1QUVBvgXAOTE1
MUZBQTEtRTcz5AbzBDY3LTg2OTEtQkNBRUIzRkY3QkRUAHBFMUQxMzQx8wEATAIA/gIBDgezMUY2OUFCQzFENDbKAvMUQkM3MjEzM0QtNUIwMi00RTQ5LTk0
MDktNEU5NjkyQjNFRTnSAPQUODlCNUM5QjItRTUzQi00MkYyLTg4OEQtNTQzMDUwNUExMEXKAvMTQkFENjMzQi04RDg3LTRBODItOUMyOC1BNEM2QUUxN0NG
NBoEYDJERkIxNUcC8woyMUUtNEFEQS1BQzcyLTU0NDY5RUNERUQ40gDzFDY2MUMzOTM1LTMzQUYtNDZCNC1BMERCLUFDQzQ5Njc0OUVGqABgRTE1ODdC6gL0
CUQ4Ri00MDhBLTg2RTMtRTg0ODgyNjFGMc4B8xQ4M0YyQUUxOC1DODk3LTRCMTYtQTM5MC1CNTJCQ0VCODAyNVQA8xQ0Q0VGRDA1MC1BOUU5LTQ2RkEtQjI0
QS01MUUwNTY3MUY5NRYF8AU2NjAwN0YwNi1FNzY4LTQ5OTEtOcIEszhBMjU1NjY1QUU5nAPzFEY1NzMwOTVGLUE1NTEtNEVBOS1CMDIwLTc0MkIxMDM5REEx
ygLzFDJEN0Q0OEYyLUVFOTYtNEUzNi04N0ZFLUQyMDE3QkEwNTREfgDQMDAwRTIwOTktRUM2QVUB8wMwLUIxQTMtNkEyNzM5NDE2RjlUAPMUNDlDNTU3NTct
RDU1Ny00RUU5LTkwQUYtMTRCQTlEM0NBMzdUAKBBMTEwOTIzNC1CVQHzBjQwQjktQTgyMi0zQzYxOEMxNzU5MEgD8xRDMTAzRDc3Qy1DQjA0LTQ0REUtOERE
Qi1FQzhCQTg2RkVBMfwA8AEyMDVGQURDOC04OTExLTQzCgjzADUwNi02MUZENDRDQUZGMPQCYDMwQUY5ODUEgEY5Ri00REIx3AjiOC1GNDY0NTEzMTk1NTVQ
AdA0N0YzOEYxNy1GQkFB4AdQQS1BNELOAZNBMkFEMzhBNDT8APAKMUNFQzJCMkEtRDE1Qi00NjRELTg1RDAtNlEBY0QyMjlCQ8oCoDgyQzIwMDE3LUVPADA0
NDWkAdQ1OS0xRUJEODk2MEI1pAFQQzEyQzJCAkBDNDVDSAPyBEItOTU5NC01NzJDN0VBMkVERTSoAFAxOTMzRq0I8wtFOTZCLTRGMDQtOUY5Mi0yMUY0RTVC
N0MwQioAsDJCOEMzM0NGLUZDkgMwMzRGSAPwAEUtMzZCRTlBODY2QUU5fVBST1AFPwIAzMcHAAAAAADzMgIAAAAGAAAAU291cmNlAbZLAAAtLSFub2NoZWNr
Cgpsb2NhbCBDb2xsZWN0aW9uU2VydmljZSA9IGdhbWU6R2V0EgAtKCIlACMiKT8AQ0h0dHAnAA85AAEHHwAFMwB/UGxheWVycy8AAQMbAAUrAC9SdZYACQYe
AAUxAPYTQ29tcG9uZW50cyA9IHNjcmlwdDpXYWl0Rm9yQ2hpbGQoIiIABTUAv0RlcGVuZGVuY2llNwAGCCQAJSIpPQH4CWVpdmVJbU92ZXJsYXkgPSByZXF1
aXJlKC8AC4EAe0RlYnVnIikWAAVFACQiKVsBb0NvbmZpZ1UAEwIsAAY8AH9GcnVzdHVtPQATAy0ABj4AYlV0aWxpdA4BD9IAEAUvAAZCAAXPAAQqAZdCb25l
Q2xhc3OTAAaLAQsNAUZCb25lTAB/Qm9uZVRyZT8AGzdUcmVDAO9Db2xsaWRlck9iamVjdIgAFgE3AE1zaW9urwEBGgAFUQAlIikSAv8AQWN0b3JSdW50aW1l
ID0gCAIIAyUABk0CMWZ1bogD8gYgQ29weVBhc3RlQXR0cmlidXRlcyi6ANIxOiBCYXNlUGFydCwgEwAWMhMA4ykKCWZvciBrLCB2IGluIABXMTpHZXRJAHQp
IGRvCgkJPQAXUx0A9A8oaywgdikKCWVuZAplbmQKCmV4cG9ydCB0eXBlIEmHATQgPSALAAFJARUuGgAOMAADLAAHKAAKJAAKRwEhID2OBAupARsuJgAPQgAD
X1RhYmxlQQANASUAIgoK0AAHtgPxG3sKCUJlZ2luOiAoVGV4dDogc3RyaW5nLCBCYWNrZ3JvdW5kQ29sb3I6IAcAgTM/LCBUZXh0DQAFFAD2ASkgLT4gKCks
CglFbmQ6ICgQAAJUAA9bAC8jCn28AORib29sID0gYm9vbGVhbmMD9QFTQl9JTkRFTlRfTE9HID0glwMZLhoAA7kFX1NCX1VOMAAHCBwAQgotLSAtBsxTQl9B
U1NFUlRfQ0JiAAUZAAZhAH9WRVJCT1NFkAABBxsADjAATFdBUk5fAAQxAElXQVJOkQAEGQBfRVJST1I2AAUBHQCBCgotLS0gQGOHBPYLU21hcnRCb25lCi0t
LSBSb290IGZvciBhbGwbAJMgb2JqZWN0cy46AGZ3aXRoaW4gAAE7AJJAcmVhZG9ubHkOAHNwcm9wIElEQwIBFADzBlVuaXF1ZSBJRCBvZiB0aGUgcm9vdFwA
D1oACgFMAARtA2JzIHRhYmyvAAHJAjEgb2avAPEGYm9uZSB0cmVlcyB1bmRlciB0aGlzZAAPXQAPClsDD2MABhNjQAXfcyBhc3NpZ25lZCB0b2gAGdVTaG91
bGREZXN0cm95uQKnLS0tIFRydWUgaRgBsWhhcyBubyBib25l1QASLGgA8gZpcyBhbHJlYWR5IGhhbmRsZWQgYnlOAQJuBQQHAwFtBGEgPSB7fQoLALEuX19p
bmRleCA9IBAADxUBClhyZXR1cuIBBpUFwmxhc3MubmV3KCkKCQ4D4XNlbGYgPSBzZXRtZXRhngGnKHsKCQlJRCA9IPoI9gk6R2VuZXJhdGVHVUlEKGZhbHNl
KSwKCQnaAYw9IHt9LAoJCY8BBBgACj8BIT0gRABSLAoJfSyYAEMpCgoJuwBCc2VsZr4Fwy0tIFByaXZhdGUgRlsGBP0AEnAYAAGeAg/WAgRVcGFyYW3qBQd8
AgcaABFPHwMBJQACSwACGwBxUGFyZW50SXUBaG51bWJlch4A+ABIZWlyYXJjaHlMZW5ndGgiAMI6OjpjYXV0aW9uIEMIABE6OgANxwDxCyBjYW4gY2hhbmdl
IHN5bnRheCBhdCBhbnkgeAfxD3dpdGhvdXQgd2FybmluZy4gT25seSB1c2UgdGhlc28C0nlvdSdyZSBwcmVwYXLPAjFmaXhDAPEDaXNzdWVzIHRoYXQgYXJp
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
RQATOtAPESm7BwTjBAkYCQR6BQpiByJpZp4LJyA8GhQHTSYBmBHxCiJEZWx0YVRpbWUgaXMgemVybyBvciBzdWIMAFIsIG5vdIwOQWluZy5+FwplAASQAA3c
EgMZAAL3AAseFQOgEgTpAA+GAQUJQwAELQAFwg4zLCBpwQ8N0QVTY2xpZW6gBQ+lAQrZUkFXX0NPTExJREVSU1wLA9gFAyIAX05UQUNUIQAH31BIWVNJQ0FM
X0JPTkVHAAYPHQAKn0FYSVNfTElNSWcACJ9ST09UX1BBUlRjAAZPRklMTNEAEgLzAJ9fSU5GTFVFTkO1AAcFKwBPQVdBSycAEJ9CUk9BRFBIQVMsAAfPQk9V
TkRJTkdfQk9YygAGj1JPVEFUSU9OFAENckFDQ0VMRVIsAElJTkZPUgBCRHJhd2gLvWRlYnVnIGdpem1vOxJBRHJhd00uMygKCfEBAiABIVM6TgAVLBcAAggC
ChYACf0BChsADhIAB+cBCisABdwBChcACtEBChwABKYABsYBDyAABAG7AQ8cAAQGsAEKIQAIpQEKGgALmgEKHQANjwECHwATClItD/wXEAToAwmWARQJmAEC
gQEB5BcBqgEJfQEGFwAKDgAHdQEGIwAFcQEGEwAI9AAGFgAL8AAGGQAN7AARCtsRASAGPAlpZl4EAykQD+MRIA0JFwWwAgEEAQokAhoseAAGHQIMGQABFgIM
FQAGDwIEpRILqhAPWwUVBMoxI0ltCgABAwkMkAMSb/AxDAYHQ0RyYXc3ABMoCAAWOkoAAgkHNG5vdIoa/wZERUJVR19PVkVSTEFZX0VOQUJMRUQUBwMC0gzy
CklOU1RBTkNFX0JBQ0tHUk9VTkRfQ09MT1LvCLFvcjMubmV3KDEuMAEA/QYsIDAuNDMxMzczLCAwLjcxMzcyNSlMAE9URVhURgACBHcdA9kfAXkCD3kAC4gw
LjQ4NjI3NXkABI0ACkgAD3UADiMKCUEBhS5CZWdpbihg3A8FXh9hIElEOiB7HhFfSUR9YCwfAQcHGwAGeQAWKWMAYVRleHQoYKwcEyCtHD86IHvDHAAyfWAp
JAMDyRwKwgFEVFJFRb8BDysIFAEMIwIVHQpMAJhNQVhfVFJFRVNoKAHXDw97AAafX09GRlNFVCArUgANRDw9IGmoAMEJCQlicmVhawoJCQkzAwMHAASoIw+c
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
LT6SAysDSgkPxAEBBOIBD7oBCwRZCQ/ZAQEElgMFlwMM0gAH0AACywkRKZMDD64DCAYbAA6vAwiwAxcJKgEEdgAUKI8FRyhuZXfPBAGgAg/AAAFUOnNldCg+
AASGAQU9ABQpCBABCAAPIQQnA1ciD4UBAgQUAwMICgHiBu5TaG93RGVtb1dpbmRvdxoJFWQcAAfjFAtcFRF3hAY0cyko9wAdKSMAOUFQSUAAAVNYAnMVQbZW
AAALChEgpBUOgwACdQ8RLh4ANCkNCqUVA3YAAWAFBscVApIFElX2CAdsAAWuAQHGEAJrAAXYFRIpzwYDUgBDLkd1aU8YD/lhAQYeABsiOAAGFxQPOAABBh4A
DDgAn1VzZXJJbnB1dHYACAwkAAxEAMRDb250ZXh0QWN0aW+wKQ+GAAEPKAABDEwAP1RleIsACQcfABEikAEIPAFSSUNPTlOrAwI5CPZNICBSSUdIVF9QT0lO
VElOR19UUklBTkdMRSA9ICJyYnhhc3NldDovL3RleHR1cmVzL0RldmVsb3BlckZyYW1ld29yay9idXR0b25fYXJyb3dfcmlnaHQucG5nIixkAE9ET1dOYwA3
TGRvd25iAJJNVUxUSVBMSUOhNE9TSUdOwgAF8gtBbmltYXRpb25FZGl0b3IvaWNvbl9jbG9zZVUA8wAgLS0gYmVzdCBhcHByb3gtAAGdEyFhICgA+QogWCB3
aGljaCByb2Jsb3ggc3VwcG9ydHMs6Sb2AHNjYWxlZCBhYm91dCAyeA4BckJPVFRPTV95AfIDQ09STkVSID0gIlx1ezI1RTJ9ggASdfg7IiB3+gP2DHJlc2l6
ZSBpY29uIGluIGJvdHRvbSByaWdodFkAr0NIRUNLX01BUkv8ABuCaGVja21hcmsAAQZQAFhBTFBIQbwxb1RFWFRVUhwCBpNtZXNoUGFydEbvEQJQAAXOAEFm
b3Iglg1yNCBhbHBoYWkAMn0NCgkAB+ADBKkcBxMAA/MDRDpHZXTKHALcFgnfAodTX1NUVURJTzwAJFJ1cQOjOklzU3R1ZGlvKBoEBHYEA/8SlHMuZ2V0VGlt
ZSAAAigSISB0EwCCIGFsd2F5cyCyBDJzIDDvKBRlMC2yIG9mIHBsdWdpbnOVAGUgICAgaWZcAAacAAJtBwIhAAICAAJUAJggb3MuY2xvY2uAAAJ0BwInAAIC
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
fwAiLS2jGGIgUHJvcHMUAHNpc0hvdmVyQiYIIAECIAABHwICia0PIQIACR4AFW31EAPSAAceAATaFBQ67gMFfQaPbGFzdFJpZ2hmAAxhRG91YmxlJwkPigAH
BkeLC6wAB8wAL2hlQgAIIVVuyS4NQAAEqQAC35QLXQAEHQBPQ2xvcx0ABm9TZWxlY3QfAAY/VW5zIQALBAwJD30ABQchBgsiAAahAAIDcgKCTQ9IAAWrVGV4
dGNoYW5nZUcABOYAi1Nob3J0Y3V0HwACIQAEYgIDXQISaFsCAzQGM0FQSRkCEmNRAg0YAAFsawPkAQ0dABZj3gENHAAJi40JHgACmAAD1gEJGgBFICAgIIqJ
DRoAAYqQL2F0GgAAL2RlHAAHE2OyCg5QAC91bhwABwT7AQ81AAAPGwAGAqx+DTIAEWOEAgkXAALqAAG0AB9lGQAAAoQEAxUCCSAAMSAgIIyMDxwAAQIeAAYv
BQUFCBImQgoOnggCJAZBQ2xhc90GAkEAp0dlbmVyYXRlOiCPHARQBgFNCAxEBgNyIA8xAAcF5QgC9iUPKQACRiwuLi4KCwWLBDFBcmdXBQbXAAIdAQViBQHm
ABNz7gAEmwYHaCMIPwUDGwABzwcMGAAEGDgZOhgIAk0BAW0AAj8ABB4BA0QADyMBBQHCAAEaDwFDsw8uABECMAABxwZfQWRkZWRdAAICfCYBJQAPkwEKASIA
A5gBD0sAHA/1CwECKQIDcxcG3AgzR3VpPkgBOQgDDAADUQQGW0gXOgwAAx0AQ1RleHQvABg6DQADHwBBVXNlcjgKBSQADBIAAykAxkNvbnRleHRBY3Rpb28A
DxYAAQVSAjJnZXQYBwIaCwJPAgNPAPQBZ2V0TW91c2VMb2NhdGlvbiUAAw8LBUQAZElDT05TOjID9AwgICAgUklHSFRfUE9JTlRJTkdfVFJJQU5HTEVCAhIs
3gGPICAgIERPV04pABL/BE1VTFRJUExJQ0FUSU9OX1NJR05PAAByQk9UVE9NX4AAb0NPUk5FUiYAAK9DSEVDS19NQVJLHQAA9QhBTFBIQV9CQUNLR1JPVU5E
X1RFWFRVUr0AViAgICAKaApRR3VpSW6ADgwXAfYTZmluZEJlc3RXaW5kb3dQb3NGb3JQb3B1cDogKHJlZlBvczQAA7QNBEMAYSBvdXRlcqwSCxMAJWF4EwAB
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
ATVVc2UqOw10QgLXSgaQMQNyDATTACFhch4eDIAnAUAWsmlzcGxheU9yZGVyzU4LoAARWl0RDRsAAj4AASQzB/45D2g6AAwjAGxNYXhEaXO7KAImAMRyYWdU
aHJlc2hvbGSHAAI4IQNASYV7fQ0KnAYAAM0OIXVynzMVCiEA8QUKCVZFUlNJT04gPSAiMC41LjIiLMFG8hVDb250cm9scyBpZiB3aGVuIGFuIG9iamVjdCBp
cyBvdXQgb2aJNwFSADIgZGnMO/UDIC8gZm92IGlmIGl0cyBib25lxnnDYmUgc2VudCBiYWNrRm+xaXIgcmVzdCBsb2NHAPISLgoJUkVTRVRfVFJBTlNGT1JN
X09OX1NLSVAgPSB0cnVlnQD4D1dvdWxkbid0IHJlY29tbWVuZCBlbmFibGluZywgY7oAFGUsZ6J3YWl0IGFmdGVyC30xY29sTwnzEyBzZXR1cC4KCVlJRUxE
X09OX0NPTExJREVSX0dBVEhFUiCwZwJ6ABJBR+syZm9yEUxVIHRvb2wQAfoOc3R1ZGlvCglBTExPV19MSVZFX0dBTUVfREVCVUdJAHZNYXhpbXVtOAHyAmZv
ciBmaWVsZCBvZiB2aWV36TlfcywgaWZ9AQJGdGhpcz8A/wdpdHMgc2tpcHBlZCByZWdhcmRsZXNzpQEE8gMuCglGQVJfUExBTkUgPSA1MDDeAMNGcmVxdWVu
Y3kgb2bPZ9V3ZSBkbyBmcnVzdHVtkwBGMSBiZTlqiWZyYW1lLCAyFQARb7B9AxsAGTMbADIzcmQZAAEaSzFzbyD5AfIBRlJVU1RVTV9GUkVRID0gMpMA+iVE
ZWJ1ZyBpbmZvIGluIG91dHB1dCwgY2FuIGxhZyB0aGUgZ2FtZS4KCUxPR19WRVJCT1NFagEJygIFEAIBFpMBoAIF80ISc+kC9AIuU3RvcCgpIGlzIGNhbGxl
ZJQC+QBCT05FX09OX0RFU1RST1mSAiFFbiU/Qm9yIGQfEQGbAPkVc3RhcnR1cCBwcmludAoJU1RBUlRVUF9QUklOVF9FTkFCTEVERwCCT3ZlcmxheSDFEFEs
IG5vdAx/knQgZm9yIGVuZMHt9wAKCURFQlVHX09WRVJMQVlLAJJmYWxzZSwgLS0RAwmSAAHHAwK2AiNpcyAAHGRLAERUUkVFkwAHRwBCdHJlZfICDzEAAVdf
SU5GT3YBCp4Az1RSRUVfT0JKRUNUUyUAC39OVU1FUklDJgAMoU9GRlNFVCA9IDDpANNob3cgb2Zmc2V0IGlu8HNXcm9vdHPuASxiZZUA0U1BWF9UUkVFUyA9
IDVIACEtMWUBbG5vIG1heC8AIUJPKgMMFwEzYm9uFwEBowIPNgABD68AEQFHAAFjAQahAg+zAAMxQk9OswABQlUPtAAQD5oBCwHSAg91AQ4BJgCfQ09OU1RS
QUlOwgEGAScAN1dFTNICCggCASEAQUZPUkPCAAFLAVQKfQrwASGaARsAFF++OQF6BTcwLjLPBgG6aASDb/MLew0KCURhbXBpbmcgPSAwLjEsDQoJU3RpZmby
VOEwLjIsDQoJSW5lcnRpYS8Cog0KCUVsYXN0aWOPO/MBMywNCglBbmNob3JEZXB0aCUABRUAM3NSb8RIAlgDARsAAiYsIWFpoEbBIlNwcmluZyIsDQoJBxcj
ID0WQp0zLnlBeGlzICrYAIIsDQoJR3JhdoQAEi0kOwYvACEyNecnUglXaW5kNHCBICJIeWJyaWRmAPQDTWF0Y2hXb3Jrc3BhY2VXaW5krwMDNABxSW5mbHVl
bosAARUBoVdpbmRTdHJlbmfiAAEWAQEUAEFwZWVkI7oDOgAF2zgHxQBSeEF4aXORAAKTPRJSEQERNk4BFUEBCBREAAj3AT0gNDUsDQoJVGhyb3R0bGUZAPMI
MTUsDQp9KQ0K9AwAAC0tIW5hdGl2ZQ1TlKFEZXBlbmRlbmNpcHYRc9oYEi6NCQQkAAWeFYhyZXF1aXJlKDUA8gA6V2FpdEZvckNoaWxkKCIsADQiKSk9AAKH
PQJeAA9AABAFLwABQwAERQABAi4FhlAFfFIBFwBRLkdldEOsC5VzKGNhbWVyYSyhBzQpDQo8lQIbAAIpACMgPQ8AEi4QADENCgkcMwMWADVQb3MiAAIhABQu
fkQFKgABrDWsVmVjLCB1cFZlYzAAE1IfAEN0b3IsVgADSgAiVXB7AgHWAgJ2AATGCTUyID26AGUgKiAwLjVvAIJmYXJQbGFuZTBG4zIgPSBtYXRoLnRhbigo
9gDyAi5GaWVsZE9mVmlldyArIDUpQwACBwCVMDE3NDUzKSAqYQANWwBhV2lkdGgyaQQKbAAkKiBiAHFWaWV3cG9yLQ1DLlggL9oAChgALVkpWwAC+wALJAEy
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
BgNAAATVBwLkBgZLCAxoDgOMAAHWAAQmAAgRAQJiTQbLZwKpAQUdCArmBgIdl1MKaWYgI1gABHMHNyA9PRwMAyISAXMFA8gjCwEHAmcAEi7ADAcNAAGFBAUS
AAZqBAoYAAI7BAGBHREJZQAIExBBID0gaQ9LAhoABb4CAbIABe0IASIAHQqnCDMJCQqTFAE+ACIgPfa9Ei6IuwQ6CgT2AB0sCAEBlAAC/gAEVgYiID1MABQu
EQABbwEPuAAHAi0AC/sAETO0RA8VAQFEDQoJCVoAAVABBioAA6EGCh8AAUoBB08ABX0ICUkAD74FDgONAAKKAQLFBQFGNEVhYmVsDwoEXwIE1QAPjAEHFQqn
CQG0AwohAwUcAA9ZBAADrBYBWgQK4gEIGwABVwAHzPkCVaw9bmlsKRkFswRBDQq8Ky0ZHy0BADYxIC0tyLEPAQACgUlyaXMgcnVuZLdhZWRpdG9y9r2fU21h
cnRCb25lNQABBFIAD6MANhEtUgAElxehRWRpdGluZ0JvbjNnK3t9GQCTQ29sbGlkZXJztRIB3gCSVGl0bGUsIERlHxqUaW9uLCBGbGFnPACRRGVidWdGbGFn
NgDyCw0KCXsgIkRyYXcgSW50ZXJuYWwgQm9uZSIsFgBScyBhIHOG2UF3aXRoy7bxA3NwZWNpZmllZCByYWRpdXMgbzO/cSBib25lIGHFCmcgd2hlcmU9AYFi
ZWxpZXZlc0EAASkAMWlzLmUAoVJBV19CT05FIiCp3gSOAG1QaHlzaWOOAKJ0aGUgYWN0dWFsbwACOPITc6FWAp/Cp2F4aXMgYXJyb3djAI9QSFlTSUNBTGwA
AZFSb290IFBhcnSRAAP2AMFib3VuZGluZyBib3gqEIFmaWxscyBpbsMAlnJvb3QgcGFydMUAm1JPT1RfUEFSVMoAFEJJADZCb3hhAAIxAQdjAAEdw+Fmb3Ig
ZnJ1c3R1bSBjdZAZBmEAy0JPVU5ESU5HX0JPWGQAAZpQakxpbWl0c2MAAQwBEWwZAAHPAkFlYWNoOgEGVwC7QVhJU19MSU1JVFNWAAWnmw9aAAEUch0AD14A
C49ST1RBVElPTmIAA3JBY2NlbGVyZgBLSW5mb74ACB8AAaAZJGhl/xwSZJrMAfASh2Rlcml2ZSBpjgFyQUNDRUxFUnwAS0lORk/cAAU8AwZyAAS30BVjVwMB
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
]==]

	local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local VALUE = {}
	for i = 1, 64 do
		VALUE[string.byte(ALPHABET, i)] = i - 1
	end

	local function decode64(text)
		text = string.gsub(text, "[^%w%+/]", "")
		local n = #text
		local rem = n % 4
		local out = buffer.create(n // 4 * 3 + (rem == 2 and 1 or rem == 3 and 2 or 0))
		local o = 0
		for i = 1, n - rem, 4 do
			local a, b, c, d = string.byte(text, i, i + 3)
			local v = VALUE[a] * 262144 + VALUE[b] * 4096 + VALUE[c] * 64 + VALUE[d]
			buffer.writeu8(out, o, v // 65536)
			buffer.writeu8(out, o + 1, v // 256 % 256)
			buffer.writeu8(out, o + 2, v % 256)
			o += 3
		end
		if rem >= 2 then
			local a, b, c = string.byte(text, n - rem + 1, n)
			local v = VALUE[a] * 262144 + VALUE[b] * 4096 + (c and VALUE[c] * 64 or 0)
			buffer.writeu8(out, o, v // 65536)
			if rem == 3 then
				buffer.writeu8(out, o + 1, v // 256 % 256)
			end
		end
		return out
	end

	-- the SmartBone ModuleScript in a .rbxm
	local function fromRbxm(buf)
		local ok, objects = pcall(function()
			return game:GetService("SerializationService"):DeserializeInstancesAsync(buf)
		end)
		if not ok then
			return nil, "could not read the .rbxm: " .. tostring(objects)
		end
		for _, o in ipairs(objects) do
			if isSmartBone(o) then
				return o
			end
			for _, d in ipairs(o:GetDescendants()) do
				if isSmartBone(d) then
					d.Parent = nil
					return d
				end
			end
		end
		return nil, "the .rbxm has no SmartBone 2 ModuleScript (Components + Dependencies.Runtime) in it"
	end

	-- GET with redirects followed (GitHub sends release files from another host)
	local function get(url)
		for _ = 1, 5 do
			local ok, res = pcall(HttpService.RequestAsync, HttpService, { Url = url, Method = "GET" })
			if not ok then
				return nil, tostring(res)
			end
			local headers = res.Headers or {}
			local location = headers.Location or headers.location
			if res.StatusCode >= 300 and res.StatusCode < 400 and location then
				url = location
			elseif not res.Success then
				return nil, string.format("%s: HTTP %d %s", url, res.StatusCode, tostring(res.StatusMessage))
			else
				return res.Body
			end
		end
		return nil, url .. ": too many redirects"
	end

	function SmartBoneSource.provided()
		local module, err = fromRbxm(decode64(PROVIDED_RBXM))
		return module, module and PROVIDED_VERSION or err
	end

	function SmartBoneSource.latest()
		local body, err = get("https://api.github.com/repos/" .. REPO .. "/releases/latest")
		if not body then
			return nil, "could not ask GitHub for the latest release (" .. err .. ")"
		end
		local ok, release = pcall(HttpService.JSONDecode, HttpService, body)
		if not ok or type(release) ~= "table" then
			return nil, "GitHub's answer was not a release"
		end
		local asset
		for _, a in ipairs(release.assets or {}) do
			if type(a.name) == "string" and string.match(a.name, "%.rbxm$") then
				asset = a
				break
			end
		end
		local tag = tostring(release.tag_name)
		if not asset then
			return nil, "release " .. tag .. " has no .rbxm file"
		end
		local data, err2 = get(asset.browser_download_url)
		if not data then
			return nil, "could not download " .. asset.name .. " (" .. err2 .. ")"
		end
		local module, err3 = fromRbxm(buffer.fromstring(data))
		return module, module and tag or (asset.name .. ": " .. err3)
	end

	SmartBoneSource.providedVersion = PROVIDED_VERSION
end

-- choice: "provided" (the copy that comes with this plugin), "github" (the latest release), or nil (the one in the
-- place: the selection, anywhere in the place, or the asset id). A provided/downloaded copy becomes
-- ReplicatedStorage.SmartBone; one already there goes to ServerStorage.
local function integrateSmartBone(choice)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local lines = {}
	local module, where
	if choice == "provided" or choice == "github" then
		local info
		if choice == "provided" then
			module, info = SmartBoneSource.provided()
		else
			module, info = SmartBoneSource.latest()
		end
		if not module then
			return nil, "SmartBone 2: " .. tostring(info)
		end
		local old = ReplicatedStorage:FindFirstChild("SmartBone")
		if old then
			old.Name = "SmartBone (replaced)"
			old.Parent = game:GetService("ServerStorage")
			table.insert(lines, "Moved the previous ReplicatedStorage.SmartBone to ServerStorage as \"SmartBone (replaced)\".")
		end
		module.Name = "SmartBone"
		module.Parent = ReplicatedStorage
		table.insert(lines, string.format("SmartBone 2 %s (%s) -> ReplicatedStorage.SmartBone.", info,
			choice == "provided" and "provided with the plugin" or "latest release on GitHub"))
	else
		module, where = findSmartBone()
		if not module then
			return nil, (where and ("SmartBone 2: " .. where .. ".\n") or "")
				.. "SmartBone 2 not found in the place. Click again and pick the provided copy or the latest release."
		end
	end
	if not module:IsDescendantOf(ReplicatedStorage) then
		-- clients require it, and a copy left in Workspace can be streamed or run twice
		local clash = ReplicatedStorage:FindFirstChild(module.Name)
		if clash and clash ~= module then
			return nil, string.format("ReplicatedStorage already has a %s named %s; rename or remove one, then click again.",
				clash.ClassName, module.Name)
		end
		module.Parent = ReplicatedStorage
		table.insert(lines, "SmartBone 2 from " .. where .. " -> ReplicatedStorage." .. module.Name .. ".")
	elseif where then
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
	if child:IsA("Model") and parseName(child.Name) then
		stampIdentity(child) -- the Uma id travels with the rig from now on, whatever it gets renamed to
	end
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

label("SmartBone 2 (hair, tail, skirt physics): Integrate asks whether to use the copy provided with this plugin (" .. SmartBoneSource.providedVersion .. ") or the latest release on GitHub, or to keep one already in the place (selected in the Explorer, anywhere in the place, or the asset id below). Rigs get the '" .. UMA_TAG .. "' tag; selected rigs, else all Uma rigs.")
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
do -- (its own scope: the main chunk is near Luau's limit of 200 locals)
	local choiceBox, choiceText, keepButton
	local function run(choice)
		choiceBox.Visible = false
		status.Text = choice == "github" and "Downloading the latest SmartBone 2 release from GitHub..." or "Integrating SmartBone 2..."
		local msg, err
		record("Uma2Roblox: integrate SmartBone 2", function()
			msg, err = integrateSmartBone(choice)
		end)
		status.Text = msg or err or "SmartBone 2 integration failed (see Output)."
	end
	-- a SmartBone already in the place, without inserting the asset (the "keep" choice)
	local function inPlace()
		for _, inst in ipairs(Selection:Get()) do
			local m = inst
			while m and not isSmartBone(m) do
				m = m.Parent ~= game and m.Parent or nil
			end
			if m then
				return m:GetFullName()
			end
		end
		for _, root in ipairs({ game:GetService("ReplicatedStorage"), workspace, game:GetService("ServerStorage"),
			game:GetService("ServerScriptService"), game:GetService("StarterPlayer"), game:GetService("ReplicatedFirst"),
			game:GetService("Lighting") }) do
			for _, d in ipairs(root:GetDescendants()) do
				if isSmartBone(d) then
					return d:GetFullName()
				end
			end
		end
		local id = tonumber(cfg.smartBoneAssetId)
		return id and id > 0 and ("asset " .. id) or nil
	end
	button("Integrate SmartBone 2 into this place", function()
		local found = inPlace()
		choiceText.Text = "Use the SmartBone 2 provided with this plugin (" .. SmartBoneSource.providedVersion
			.. "), or download the latest release from GitHub?"
			.. (found and ("\nThis place already has one: " .. found .. ".") or "")
		keepButton.Text = found and ("Keep " .. found) or ""
		keepButton.Visible = found ~= nil
		choiceBox.Visible = true
	end)
	choiceBox = Instance.new("Frame")
	choiceBox.Size = UDim2.new(1, 0, 0, 0)
	choiceBox.AutomaticSize = Enum.AutomaticSize.Y
	choiceBox.BackgroundColor3 = theme:GetColor(Enum.StudioStyleGuideColor.InputFieldBackground)
	choiceBox.BorderSizePixel = 0
	choiceBox.Visible = false
	choiceBox.LayoutOrder = nextOrder()
	choiceBox.Parent = frame
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = choiceBox
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight, pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6), UDim.new(0, 6)
	pad.Parent = choiceBox
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = choiceBox
	choiceText = Instance.new("TextLabel")
	choiceText.Size = UDim2.new(1, 0, 0, 0)
	choiceText.AutomaticSize = Enum.AutomaticSize.Y
	choiceText.BackgroundTransparency = 1
	choiceText.TextWrapped = true
	choiceText.TextXAlignment = Enum.TextXAlignment.Left
	choiceText.Font = Enum.Font.SourceSansSemibold
	choiceText.TextSize = 15
	choiceText.TextColor3 = theme:GetColor(Enum.StudioStyleGuideColor.MainText)
	choiceText.LayoutOrder = 1
	choiceText.Parent = choiceBox
	local function choice(text, order, main, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, 0, 0, 28)
		b.BackgroundColor3 = theme:GetColor(main and Enum.StudioStyleGuideColor.DialogMainButton or Enum.StudioStyleGuideColor.Button)
		b.TextColor3 = theme:GetColor(main and Enum.StudioStyleGuideColor.DialogMainButtonText or Enum.StudioStyleGuideColor.ButtonText)
		b.Font = Enum.Font.SourceSansBold
		b.TextSize = 15
		b.TextTruncate = Enum.TextTruncate.AtEnd
		b.Text = text
		b.LayoutOrder = order
		b.Parent = choiceBox
		b.MouseButton1Click:Connect(onClick)
		return b
	end
	choice("Use the provided SmartBone 2 (" .. SmartBoneSource.providedVersion .. ")", 2, true, function()
		run("provided")
	end)
	choice("Download the latest release from GitHub", 3, false, function()
		run("github")
	end)
	keepButton = choice("", 4, false, function()
		run(nil)
	end)
	choice("Cancel", 5, false, function()
		choiceBox.Visible = false
	end)
end

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

---------------------------------------------------------------- UmaAnimateHandler
-- Replaces the place's Animate script for Uma rigs. ReplicatedStorage.UmaAnimateHandler (a ModuleScript), started by
-- ServerScriptService.UmaAnimateCaller, finds every Uma rig added anywhere in Workspace (a Model with UmaCharaId or a
-- UmaAnimate folder), checks its owner (Players:GetPlayerFromCharacter) and copies one of its two scripts into it:
--   a player's character  UmaAnimateClient (a LocalScript: runs on that player's client, so it replicates)
--   any other rig (NPC)   UmaAnimateServer (a Script: runs on the server)
-- Its children:
--   UmaAnimateClient, UmaAnimateServer: those two scripts (inert here, in ReplicatedStorage)
--   UmaRagdoll (ModuleScript) + UmaRagdollClient (Script, RunContext Client: runs on every client): the ragdoll,
--           switched by the rig's UmaRagdoll attribute
--   _idle, _walk (and optionally _run, _jump, _fall, _climb, _sit, _swim): the universal base animations, one or more
--           Animations each (several = picked at random by a Weight NumberValue/attribute). A rig's own UmaAnimate
--           set of the same name (its idle) wins when uploaded. These are the user's own uploads.
--   any other Folder: an /e extension. /e Dance = a random entry of folder "Dance", /e Dance3 = its entry named
--           "Dance3" or "3" (else the 3rd one). An entry is an Animation (looped) or a Folder/StringValue with
--           "Start" (played once) and/or "Loop" (then held until the player moves).
do -- (its own scope: the main chunk is near Luau's limit of 200 locals)
local HANDLER_NAME = "UmaAnimateHandler"
local HANDLER_CALLER = "UmaAnimateCaller"
local HANDLER_SERVER = "UmaAnimateServer"
local HANDLER_CLIENT = "UmaAnimateClient"
local OLD_ANIMATE_BACKUP = "Animate (old, replaced by UmaAnimateHandler)"

local HANDLER_SOURCE = [===[
-- UmaAnimateHandler (Uma2Roblox): animates every Uma rig in Workspace, at any depth.
--
-- ServerScriptService.UmaAnimateCaller starts it on the server. Every Uma rig added to Workspace then gets a copy of
-- one of the two scripts in this module, by its owner (Players:GetPlayerFromCharacter):
--   a player's character  UmaAnimateClient (LocalScript): animated by that player's client, so it replicates
--   any other Uma rig     UmaAnimateServer (Script): animated by the server (NPCs)
-- A rig that becomes a player's character later swaps its script.
--
-- A Uma rig is a Model with a UmaCharaId attribute or a UmaAnimate folder, and a Humanoid or AnimationController.
-- Set the rig's UmaAnimateDisabled attribute to true to leave it alone. Its Animate script, if any, is disabled.
--
-- BASE ANIMATIONS: the folders starting with "_" in this module. Put your OWN uploaded Animations in them (an
-- Animation with its AnimationId set; an empty AnimationId is skipped):
--   _walk  moving: needed (a warning in Output while it is empty)
--   _idle  standing: optional; each rig's own uploaded UmaAnimate.idle is used first (a warning for a rig without)
--   optional: _run (from RunSpeed studs/s, an attribute of this module, default 18), _jump, _fall, _climb, _sit, _swim
-- Missing ones fall back: run -> walk -> idle, jump/fall/sit -> idle, climb/swim -> walk.
-- Several Animations in one = picked at random by their Weight (NumberValue child or attribute, default 1).
-- SpeedAt1x attribute (on the folder or the Animation): the speed in studs/s at which the clip plays at 1x; the
-- clip then speeds up and slows down with the rig. A rig's own UmaAnimate.<name> set (its idle, from the
-- Uma2Roblox plugin) wins over the universal one once it is uploaded.
--
-- /e COMMANDS: every other Folder in this module (universal), and every Folder in a rig's UmaAnimate (that rig's
-- own, tried first; the plugin makes its Emote folder).
--   /e Dance      a random entry of the folder "Dance"
--   /e Dance3     its entry named "Dance3" or "3", else its 3rd entry
--   /e Emote, /e Emote2   the rig's own emotes (UmaAnimate.Emote; "Emotes" from older plugins works too)
-- An entry is an Animation (looped until the player moves), or a Folder/StringValue holding "Start" (played once)
-- and/or "Loop" (then looped). Anything not found goes to the default Animate / catalog emotes.
--
-- RAGDOLL (UmaRagdoll, in this module): rig:SetAttribute("UmaRagdoll", true) on the server ragdolls the rig, false
-- stands it up; a rig also ragdolls when it dies (this module's RagdollOnDeath attribute, default true).
--
-- SCRIPTING:
--   Handler.Play(rig, "Dance3")   plays an emote on a rig this side animates (server: NPCs; client: own character)
--   Handler.IsAnimating(rig)      whether this side animates it
--   Handler.Stop(rig)             back to idle
--   rig:SetAttribute("UmaEmote", "Umapyoi2")   the same from anywhere (server: also for players' characters)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Handler = {}

local RIG_FOLDER = "UmaAnimate"
local RIG_EMOTES = "Emote"
local FALLBACK = { run = "walk", walk = "idle", jump = "idle", fall = "idle", sit = "idle", climb = "walk", swim = "walk" }
local FADE = 0.1
local FALL_FADE = 0.3
local JUMP_TIME = 0.3

local IS_SERVER = RunService:IsServer()
local started = false
local controllers = {} -- rig -> controller (or true while it starts)
local waiting = {} -- rig -> connection, rigs without a Humanoid/AnimationController yet
local warned = {}

local function note(key, msg)
	if not warned[key] then
		warned[key] = true
		warn("[UmaAnimateHandler] " .. msg)
	end
end

local function playable(a)
	return a ~= nil and a:IsA("Animation") and a.AnimationId ~= ""
end

-- children in natural order: Dance2 before Dance10
local function sortedChildren(inst)
	local list = inst:GetChildren()
	table.sort(list, function(a, b)
		local pa, na = string.match(string.lower(a.Name), "^(.-)(%d*)$")
		local pb, nb = string.match(string.lower(b.Name), "^(.-)(%d*)$")
		if pa ~= pb then
			return pa < pb
		end
		return (tonumber(na) or -1) < (tonumber(nb) or -1)
	end)
	return list
end

local function weightOf(a)
	local w = a:FindFirstChild("Weight")
	if w and w:IsA("ValueBase") and tonumber(w.Value) then
		return tonumber(w.Value)
	end
	return tonumber(a:GetAttribute("Weight")) or 1
end

-- the playable Animations of a set, with their weights
local function animsIn(set)
	local list, total = {}, 0
	if set then
		for _, a in ipairs(sortedChildren(set)) do
			local w = playable(a) and weightOf(a) or 0
			if w > 0 then
				table.insert(list, { anim = a, weight = w })
				total += w
			end
		end
	end
	return list, total
end

local function isExtension(f)
	return f:IsA("Folder") and string.sub(f.Name, 1, 1) ~= "_"
end

---------------------------------------------------------------- emotes

local function entryFrom(group, inst)
	local e = { name = string.lower(inst.Name) }
	e.key = "uma:" .. group .. ":" .. e.name
	if playable(inst) then
		e.loop = inst
		return e
	end
	local start, loop = inst:FindFirstChild("Start"), inst:FindFirstChild("Loop")
	e.start = playable(start) and start or nil
	e.loop = playable(loop) and loop or nil
	if not (e.start or e.loop) then -- a set with one Animation of any name
		for _, a in ipairs(sortedChildren(inst)) do
			if playable(a) then
				e.loop = a
				break
			end
		end
	end
	return (e.start or e.loop) and e or nil
end

-- lname: the /e name, lower case; prefix: the container's name, lower case
local function findIn(container, prefix, lname, pattern)
	local list = {}
	for _, inst in ipairs(sortedChildren(container)) do
		if not pattern or string.match(inst.Name, pattern) then
			local e = entryFrom(prefix, inst)
			if e then
				table.insert(list, e)
			end
		end
	end
	if #list == 0 then
		return nil
	elseif lname == prefix then
		return list[math.random(1, #list)]
	end
	local rest = string.sub(lname, 1, #prefix) == prefix and string.sub(lname, #prefix + 1) or nil
	for _, e in ipairs(list) do
		if e.name == lname or e.name == rest then
			return e
		end
	end
	local n = rest and tonumber(rest)
	return n and list[n] or nil
end

-- the command folders in parent, with their /e name ("Emotes", from older plugins, is /e Emote)
local function commandFolders(parent)
	local list = {}
	for _, f in ipairs(parent and parent:GetChildren() or {}) do
		if isExtension(f) then
			local cmd = string.lower(f.Name)
			table.insert(list, { folder = f, cmd = cmd == "emotes" and RIG_EMOTES:lower() or cmd })
		end
	end
	return list
end

local function findInFolders(list, lname)
	-- the longest folder name the command starts with
	local best
	for _, c in ipairs(list) do
		if string.sub(lname, 1, #c.cmd) == c.cmd and (not best or #c.cmd > #best.cmd) then
			best = c
		end
	end
	local e = best and findIn(best.folder, best.cmd, lname)
	if e then
		return e
	end
	-- an entry of any of them by its own name
	for _, c in ipairs(list) do
		for _, child in ipairs(c.folder:GetChildren()) do
			if string.lower(child.Name) == lname then
				e = entryFrom(c.cmd, child)
				if e then
					return e
				end
			end
		end
	end
	return nil
end

-- the rig's own command folders first (UmaAnimate.Emote: /e Emote, /e Emote3), then the universal ones
local function findEmote(rig, name)
	local lname = string.lower(name)
	local own = rig:FindFirstChild(RIG_FOLDER)
	local e = findInFolders(commandFolders(own), lname)
	if not e and own and string.sub(lname, 1, 5) == "emote" then -- rigs from older plugins: Emote<n> next to idle
		e = findIn(own, "emote", lname, "^[Ee]mote%d+$")
	end
	return e or findInFolders(commandFolders(script), lname)
end

---------------------------------------------------------------- one rig

local Controller = {}
Controller.__index = Controller

local function animatorOf(rig)
	local hum = rig:FindFirstChildOfClass("Humanoid")
	local holder = hum or rig:FindFirstChildOfClass("AnimationController")
	if not holder then
		return nil
	end
	local animator = holder:FindFirstChildOfClass("Animator")
	if not animator then
		if IS_SERVER then
			animator = Instance.new("Animator")
			animator.Parent = holder
		else
			animator = holder:WaitForChild("Animator", 5) -- made by the server; one made here would not replicate
		end
	end
	return animator, hum
end

-- the rig's own set, else the universal one, else the fallbacks: resolved name, animations, total weight, set
function Controller:resolve(name)
	local seen = {}
	while name and not seen[name] do
		seen[name] = true
		local own = self.rig:FindFirstChild(RIG_FOLDER)
		local sets = { (own and own:FindFirstChild(name)) or false, script:FindFirstChild("_" .. name) or false }
		for i = 1, 2 do
			local list, total = animsIn(sets[i] or nil)
			if total > 0 then
				return name, list, total, sets[i]
			end
		end
		name = FALLBACK[name]
	end
	return nil
end

function Controller:stopCurrent(fade)
	fade = fade or FADE
	self.token = nil
	self.emoting = false
	if self.trackConn then
		self.trackConn:Disconnect()
		self.trackConn = nil
	end
	local track = self.track
	if track then
		track:Stop(fade)
		task.delay(fade + 0.1, function()
			track:Destroy()
		end)
	end
	self.track, self.anim, self.current = nil, nil, nil
end

function Controller:load(anim, looped, fade)
	local track = self.animator:LoadAnimation(anim)
	self.owned[track] = true
	track.Priority = Enum.AnimationPriority.Core
	track.Looped = looped
	track:Play(fade)
	self.track, self.anim = track, anim
	return track
end

-- plays a base set (idle, walk, ...); nothing changes when one of its animations is already playing
function Controller:play(name, fade, reroll)
	if self.ragdoll then
		return
	end
	local resolved, list, total, set = self:resolve(name)
	if not resolved then
		if self.track and not self.emoting then
			self:stopCurrent(fade)
		end
		return
	end
	if self.track and not reroll then
		for _, e in ipairs(list) do
			if e.anim == self.anim then
				self.current = name
				return
			end
		end
	end
	local roll, pick = math.random() * total, list[#list].anim
	for _, e in ipairs(list) do
		roll -= e.weight
		if roll <= 0 then
			pick = e.anim
			break
		end
	end
	if reroll and pick == self.anim and self.track then
		return
	end
	self:stopCurrent(fade)
	local track = self:load(pick, resolved ~= "jump", fade)
	self.current = name
	self.speedAt1x = tonumber(pick:GetAttribute("SpeedAt1x")) or tonumber(set:GetAttribute("SpeedAt1x"))
	if #list > 1 and resolved == "idle" then -- several idles: a new pick every cycle
		self.trackConn = track.DidLoop:Connect(function()
			if self.track == track then
				self:play(name, FADE, true)
			end
		end)
	end
end

function Controller:fitSpeed(speed)
	if self.track and self.speedAt1x and self.speedAt1x > 0 and not self.emoting then
		self.track:AdjustSpeed(speed / self.speedAt1x)
	end
end

function Controller:emote(name)
	if self.ragdoll or self.pose == "Dead" or (self.humanoid and self.pose ~= "Standing") then
		return false
	end
	local e = findEmote(self.rig, name)
	if not e then
		return false
	end
	self:stopCurrent(FADE)
	self.emoting, self.current = true, e.key
	local token = {}
	self.token = token
	if not e.start then
		self:load(e.loop, true, FADE)
		return true
	end
	local start = self:load(e.start, false, FADE)
	self.trackConn = start.Stopped:Connect(function()
		if self.token ~= token then
			return -- interrupted
		end
		self.trackConn:Disconnect()
		self.trackConn = nil
		if e.loop then
			self:load(e.loop, true, 0) -- Start ends on the pose Loop begins with
		else
			self.track, self.anim, self.current, self.emoting, self.token = nil, nil, nil, false, nil
			self:play("idle", FADE)
		end
		task.delay(0.1, function()
			start:Destroy()
		end)
	end)
	return true
end

function Controller:scale()
	local ok, s = pcall(self.rig.GetScale, self.rig)
	return ok and s or 1
end

function Controller:onRunning(speed)
	speed /= self:scale()
	if speed > 0.01 then
		local runAt = tonumber(script:GetAttribute("RunSpeed")) or 18
		self.moveSet = (speed >= runAt and self:resolve("run") == "run") and "run" or "walk"
		self:play(self.moveSet, FADE)
		self:fitSpeed(speed)
		self.pose = "Running"
	else
		if not self.emoting then
			self:play("idle", FADE)
		end
		self.pose = "Standing"
	end
end

function Controller:step(dt)
	if self.ragdoll then
		return
	end
	if self.jumpTime > 0 then
		self.jumpTime -= dt
	end
	local pose = self.pose
	if pose == "FreeFall" and self.jumpTime <= 0 then
		self:play("fall", FALL_FADE)
	elseif pose == "Seated" then
		self:play("sit", 0.5)
	elseif pose == "Running" then
		self:play(self.moveSet or "walk", FADE)
	elseif pose == "Dead" or pose == "GettingUp" or pose == "FallingDown" or pose == "PlatformStanding" then
		if self.track then
			self:stopCurrent()
		end
	end
end

-- stops the tracks this controller did not start (another Animate's, from before it was disabled)
function Controller:sweep()
	if not self.alive then
		return
	end
	for _, t in ipairs(self.animator:GetPlayingAnimationTracks()) do
		if not self.owned[t] then
			t:Stop(0)
		end
	end
end

function Controller:silence(inst)
	if inst.Name == "Animate" and inst:IsA("BaseScript") and inst.Enabled then
		inst.Enabled = false -- the default (or an old) Animate would fight over the same tracks
		task.delay(0.2, self.sweep, self)
	end
end

-- UmaRagdoll: no animation while the rig lies; the server builds the ragdoll (UmaRagdoll module)
function Controller:setRagdoll(on)
	if on == (self.ragdoll == true) then
		return
	end
	local hum = self.humanoid
	if on then
		self:stopCurrent(0.1)
		self.ragdoll = true
		for _, t in ipairs(self.animator:GetPlayingAnimationTracks()) do
			t:Stop(0.1)
		end
		if hum and hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.Physics)
		end
	else
		self.ragdoll = false
		if hum and hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		self.pose = "Standing"
		self:play("idle", FADE)
	end
end

function Controller.new(rig)
	local animator, hum = animatorOf(rig)
	if not animator then
		return nil
	end
	local self = setmetatable({ rig = rig, animator = animator, humanoid = hum, conns = {}, pose = "Standing",
		jumpTime = 0, alive = true, owned = setmetatable({}, { __mode = "k" }) }, Controller)
	local function on(signal, fn)
		table.insert(self.conns, signal:Connect(fn))
	end
	for _, c in ipairs(rig:GetChildren()) do
		self:silence(c)
	end
	on(rig.ChildAdded, function(c)
		self:silence(c)
	end)
	self:sweep()
	task.delay(1, self.sweep, self)
	if hum then
		on(hum.Running, function(speed)
			self:onRunning(speed)
		end)
		on(hum.Jumping, function(active)
			if active then
				self:play("jump", FADE)
				self.jumpTime, self.pose = JUMP_TIME, "Jumping"
			end
		end)
		on(hum.FreeFalling, function(active)
			if active then
				if self.jumpTime <= 0 then
					self:play("fall", FALL_FADE)
				end
				self.pose = "FreeFall"
			end
		end)
		on(hum.Climbing, function(speed)
			self:play("climb", FADE)
			self:fitSpeed(speed / self:scale())
			self.pose = "Climbing"
		end)
		on(hum.Swimming, function(speed)
			self:play(speed > 1 and "swim" or "idle", FADE)
			self.pose = speed > 1 and "Running" or "Standing"
			self.moveSet = "swim"
		end)
		on(hum.Seated, function(active)
			self.pose = active and "Seated" or "Standing"
		end)
		on(hum.GettingUp, function()
			self.pose = "GettingUp"
		end)
		on(hum.FallingDown, function()
			self.pose = "FallingDown"
		end)
		on(hum.PlatformStanding, function()
			self.pose = "PlatformStanding"
		end)
		on(hum.Died, function()
			self.pose = "Dead"
			self:stopCurrent()
		end)
	end
	on(rig:GetAttributeChangedSignal("UmaEmote"), function()
		local name = rig:GetAttribute("UmaEmote")
		if type(name) == "string" and name ~= "" then
			self:emote(name)
		end
	end)
	on(rig:GetAttributeChangedSignal("UmaRagdoll"), function()
		self:setRagdoll(rig:GetAttribute("UmaRagdoll") == true)
	end)
	self:play("idle", FADE)
	if rig:GetAttribute("UmaRagdoll") == true then
		self:setRagdoll(true)
	end
	task.spawn(function()
		while self.alive do
			self:step(task.wait(0.1))
		end
	end)
	return self
end

function Controller:destroy()
	self.alive = false
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self:stopCurrent(0)
end

---------------------------------------------------------------- per-rig scripts

-- templates (children of this module, inert in ReplicatedStorage), copied into each rig by the server
local CLIENT_SCRIPT = "UmaAnimateClient" -- a player's character: runs on that player's client, so it replicates
local SERVER_SCRIPT = "UmaAnimateServer" -- any other rig (NPC): runs on the server
local COPY_MARK = "UmaAnimateCopy"

local function isUmaModel(inst)
	return inst:IsA("Model") and (inst:GetAttribute("UmaCharaId") ~= nil or inst:FindFirstChild(RIG_FOLDER) ~= nil)
end

local function drives(rig)
	return rig:FindFirstChildOfClass("Humanoid") or rig:FindFirstChildOfClass("AnimationController")
end

-- a rig without an uploaded idle of its own (UmaAnimate.idle): once per character/outfit
local function checkOwnIdle(rig)
	local own = rig:FindFirstChild(RIG_FOLDER)
	local _, total = animsIn(own and own:FindFirstChild("idle"))
	if total > 0 then
		return
	end
	local _, universal = animsIn(script:FindFirstChild("_idle"))
	local id = rig:GetAttribute("UmaSource") or rig.Name
	note("idle:" .. tostring(id), string.format("%s (%s) has no idle animation of its own (UmaAnimate.idle with an "
		.. "uploaded AnimationId); it %s. Import and upload its animations with the Uma2Roblox plugin.",
		rig:GetFullName(), tostring(id), universal > 0 and ("uses " .. script.Name .. "._idle") or "stands in rest pose"))
end

-- server: gives the rig the script for its owner (Players:GetPlayerFromCharacter), and takes the other one away
-- server: the UmaRagdoll attribute builds / removes the ragdoll; a death ragdolls (RagdollOnDeath, default on)
local ragdollHooked = setmetatable({}, { __mode = "k" })
local function hookRagdoll(rig)
	if ragdollHooked[rig] then
		return
	end
	local module = script:FindFirstChild("UmaRagdoll")
	local ok, Ragdoll = pcall(require, module)
	if not (ok and type(Ragdoll) == "table") then
		note("ragdoll", script:GetFullName() .. " has no UmaRagdoll module; click 'Add UmaAnimateHandler to this place' in the Uma2Roblox plugin again.")
		return
	end
	ragdollHooked[rig] = true
	local function apply()
		local fine, err = pcall(rig:GetAttribute("UmaRagdoll") == true and Ragdoll.Build or Ragdoll.Remove, rig)
		if not fine then
			warn("[UmaAnimateHandler] ragdoll " .. rig:GetFullName() .. ": " .. tostring(err))
		end
	end
	rig:GetAttributeChangedSignal("UmaRagdoll"):Connect(apply)
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Connect(function()
			if script:GetAttribute("RagdollOnDeath") ~= false then
				rig:SetAttribute("UmaRagdoll", true)
			end
		end)
	end
	if rig:GetAttribute("UmaRagdoll") == true then
		apply()
	end
end

local assign
assign = function(rig)
	if not rig:IsDescendantOf(workspace) then
		return
	end
	local want
	if not rig:GetAttribute("UmaAnimateDisabled") then
		want = Players:GetPlayerFromCharacter(rig) and CLIENT_SCRIPT or SERVER_SCRIPT
	end
	for _, name in ipairs({ CLIENT_SCRIPT, SERVER_SCRIPT }) do
		local s = rig:FindFirstChild(name)
		if s and name ~= want and s:GetAttribute(COPY_MARK) then
			s:Destroy()
			local c = controllers[rig]
			if name == SERVER_SCRIPT and type(c) == "table" then -- the script's connections went with it; stop its tracks
				controllers[rig] = nil
				c:destroy()
			end
		end
	end
	if want then
		checkOwnIdle(rig)
		hookRagdoll(rig)
	end
	if not want or rig:FindFirstChild(want) then
		return
	end
	if not drives(rig) then
		if not waiting[rig] then -- e.g. a Humanoid added by a script after the rig: try again then
			waiting[rig] = rig.ChildAdded:Connect(function(child)
				if child:IsA("Humanoid") or child:IsA("AnimationController") then
					waiting[rig]:Disconnect()
					waiting[rig] = nil
					task.defer(assign, rig)
				end
			end)
		end
		return
	end
	local template = script:FindFirstChild(want)
	if not template then
		note("template" .. want, script:GetFullName() .. " has no " .. want .. " script; click 'Add UmaAnimateHandler to "
			.. "this place' in the Uma2Roblox plugin again.")
		return
	end
	local copy = template:Clone()
	copy:SetAttribute(COPY_MARK, true)
	copy.Parent = rig
end

local function checkBase()
	local _, total = animsIn(script:FindFirstChild("_walk"))
	if total == 0 then
		note("base_walk", script:GetFullName() .. "._walk has no uploaded Animation: put your own walk Animation (its "
			.. "AnimationId set) in it; moving rigs stand still meanwhile.")
	end
end

---------------------------------------------------------------- /e (client)

-- /e and /emote: Uma emotes and extensions, then the default Animate's (wave, dance...) and catalog emotes
local function chatEmote(name)
	local ch = Players.LocalPlayer.Character
	if not ch or Handler.Play(ch, name) then
		return
	end
	local animate = ch:FindFirstChild("Animate")
	local bindable = animate and animate:IsA("LocalScript") and animate.Enabled and animate:FindFirstChild("PlayEmote")
	local ok, played = false, false
	if bindable and bindable:IsA("BindableFunction") then
		ok, played = pcall(bindable.Invoke, bindable, name)
	end
	local hum = ch:FindFirstChildOfClass("Humanoid")
	if not (ok and played) and hum then
		pcall(hum.PlayEmote, hum, name)
	end
end

-- connected again by each character's script (a destroyed script's connections go with it), never twice
local chatConn
local function hookChat()
	if chatConn then
		chatConn:Disconnect()
		chatConn = nil
	end
	local TextChatService = game:GetService("TextChatService")
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		chatConn = Players.LocalPlayer.Chatted:Connect(function(msg)
			local name = string.match(msg, "^/e%s+(%S+)") or string.match(msg, "^/emote%s+(%S+)")
			if name then
				chatEmote(name)
			end
		end)
		return
	end
	local commands = TextChatService:WaitForChild("TextChatCommands", 10)
	if not commands then
		return
	end
	local cmd = commands:FindFirstChild("UmaEmoteCommand")
	if not cmd then
		local builtin = commands:WaitForChild("RBXEmoteCommand", 5)
		if builtin then
			builtin.Enabled = false -- it only knows default and catalog emotes; chatEmote falls back to them
		end
		cmd = Instance.new("TextChatCommand")
		cmd.Name = "UmaEmoteCommand"
		cmd.PrimaryAlias = "/e"
		cmd.SecondaryAlias = "/emote"
		cmd.Parent = commands
	end
	chatConn = cmd.Triggered:Connect(function(_, text)
		local name = string.match(text, "^%S+%s+(%S+)")
		if name then
			chatEmote(name)
		end
	end)
end

---------------------------------------------------------------- API

-- The server caller (ServerScriptService.UmaAnimateCaller): finds Uma rigs added anywhere in Workspace and gives
-- each the script for its owner.
function Handler.StartServer()
	assert(IS_SERVER, "UmaAnimateHandler.StartServer runs on the server")
	if started then
		return
	end
	started = true
	checkBase()
	local function consider(inst)
		if isUmaModel(inst) then
			task.defer(assign, inst) -- after its spawn has set Player.Character
		end
	end
	workspace.DescendantAdded:Connect(consider)
	workspace.DescendantRemoving:Connect(function(inst)
		if waiting[inst] then
			waiting[inst]:Disconnect()
			waiting[inst] = nil
		end
	end)
	for _, inst in ipairs(workspace:GetDescendants()) do
		consider(inst)
	end
	local function hook(player) -- a rig taken as a character changes sides
		player.CharacterAdded:Connect(function(ch)
			task.defer(assign, ch)
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in ipairs(Players:GetPlayers()) do
		hook(p)
	end
end

-- The copied scripts: animates the rig on this side until the script or the rig leaves.
function Handler.Animate(rig, runner)
	if typeof(rig) ~= "Instance" or not rig:IsA("Model") or controllers[rig] then
		return
	end
	if not IS_SERVER and rig ~= Players.LocalPlayer.Character then
		return -- only the owner animates a character
	end
	controllers[rig] = true
	local ok, ctl = pcall(Controller.new, rig)
	if not ok then
		warn("[UmaAnimateHandler] " .. rig:GetFullName() .. ": " .. tostring(ctl))
	end
	if not (ok and ctl) or controllers[rig] ~= true then
		if ok and ctl then
			ctl:destroy()
		end
		if controllers[rig] == true then
			controllers[rig] = nil
		end
		return
	end
	controllers[rig] = ctl
	local conns = {}
	local function check()
		if runner and runner.Parent == rig and rig:IsDescendantOf(workspace) then
			return
		end
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		if controllers[rig] == ctl then
			controllers[rig] = nil
		end
		ctl:destroy()
	end
	if runner then
		table.insert(conns, runner.AncestryChanged:Connect(check))
	end
	table.insert(conns, rig.AncestryChanged:Connect(check))
	if not IS_SERVER then
		task.spawn(hookChat)
	end
end

-- plays an emote on a rig animated on this side (server: NPCs; client: its own character)
function Handler.Play(rig, name)
	local c = controllers[rig]
	if type(c) ~= "table" or type(name) ~= "string" or name == "" then
		return false
	end
	return c:emote(name)
end

function Handler.Stop(rig)
	local c = controllers[rig]
	if type(c) == "table" then
		c:stopCurrent()
		c:play("idle", FADE)
	end
end

function Handler.IsAnimating(rig)
	return type(controllers[rig]) == "table"
end

return Handler
]===]

local HANDLER_CALLER_SOURCE = [===[
-- Uma2Roblox: finds the Uma rigs added to Workspace and gives each UmaAnimateClient (a player's character) or
-- UmaAnimateServer (an NPC). See ReplicatedStorage.UmaAnimateHandler.
require(game:GetService("ReplicatedStorage"):WaitForChild("UmaAnimateHandler")).StartServer()
]===]

local HANDLER_SERVER_SOURCE = [===[
-- Uma2Roblox: animates this NPC Uma rig from the server. Copied in by UmaAnimateHandler (ReplicatedStorage).
require(game:GetService("ReplicatedStorage"):WaitForChild("UmaAnimateHandler")).Animate(script.Parent, script)
]===]

local HANDLER_CLIENT_SOURCE = [===[
-- Uma2Roblox: animates this player's Uma character from their client and adds /e. Copied in by UmaAnimateHandler
-- (ReplicatedStorage).
require(game:GetService("ReplicatedStorage"):WaitForChild("UmaAnimateHandler")).Animate(script.Parent, script)
]===]

local RAGDOLL_NAME = "UmaRagdoll"
local RAGDOLL_CLIENT = "UmaRagdollClient"
local RAGDOLL_SOURCE = [===[
-- UmaRagdoll (Uma2Roblox, part of UmaAnimateHandler): a ragdoll for Uma rigs, switched by an attribute.
--
--   rig:SetAttribute("UmaRagdoll", true)    ragdoll (set it on the server)
--   rig:SetAttribute("UmaRagdoll", false)   stand up again
--   UmaAnimateHandler's RagdollOnDeath attribute (default true): a rig ragdolls when its Humanoid dies
--
-- Uma rigs move by bones, which physics does not move. The server builds invisible parts for the body (torso,
-- head, upper/lower arms and legs) in the rig's current pose, joined by BallSocketConstraints, with the
-- HumanoidRootPart welded to the torso; every client (UmaRagdollClient, in UmaAnimateHandler) then turns the body
-- bones to follow those parts each frame. Hair, skirt and the rest follow their body bones as usual.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Ragdoll = {}

local FOLDER = "UmaRagdoll"
local TAG = "UmaRagdolled"
local PREFIX = "UmaBone_" -- a part's attribute: the bone it carries -> that bone's offset from the part

-- each body part: the bones it carries; the segment it spans (from -> to, stretched by extend); the bone where it
-- joins its parent part, with the cone (degrees off its pose when ragdolled) and twist limits
local SEGMENTS = {
	{ name = "Torso", bones = { "Hip", "Waist", "Chest", "Neck", "Shoulder_L", "Shoulder_R" }, from = "Hip", to = "Neck" },
	{ name = "Head", bones = { "Head" }, joint = "Head", parent = "Torso", limit = 35, twist = 30 },
	{ name = "UpperArm_L", bones = { "Arm_L" }, from = "Arm_L", to = "Elbow_L", joint = "Arm_L", parent = "Torso", limit = 85, twist = 45 },
	{ name = "LowerArm_L", bones = { "Elbow_L" }, from = "Elbow_L", to = "Wrist_L", extend = 1.3, joint = "Elbow_L", parent = "UpperArm_L", limit = 70, twist = 10 },
	{ name = "UpperArm_R", bones = { "Arm_R" }, from = "Arm_R", to = "Elbow_R", joint = "Arm_R", parent = "Torso", limit = 85, twist = 45 },
	{ name = "LowerArm_R", bones = { "Elbow_R" }, from = "Elbow_R", to = "Wrist_R", extend = 1.3, joint = "Elbow_R", parent = "UpperArm_R", limit = 70, twist = 10 },
	{ name = "UpperLeg_L", bones = { "Thigh_L" }, from = "Thigh_L", to = "Knee_L", joint = "Thigh_L", parent = "Torso", limit = 60, twist = 20 },
	{ name = "LowerLeg_L", bones = { "Knee_L" }, from = "Knee_L", to = "Ankle_L", extend = 1.25, joint = "Knee_L", parent = "UpperLeg_L", limit = 70, twist = 5 },
	{ name = "UpperLeg_R", bones = { "Thigh_R" }, from = "Thigh_R", to = "Knee_R", joint = "Thigh_R", parent = "Torso", limit = 60, twist = 20 },
	{ name = "LowerLeg_R", bones = { "Knee_R" }, from = "Knee_R", to = "Ankle_R", extend = 1.25, joint = "Knee_R", parent = "UpperLeg_R", limit = 70, twist = 5 },
}

local function rootOf(rig)
	return rig:FindFirstChild("HumanoidRootPart") or rig.PrimaryPart
end

-- the rig's bones by name (the first of each name)
local function boneMap(rig)
	local map = {}
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("Bone") and not map[d.Name] then
			map[d.Name] = d
		end
	end
	return map
end

-- a CFrame at the middle of a -> b, its Y axis along the segment, X toward the rig's right
local function segmentFrame(a, b, root)
	local y = (b - a).Unit
	local x = root.CFrame.RightVector
	if math.abs(x:Dot(y)) > 0.95 then
		x = root.CFrame.LookVector
	end
	local z = x:Cross(y).Unit
	x = y:Cross(z).Unit
	return CFrame.fromMatrix((a + b) / 2, x, y, z)
end

-- the face mesh (its bounds stand for the head), if any
local function faceMesh(rig)
	local best
	for _, p in ipairs(rig:GetDescendants()) do
		if p:IsA("MeshPart") and string.find(string.lower(p.Name), "face", 1, true) and not string.find(p.Name, "^Face_") then
			if not best or p.Size.Magnitude > best.Size.Magnitude then
				best = p
			end
		end
	end
	return best
end

-- server: builds the ragdoll in the rig's current pose. true when it is ragdolled.
function Ragdoll.Build(rig)
	if rig:FindFirstChild(FOLDER) then
		return true
	end
	local root = rootOf(rig)
	local bones = boneMap(rig)
	if not (root and bones.Hip and bones.Chest) then
		return false
	end
	local function at(name)
		local b = bones[name]
		return b and b.TransformedWorldCFrame.Position
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER
	local parts = {}
	local shoulders = (at("Arm_L") and at("Arm_R")) and (at("Arm_L") - at("Arm_R")).Magnitude or 2

	local function newPart(name, cf, size, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = shape or Enum.PartType.Block
		p.Size = size
		p.CFrame = cf
		p.Transparency = 1
		p.CanCollide = true
		p.CanTouch = false
		p.CanQuery = false
		p.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.8, 0, 1, 1)
		p.Parent = folder
		parts[name] = p
		return p
	end

	for _, s in ipairs(SEGMENTS) do
		local parent = s.parent and parts[s.parent]
		local part
		if s.name == "Head" then
			local head = at("Head")
			if head then
				local face = faceMesh(rig)
				local size = face and math.min(face.Size.X, face.Size.Y, face.Size.Z) * 0.85
					or (at("Neck") and (head - at("Neck")).Magnitude * 6) or shoulders * 1.5
				local center = face and face.Position or (head + root.CFrame.UpVector * size / 2)
				part = newPart("Head", CFrame.new(center) * root.CFrame.Rotation, Vector3.one * size, Enum.PartType.Ball)
			end
		elseif at(s.from) and (at(s.to) or (s.to == "Neck" and at("Chest"))) then
			local a, b = at(s.from), at(s.to) or at("Chest")
			b = a + (b - a) * (s.extend or 1)
			local length = (b - a).Magnitude
			local size
			if s.name == "Torso" then
				size = Vector3.new(shoulders * 0.9, length * 1.15, shoulders * 0.55)
			else
				local w = math.max(length * 0.45, shoulders * 0.15)
				size = Vector3.new(w, length, w)
			end
			part = newPart(s.name, segmentFrame(a, b, root), size)
		end
		if part then
			for _, name in ipairs(s.bones) do
				local b = bones[name]
				if b then
					part:SetAttribute(PREFIX .. name, part.CFrame:ToObjectSpace(b.TransformedWorldCFrame))
				end
			end
			if parent and at(s.joint) then
				-- the joint's primary axis along the child (the head: from the joint to its centre)
				local p = at(s.joint)
				local axis = s.name == "Head" and (part.Position - p) or part.CFrame.UpVector
				axis = axis.Magnitude > 1e-4 and axis.Unit or root.CFrame.UpVector
				local side = math.abs(axis:Dot(root.CFrame.LookVector)) < 0.95 and root.CFrame.LookVector or root.CFrame.RightVector
				local up = side:Cross(axis).Unit
				local cf = CFrame.fromMatrix(p, axis, up)
				local a0, a1 = Instance.new("Attachment"), Instance.new("Attachment")
				a0.Name, a1.Name = "Ragdoll_" .. s.name, "Ragdoll_" .. s.name
				a0.Parent, a1.Parent = parent, part
				a0.WorldCFrame, a1.WorldCFrame = cf, cf
				local joint = Instance.new("BallSocketConstraint")
				joint.Name = "Joint"
				joint.Attachment0, joint.Attachment1 = a0, a1
				joint.LimitsEnabled = true
				joint.UpperAngle = s.limit
				joint.TwistLimitsEnabled = true
				joint.TwistLowerAngle, joint.TwistUpperAngle = -s.twist, s.twist
				joint.Restitution = 0
				joint.Parent = part
			end
		end
	end
	if not parts.Torso then
		folder:Destroy()
		return false
	end
	-- the body does not collide with itself (the chibi head overlaps the shoulders), only with the world
	local list = {}
	for _, p in pairs(parts) do
		table.insert(list, p)
	end
	for i = 1, #list do
		for j = i + 1, #list do
			local nc = Instance.new("NoCollisionConstraint")
			nc.Part0, nc.Part1 = list[i], list[j]
			nc.Parent = list[i]
		end
	end
	-- the root rides on the torso; restored when it stands up
	folder:SetAttribute("RootCanCollide", root.CanCollide)
	folder:SetAttribute("RootMassless", root.Massless)
	folder:SetAttribute("HipLocal", root.CFrame:PointToObjectSpace(at("Hip")))
	folder:SetAttribute("LookLocal", parts.Torso.CFrame:VectorToObjectSpace(root.CFrame.LookVector))
	root.CanCollide = false
	root.Massless = true
	parts.Torso.RootPriority = 1
	local weld = Instance.new("WeldConstraint")
	weld.Name = "RootWeld"
	weld.Part0, weld.Part1 = parts.Torso, root
	weld.Parent = parts.Torso
	local velocity = root.AssemblyLinearVelocity
	folder.Parent = rig
	local owner = Players:GetPlayerFromCharacter(rig)
	for _, p in pairs(parts) do
		p.AssemblyLinearVelocity = velocity
		pcall(p.SetNetworkOwner, p, owner) -- the player simulates their own; the server an NPC
	end
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if hum and not owner and hum.Health > 0 then
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end
	CollectionService:AddTag(rig, TAG)
	return true
end

-- server: removes the ragdoll and stands the root up where the hips lie
function Ragdoll.Remove(rig)
	local folder = rig:FindFirstChild(FOLDER)
	if not folder then
		return
	end
	CollectionService:RemoveTag(rig, TAG)
	local root = rootOf(rig)
	local torso = folder:FindFirstChild("Torso")
	local hipOffset = torso and torso:GetAttribute(PREFIX .. "Hip")
	local hipLocal, lookLocal = folder:GetAttribute("HipLocal"), folder:GetAttribute("LookLocal")
	local hip = hipOffset and (torso.CFrame * hipOffset).Position
	local look = torso and lookLocal and torso.CFrame:VectorToWorldSpace(lookLocal)
	local canCollide, massless = folder:GetAttribute("RootCanCollide"), folder:GetAttribute("RootMassless")
	folder:Destroy()
	if not root then
		return
	end
	root.CanCollide = canCollide ~= false
	root.Massless = massless == true
	if hip and hipLocal then
		local flat = look and Vector3.new(look.X, 0, look.Z) or Vector3.zero
		if flat.Magnitude < 1e-3 then
			flat = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		end
		local turn = CFrame.lookAt(Vector3.zero, flat.Magnitude > 1e-3 and flat.Unit or Vector3.zAxis)
		root.CFrame = turn + (hip - turn:VectorToWorldSpace(hipLocal) + Vector3.new(0, 0.5, 0))
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	if not Players:GetPlayerFromCharacter(rig) then
		pcall(root.SetNetworkOwnershipAuto, root)
	end
end

---------------------------------------------------------------- every client: the bones follow the parts

-- the body bones the parts carry, and every bone between them and the root, parent first
local function rigState(rig)
	local root = rootOf(rig)
	local folder = rig:WaitForChild(FOLDER, 5)
	if not (root and folder) then
		return nil
	end
	local bones = boneMap(rig)
	local driven, needed = {}, {}
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			for key, offset in pairs(part:GetAttributes()) do
				local b = string.sub(key, 1, #PREFIX) == PREFIX and bones[string.sub(key, #PREFIX + 1)]
				if b and typeof(offset) == "CFrame" then
					driven[b] = { part = part, offset = offset }
					local a = b
					while a and a:IsA("Bone") do
						needed[a] = true
						a = a.Parent
					end
				end
			end
		end
	end
	local chain = {}
	local function visit(inst)
		for _, c in ipairs(inst:GetChildren()) do
			if c:IsA("Bone") and needed[c] then
				table.insert(chain, c)
				visit(c)
			end
		end
	end
	visit(root)
	if #chain == 0 then
		return nil
	end
	return { root = root, chain = chain, driven = driven }
end

local function drive(st)
	local world = {}
	for _, b in ipairs(st.chain) do
		local parent = b.Parent
		local parentWorld = world[parent] or (parent:IsA("BasePart") and parent.CFrame) or parent.TransformedWorldCFrame
		local d = st.driven[b]
		if d and d.part.Parent then
			local target = d.part.CFrame * d.offset
			b.Transform = (parentWorld * b.CFrame):Inverse() * target
			world[b] = target
		else
			b.Transform = CFrame.identity
			world[b] = parentWorld * b.CFrame
		end
	end
end

function Ragdoll.StartClient()
	local active = {}
	local function add(rig)
		if active[rig] ~= nil then
			return
		end
		active[rig] = false
		task.spawn(function()
			local st = rigState(rig)
			if active[rig] == false and st and CollectionService:HasTag(rig, TAG) then
				active[rig] = st
			elseif active[rig] == false then
				active[rig] = nil
			end
		end)
	end
	local function remove(rig)
		local st = active[rig]
		active[rig] = nil
		if st then
			for _, b in ipairs(st.chain) do
				b.Transform = CFrame.identity -- the Animator takes over again
			end
		end
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(remove)
	for _, rig in ipairs(CollectionService:GetTagged(TAG)) do
		add(rig)
	end
	-- after the simulation, so the bones show where the parts landed this frame (and win over the Animator)
	RunService.PostSimulation:Connect(function()
		for rig, st in pairs(active) do
			if st then
				if rig.Parent then
					drive(st)
				else
					active[rig] = nil
				end
			end
		end
	end)
end

return Ragdoll
]===]

local RAGDOLL_CLIENT_SOURCE = [===[
-- Uma2Roblox: on every client, turns the bones of ragdolled Uma rigs to follow their ragdoll parts. Runs here, in
-- UmaAnimateHandler (RunContext Client). See UmaRagdoll.
require(script.Parent:WaitForChild("UmaRagdoll")).StartClient()
]===]

local HANDLER_BASE = {
	{ folder = "_idle", anim = "Idle", hint = "Optional: a universal IDLE for rigs without an uploaded idle of their own (UmaAnimate.idle, which always wins). Paste an AnimationId into Idle (or add more Animations; Weight = how often)." },
	{ folder = "_walk", anim = "Walk", required = true, hint = "Your own uploaded WALK animation(s): paste the AnimationId into Walk. Optional SpeedAt1x attribute = speed (studs/s) the clip is made for. Add _run, _jump, _fall, _climb, _sit, _swim the same way." },
}
local HANDLER_EXAMPLES = { "Dance", "Umapyoi" }
local EXTENSION_HINT = "/e %s = a random entry, /e %s1 or /e %s<name> = that one. An entry is an Animation (looped) or a Folder with Start and/or Loop. Any new Folder in UmaAnimateHandler is a new /e command."

local function hasPlayable(set)
	for _, a in ipairs(set and set:GetChildren() or {}) do
		if a:IsA("Animation") and a.AnimationId ~= "" then
			return true
		end
	end
	return false
end

-- replaced rather than edited, as the other runtimes (a new Source did not always reach playtests); keeps children
local function putScript(className, parent, name, source, runContext)
	local old = parent:FindFirstChild(name)
	if old and old.ClassName == className and old.Source == source and (not runContext or old.RunContext == runContext) then
		return "current", old
	end
	local s = Instance.new(className)
	s.Name = name
	s.Source = source
	if runContext then
		s.RunContext = runContext
	end
	if old then
		for _, c in ipairs(old:GetChildren()) do
			c.Parent = s
		end
		for k, v in pairs(old:GetAttributes()) do
			s:SetAttribute(k, v)
		end
		old:Destroy()
	end
	s.Parent = parent
	return old and "updated" or "added", s
end

-- an Animate script written for Uma2Roblox (its UmaAnimate reader), not Roblox's default
local function isUmaAnimate(s)
	return s:IsA("LocalScript") and string.find(s.Source, "UmaAnimate", 1, true) ~= nil
end

-- moves the old Animate's universal sets and dance folders into the handler, then parks the script in ServerStorage
local function migrateAnimate(handler, lines)
	local scs = game:GetService("StarterPlayer"):FindFirstChild("StarterCharacterScripts")
	local old = scs and scs:FindFirstChild("Animate")
	if not (old and isUmaAnimate(old)) then
		return
	end
	local moved = {}
	for _, name in ipairs({ "idle", "walk", "run", "jump", "fall", "climb", "sit", "swim" }) do
		local set = old:FindFirstChild(name)
		local target = handler:FindFirstChild("_" .. name)
		if hasPlayable(set) and not hasPlayable(target) then
			-- the old script also lists Roblox's default (R15) ids; they do not move bones, so only uploads are kept
			local ids = {}
			for _, a in ipairs(set:GetChildren()) do
				if a:IsA("Animation") and a.AnimationId ~= "" and not string.find(a.AnimationId, "roblox.com/asset", 1, true) then
					table.insert(ids, a)
				end
			end
			local dup = name == "run" and hasPlayable(handler:FindFirstChild("_walk"))
				and #ids == 1 and ids[1].AnimationId == (handler._walk:FindFirstChildWhichIsA("Animation") or {}).AnimationId
			if #ids > 0 and not dup then
				if not target then
					target = Instance.new("Folder")
					target.Name = "_" .. name
					target.Parent = handler
				end
				for _, c in ipairs(target:GetChildren()) do
					if c:IsA("Animation") and c.AnimationId == "" then
						c:Destroy() -- the empty placeholder
					end
				end
				for _, a in ipairs(ids) do
					a:Clone().Parent = target
				end
				table.insert(moved, "_" .. name)
			end
		end
	end
	for _, f in ipairs(old:GetChildren()) do
		if f:IsA("Folder") then
			local name = f.Name == "Dances" and "Dance" or f.Name
			local target = handler:FindFirstChild(name)
			if target and #target:GetChildren() == 0 then
				target:Destroy()
				target = nil
			end
			if not target then
				local copy = f:Clone()
				copy.Name = name
				copy:SetAttribute("Help", string.format(EXTENSION_HINT, name, name, name))
				copy.Parent = handler
				table.insert(moved, name)
			end
		end
	end
	old.Enabled = false
	old.Name = OLD_ANIMATE_BACKUP
	old.Parent = game:GetService("ServerStorage")
	table.insert(lines, string.format("Moved the old Uma Animate script to ServerStorage (disabled)%s.",
		#moved > 0 and ("; took over its " .. table.concat(moved, ", ")) or ""))
end

local function installAnimateHandler()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local lines = {}
	local clash = ReplicatedStorage:FindFirstChild(HANDLER_NAME)
	if clash and not clash:IsA("ModuleScript") then
		return nil, "ReplicatedStorage already has a " .. clash.ClassName .. " named " .. HANDLER_NAME .. "; rename it, then click again."
	end
	local result, handler = putScript("ModuleScript", ReplicatedStorage, HANDLER_NAME, HANDLER_SOURCE)
	table.insert(lines, string.format("ReplicatedStorage.%s %s.", HANDLER_NAME,
		result == "current" and "already up to date" or result))
	for _, b in ipairs(HANDLER_BASE) do
		local f = handler:FindFirstChild(b.folder)
		if not f then
			f = Instance.new("Folder")
			f.Name = b.folder
			f.Parent = handler
		end
		f:SetAttribute("Help", b.hint)
	end
	migrateAnimate(handler, lines)
	for _, b in ipairs(HANDLER_BASE) do -- an empty Animation to paste the id into
		local f = handler[b.folder]
		if not f:FindFirstChildWhichIsA("Animation") then
			local a = Instance.new("Animation")
			a.Name = b.anim
			a.AnimationId = ""
			a.Parent = f
		end
	end
	local extensions = 0
	for _, f in ipairs(handler:GetChildren()) do
		if f:IsA("Folder") and string.sub(f.Name, 1, 1) ~= "_" then
			extensions += 1
		end
	end
	if extensions == 0 then -- examples, so the layout explains itself
		for _, name in ipairs(HANDLER_EXAMPLES) do
			local f = Instance.new("Folder")
			f.Name = name
			f:SetAttribute("Help", string.format(EXTENSION_HINT, name, name, name))
			f.Parent = handler
		end
	end
	-- the per-rig scripts live in the handler; the server caller copies them into the rigs
	putScript("LocalScript", handler, HANDLER_CLIENT, HANDLER_CLIENT_SOURCE)
	putScript("Script", handler, HANDLER_SERVER, HANDLER_SERVER_SOURCE)
	putScript("ModuleScript", handler, RAGDOLL_NAME, RAGDOLL_SOURCE)
	putScript("Script", handler, RAGDOLL_CLIENT, RAGDOLL_CLIENT_SOURCE, Enum.RunContext.Client)
	if handler:GetAttribute("RagdollOnDeath") == nil then
		handler:SetAttribute("RagdollOnDeath", true)
	end
	local sss = game:GetService("ServerScriptService")
	local sps = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
	for _, pair in ipairs({ { sss, HANDLER_SERVER }, { sps, HANDLER_CLIENT } }) do
		local old = pair[1]:FindFirstChild(pair[2])
		if old and old:IsA("LuaSourceContainer") and string.find(old.Source, HANDLER_NAME, 1, true) then
			table.insert(lines, "Removed " .. old:GetFullName() .. " (it is inside " .. HANDLER_NAME .. " now).")
			old:Destroy() -- the earlier layout: one script per side for every rig
		end
	end
	local r1 = putScript("Script", sss, HANDLER_CALLER, HANDLER_CALLER_SOURCE)
	table.insert(lines, string.format("ServerScriptService.%s %s: gives each Uma rig in Workspace %s (a player's) or "
		.. "%s (an NPC).", HANDLER_CALLER, r1 == "current" and "up to date" or r1, HANDLER_CLIENT, HANDLER_SERVER))
	if not hasPlayable(handler._walk) then
		local msg = string.format("You must upload your OWN universal walk animation and paste its AnimationId into "
			.. "ReplicatedStorage.%s._walk; moving rigs stand still without it.", HANDLER_NAME)
		table.insert(lines, "WARNING: " .. msg)
		warn("[Uma2Roblox] " .. msg)
	end
	-- the rigs' own emote folder is Emote now (as Dance, Umapyoi); and each rig should have an idle of its own
	local renamed, noIdle = 0, {}
	for _, root in ipairs({ workspace, game:GetService("StarterPlayer"), ReplicatedStorage, game:GetService("ServerStorage") }) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Model") and isUmaModel(d) and not (d.Parent and d.Parent:IsA("Model") and isUmaModel(d.Parent)) then
				local own = d:FindFirstChild(ANIMATE_FOLDER)
				local old = own and own:FindFirstChild("Emotes")
				if old and old:IsA("Folder") and not own:FindFirstChild(EMOTES_FOLDER) then
					old.Name = EMOTES_FOLDER
					renamed += 1
				end
				if not hasPlayable(own and own:FindFirstChild("idle")) then
					table.insert(noIdle, d:GetFullName())
				end
			end
		end
	end
	if renamed > 0 then
		table.insert(lines, string.format("Renamed %d rig(s)' %s.Emotes to %s.%s.", renamed, ANIMATE_FOLDER,
			ANIMATE_FOLDER, EMOTES_FOLDER))
	end
	if #noIdle > 0 then
		local msg = string.format("%d rig(s) have no idle animation of their own (%s.idle with an uploaded "
			.. "AnimationId): %s. Import their animations, then 'Upload rig animations'; until then they use %s._idle "
			.. "if it is set, else stand in rest pose.", #noIdle, ANIMATE_FOLDER, table.concat(noIdle, ", "), HANDLER_NAME)
		table.insert(lines, "WARNING: " .. msg)
		warn("[Uma2Roblox] " .. msg)
	end
	table.insert(lines, "/e commands: every other Folder in " .. HANDLER_NAME .. " (/e Dance, /e Dance3, /e Umapyoi2); /e Emote = the rig's own UmaAnimate.Emote.")
	table.insert(lines, "Ragdoll: rig:SetAttribute(\"UmaRagdoll\", true / false) on the server; dying ragdolls too ("
		.. HANDLER_NAME .. ".RagdollOnDeath).")
	return table.concat(lines, "\n")
end

label("Animation: ReplicatedStorage." .. HANDLER_NAME .. " animates every Uma rig in Workspace. ServerScriptService." .. HANDLER_CALLER .. " gives each rig " .. HANDLER_CLIENT .. " (a player's character, run by their client) or " .. HANDLER_SERVER .. " (an NPC, run by the server). Put your own uploaded walk in its _walk folder (_idle is optional: each rig's own idle comes first); every other Folder in it is an /e command for all rigs (/e Dance, /e Dance3), and each rig's UmaAnimate.Emote its own (/e Emote). Replaces an old Uma Animate script.")
button("Add " .. HANDLER_NAME .. " to this place", function()
	local msg, err
	record("Uma2Roblox: add " .. HANDLER_NAME, function()
		msg, err = installAnimateHandler()
	end)
	status.Text = msg or err or (HANDLER_NAME .. " install failed (see Output).")
end)
end

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
