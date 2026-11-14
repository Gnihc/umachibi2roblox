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
	  * "Sync with Uma2Roblox app" tells the app which characters are now in this place,
	    so its list only shows characters that still need porting.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Lighting = game:GetService("Lighting")

local SYNC_URL = "http://localhost:34891/uma2roblox"
local SETTINGS_KEY = "Uma2Roblox_Settings_v1"

local cfg = plugin:GetSetting(SETTINGS_KEY) or {}
cfg.targetHeight = cfg.targetHeight or 4
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
cfg.smartBoneAssetId = tonumber(cfg.smartBoneAssetId) or 0
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

-- The importer's RootPart is a big box around the whole scene, centred on the hip. Fit it to the body instead:
-- from the soles to the top of the head, as wide and deep as the head (hair, ears and the arms' T-pose span
-- left out), so the model is easy to grab, place and collide. Bones and joints hang off the RootPart, so their
-- offsets are moved the other way: nothing else moves, and animations stay valid (a pure translation of the
-- root; its rotation is kept). The pivot goes to the soles, so PivotTo puts the feet on the ground.
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
	local rp = model.PrimaryPart or model:FindFirstChild("RootPart")
	if not (rp and rp:IsA("BasePart")) then
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
	local size = Vector3.new(headHi.X - headLo.X, headHi.Y - sole, headHi.Z - headLo.Z)
	local center = Vector3.new((headLo.X + headHi.X) / 2, sole + size.Y / 2, (headLo.Z + headHi.Z) / 2)

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
	local newPivot = CFrame.new(rp.CFrame:PointToWorldSpace(Vector3.new(0, -size.Y / 2, 0))) * oldPivot.Rotation
	if model.PrimaryPart == rp then
		rp.PivotOffset = rp.CFrame:ToObjectSpace(newPivot)
	else
		model.WorldPivot = newPivot
	end
	return true
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

	faceFront(model)
	if fitRootToBody(model) then -- before scaling: the importer's big RootPart box would count in the height
		model:SetAttribute("UmaRootFitted", true)
	end

	local h = model:GetExtentsSize().Y
	if cfg.targetHeight > 0 and h > 0 then
		model:ScaleTo(model:GetScale() * cfg.targetHeight / h)
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
	return count
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
	-- The Animation Editor ties a save folder to its rig through the ObjectValue's Value, not its name: copies
	-- and re-imports of a rig share a name, so the folder must point at THIS rig instance. In order:
	--  1. the folder the Animation Editor already linked to the rig (rig.AnimSaves.Value -> folder)
	--  2. a folder whose Value is this rig (the fullest one, if there are several)
	--  3. a same-named folder whose rig is gone (Value nil, or an instance no longer in the place, e.g. the
	--     rig was deleted or re-imported): re-pointed at this rig
	--  4. a new folder
	local function live(inst)
		return inst ~= nil and inst:IsDescendantOf(game)
	end
	local link = model:FindFirstChild("AnimSaves")
	local linked = link and link:IsA("ObjectValue") and link.Value
	if linked and linked:IsA("ObjectValue") and linked.Parent == saves and (linked.Value == model or not live(linked.Value)) then
		linked.Value = model
		return linked
	end
	local mine, orphan
	for _, child in ipairs(saves:GetChildren()) do
		if child:IsA("ObjectValue") then
			if child.Value == model then
				if not mine or #child:GetChildren() > #mine:GetChildren() then
					mine = child
				end
			elseif child.Name == model.Name and not live(child.Value) then
				if not orphan or #child:GetChildren() > #orphan:GetChildren() then
					orphan = child
				end
			end
		end
	end
	if mine then
		return mine
	end
	if orphan then
		orphan.Value = model
		return orphan
	end
	local holder = Instance.new("ObjectValue")
	holder.Name = model.Name
	holder.Value = model
	holder.Parent = saves
	return holder
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

