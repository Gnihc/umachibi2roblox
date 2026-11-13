--[[
	Uma2Roblox Studio plugin
	Install: Studio > Plugins tab > Plugins Folder, copy this file there, restart Studio.

	After importing an Uma_<id>_<costume>_*.glb with File > Import 3D:
	  * select the imported model(s) and click "Apply Uma Toon"
	      - CastShadow off on every MeshPart (no shadows from the model)
	      - SmoothPlastic, no reflectance; the GLB's normals already point up, so Roblox
	        lighting is uniform and the baked anime cel shading shows unchanged
	      - outline hull parts made non-collidable / non-queryable
	      - model turned to face Roblox's front (-Z) and scaled to the target height
	      - tagged with UmaCharaId / UmaCostume attributes
	  * with "Also import its mini animations" on, Apply also builds KeyframeSequences from the
	    animations the app ported, into ServerStorage.RBX_ANIMSAVES.<model> (Animation Editor)
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
	local lastLocal = {} -- constant (face) bones: only key frames where they change
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
				-- face expression bones: instant swaps (Constant easing), and no key while nothing changes
				local prev = lastLocal[bone]
				skip = prev ~= nil and f < anim.frames - 1 and (prev.Position - localCf.Position).Magnitude < 1e-4
				if not skip then
					lastLocal[bone] = localCf
				end
			end
			if needed[bone] and not skip then
				local pose = Instance.new("Pose")
				pose.Name = bone.Name
				pose.CFrame = CFrame.new(localCf.Position / modelScale) * localCf.Rotation
				if d and d.constant then
					pose.EasingStyle = Enum.PoseEasingStyle.Constant
				end
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
	local holder = saves:FindFirstChild(model.Name)
	if not holder then
		holder = Instance.new("ObjectValue")
		holder.Name = model.Name
		holder.Value = model
		holder.Parent = saves
	end
	return holder
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
	local n = 0
	for i, name in ipairs(index.animations) do
		report(string.format("%s: animation %d/%d %s", source, i, #index.animations, name))
		local anim = fetchJson("/anim?model=" .. HttpService:UrlEncode(source) .. "&name=" .. HttpService:UrlEncode(name))
		local ks = buildSequence(anim, fit, bonesByName, order, model:GetScale())
		local old = holder:FindFirstChild(ks.Name)
		if old then
			old:Destroy()
		end
		ks.Parent = holder
		n += 1
	end
	return n
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
toggleRow("Extra Highlight silhouette outline", cfg.highlightOutline, function(v)
	cfg.highlightOutline = v
	saveSettings()
end)
numberRow("Root motion scale (hip movement, 1 = as in game)", cfg.rootMotionScale, function(n)
	cfg.rootMotionScale = math.max(0, n)
	saveSettings()
end)
toggleRow("Also import its mini animations", cfg.autoAnimations, function(v)
	cfg.autoAnimations = v
	saveSettings()
end)
toggleRow("Auto-fix cheek/mayu transparency (0.02)", cfg.autoTransparency, function(v)
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