local function importAnimations(model, report)
	local source = model:GetAttribute("UmaSource") or model.Name
	local index = fetchJson("/anims?model=" .. HttpService:UrlEncode(source))
	if not index.animations or #index.animations == 0 then
		report(source .. ": no animations ported yet (enable 'Port mini animations' in the app).")
		return 0
	end
	-- rig needs an Animator to play
	if not model:FindFirstChildWhichIsA("Humanoid", true) and not model:FindFirstChildWhichIsA("AnimationController") then
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
	if holder.Value ~= model then -- never leave animations where the Animation Editor won't find them
		warn(string.format("[Uma2Roblox] %s: save folder pointed elsewhere; re-linked it to this rig", model.Name))
		holder.Value = model
	end
	return n, holder
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
-- original game (hair, tail, ribbons, skirt/jacket, bust).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local function enable(model)
	local rp = model.PrimaryPart or model:FindFirstChild("RootPart")
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
		if rp:GetAttribute(k) == nil then
			rp:SetAttribute(k, v)
		end
	end
	for _, d in ipairs(rp:GetDescendants()) do
		if isSpring(d) and d:GetAttribute("RotationLimit") == nil then
			d:SetAttribute("RotationLimit", ROTATION_LIMIT)
		end
	end
	CollectionService:AddTag(rp, "SmartBone")
end

local function disable(model)
	local rp = model.PrimaryPart or model:FindFirstChild("RootPart")
	if rp then
		CollectionService:RemoveTag(rp, "SmartBone")
	end
end

-- Only rigs in Workspace move; templates in ReplicatedStorage are left alone until they are put in Workspace.
local function watch(model)
	if not model:IsA("Model") or watching[model] then
		return
	end
	watching[model] = true
	local function update()
		if model:IsDescendantOf(workspace) then
			if not (model.PrimaryPart or model:FindFirstChild("RootPart")) then
				model:WaitForChild("RootPart", 30) -- streaming: the RootPart can arrive after the model
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

-- Returns "patched", "already" or nil plus what is missing
local function patchSmartBone(module)
	local edits = {}
	for _, p in ipairs(SB_PATCHES) do
		local script = module
		for _, name in ipairs(p.path) do
			script = script and script:FindFirstChild(name)
		end
		if not (script and script:IsA("LuaSourceContainer")) then
			return nil, "no " .. table.concat(p.path, ".") .. " module"
		end
		edits[script] = edits[script] or script.Source
	end
	local already = true
	for _, src in pairs(edits) do
		if not string.find(src, SB_MARK, 1, true) then
			already = false
		end
	end
	if already then
		return "already"
	end
	for _, p in ipairs(SB_PATCHES) do
		local script = module
		for _, name in ipairs(p.path) do
			script = script:FindFirstChild(name)
		end
		local src = edits[script]
		local a, b = string.find(src, p.find, 1, true)
		if not a or string.find(src, p.find, b + 1, true) then
			return nil, "unknown SmartBone version (the line to patch in " .. script.Name .. " was not found once)"
		end
		local new = p.replace or (p.find .. p.add)
		edits[script] = string.sub(src, 1, a - 1) .. new .. string.sub(src, b + 1)
	end
	for script, src in pairs(edits) do
		script.Source = src
	end
	return "patched"
end

-- A rig the importer made: a RootPart part with Bones under it
local function isRig(model)
	local rp = model:IsA("Model") and (model.PrimaryPart or model:FindFirstChild("RootPart"))
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
	local runtime = sps:FindFirstChild(SMARTBONE_SCRIPT)
	if runtime and not runtime:IsA("LocalScript") then
		runtime:Destroy()
		runtime = nil
	end
	local created = runtime == nil
	runtime = runtime or Instance.new("LocalScript")
	runtime.Name = SMARTBONE_SCRIPT
	runtime.Source = (string.gsub(SMARTBONE_RUNTIME, "%-%-%[%[SMARTBONE_PATH%]%]", function()
		return requirePath(module)
	end))
	runtime.Parent = sps
	table.insert(lines, (created and "Added" or "Updated") .. " StarterPlayerScripts." .. SMARTBONE_SCRIPT .. ".")

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
numberRow("Target height (studs, 0 = keep)", cfg.targetHeight, function(n)
	cfg.targetHeight = n
	saveSettings()
end)
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
toggleRow("Smooth out blinks (sprite #3 between open and closed eyes)", cfg.smoothBlinks, function(v)
	cfg.smoothBlinks = v
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

button("Import Uma animations for selection", function()
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
end)

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
button("Integrate SmartBone 2 into this place", function()
	local msg, err
	record("Uma2Roblox: integrate SmartBone 2", function()
		msg, err = integrateSmartBone()
	end)
	status.Text = msg or err or "SmartBone 2 integration failed (see Output)."
end)

button("Place: remove PBR reflections (optional)", function()
	record("Uma2Roblox: lighting", function()
		Lighting.EnvironmentSpecularScale = 0
	end)
	status.Text = "Lighting.EnvironmentSpecularScale = 0 (affects the whole place; undo with Ctrl+Z)."
end)

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
