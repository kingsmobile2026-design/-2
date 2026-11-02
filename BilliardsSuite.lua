-- 당구 통합 도우미 (UI 라이브러리 분리 버전)
-- UI: https://raw.githubusercontent.com/kingsmobile2026-design/-2/refs/heads/main/BilliardsUI.lua

local function __patchAI(modules, name)
	local module = modules:FindFirstChild(name) or modules:FindFirstChild(name, true)
	if not (module and module:IsA("ModuleScript")) then return nil end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" and type(result.Plan) == "function" then return result end
	warn("[당구 패치] " .. name .. " 모듈을 쓸 수 없어 건너뜁니다: " .. (ok and "Plan 함수 없음" or tostring(result)))
	return nil
end

local function __patchReport(modules, poolAI, ai)
	if poolAI and ai then
		print("[당구 패치] 게임 AI 모듈을 찾았습니다. 원래 방식으로 계산합니다.")
		return
	end
	warn("[당구 패치] 게임 AI 모듈이 없어 자체 후보 탐색으로 계산합니다. (포켓볼 AI: "
		.. (poolAI and "있음" or "없음") .. ", 4구·3구 AI: " .. (ai and "있음" or "없음") .. ")")
	local found = {}
	for _, item in ipairs(modules:GetDescendants()) do
		if item:IsA("ModuleScript") and (string.find(item.Name, "AI", 1, true) or string.find(item.Name, "Bot", 1, true)) then
			table.insert(found, item:GetFullName())
		end
	end
	if #found > 0 then warn("[당구 패치] 이름에 AI/Bot 이 들어간 모듈: " .. table.concat(found, ", ")) end
end

local function __patchSeed(raw, limit, selectedState, poolAI, ai)
	if selectedState.PoolMode then
		if not poolAI then return nil end
	elseif not ai then
		return nil
	end
	local ok, seed = pcall(raw, limit, selectedState)
	if not ok then
		warn("[당구 패치] 게임 AI 계산 오류, 자체 계산으로 대신합니다: " .. tostring(seed))
		return nil
	end
	if type(seed) ~= "table" or type(seed.angle) ~= "number" or type(seed.power) ~= "number"
		or seed.angle ~= seed.angle or seed.power ~= seed.power then
		return nil
	end
	seed.side = tonumber(seed.side) or 0
	seed.top = tonumber(seed.top) or 0
	return seed
end

local __patchSeenErrors = {}
local function __patchEval(raw, selectedState, shot, stop)
	local ok, a, b, c = pcall(raw, selectedState, shot, stop)
	if ok then return a, b, c end
	local message = tostring(a)
	if not __patchSeenErrors[message] then
		__patchSeenErrors[message] = true
		warn("[당구 패치] 후보 검증 오류(이 후보는 건너뜀): " .. message)
	end
	return nil, message
end

local function __patchEarly(s, selectedRemote, seed, add, physicsFor, poolPhysics, groupFor, poolLegal, clearLine)
	if seed then return end
	if s.PoolMode then
		local c = poolPhysics.Config
		local balls = s.balls
		local legal = poolLegal(balls, groupFor(s), s.breakShot)
		if s.breakShot then
			local origin = balls[1].p
			local best, bestDistance
			for i = 2, #balls do
				if legal[i] then
					local distance = (balls[i].p - origin).Magnitude
					if not bestDistance or distance < bestDistance then best, bestDistance = i, distance end
				end
			end
			if best then
				local delta = balls[best].p - origin
				local angle = math.atan2(delta.Z, delta.X)
				for _, offset in ipairs({0, 0.004, -0.004, 0.01, -0.01}) do
					for _, power in ipairs({1, 0.9}) do
						add({angle = angle + offset, power = power, side = 0, top = 0})
					end
				end
			end
		elseif s.ballInHand or s.kitchen then
			local kitchenOnly = s.kitchen and not s.ballInHand
			local function validSpot(pos)
				if pos.X < c.Radius or pos.X > c.Width - c.Radius or pos.Z < c.Radius or pos.Z > c.Height - c.Radius then return false end
				if kitchenOnly and pos.X > c.Width * 0.25 then return false end
				if poolPhysics.PocketAt(pos) then return false end
				for i = 2, #balls do
					if not balls[i].pocketed and (balls[i].p - pos).Magnitude < 2 * c.Radius + 0.001 then return false end
				end
				return true
			end
			local spots = {}
			for i = 2, #balls do
				local ball = balls[i]
				if legal[i] then
					for _, pocket in ipairs(poolPhysics.Pockets) do
						local toHole = pocket.hole - ball.p
						if toHole.Magnitude > c.Radius then
							local ghost = ball.p - toHole.Unit * (2 * c.Radius)
							for _, back in ipairs({5, 9, 14}) do
								local pos = ghost - toHole.Unit * (back * c.Radius)
								if validSpot(pos) and clearLine(balls, pos, ghost, 1, i) and clearLine(balls, ball.p, pocket.hole, 1, i) then
									table.insert(spots, {pos = pos, angle = math.atan2(toHole.Z, toHole.X), distance = (ghost - pos).Magnitude + toHole.Magnitude})
									break
								end
							end
						end
					end
				end
			end
			table.sort(spots, function(x, y) return x.distance < y.distance end)
			for k = 1, math.min(#spots, 8) do
				local spot = spots[k]
				local approximate = math.clamp(math.sqrt(2.8 * c.RollingFriction * c.Gravity * spot.distance) / c.MaxSpeed, 0.13, 0.6)
				for _, multiplier in ipairs({1.4, 2}) do
					add({angle = spot.angle, power = approximate * multiplier, side = 0, top = 0, cue = {spot.pos.X, spot.pos.Z}})
				end
			end
		end
	else
		local physics = physicsFor(s, selectedRemote)
		local c, origin = physics.Config, s.balls[s.turn].p
		local targets = #s.balls == 3 and {3, 3 - s.turn} or {3, 4}
		for _, i in ipairs(targets) do
			local delta = s.balls[i].p - origin
			local distance = delta.Magnitude
			if distance > 2 * c.Radius then
				local base = math.atan2(delta.Z, delta.X)
				for _, f in ipairs({0.5, -0.5, 0.25, -0.25, 0.75, -0.75}) do
					local offset = math.asin(math.min(0.99, math.abs(f) * 2 * c.Radius / distance)) * (f > 0 and 1 or -1)
					for _, power in ipairs({0.45, 0.65, 0.85}) do
						add({angle = base + offset, power = power, side = f > 0 and 0.2 or -0.2, top = 0.15})
					end
				end
			end
		end
	end
end

local function __patchLate(s, seed, add)
	if seed or s.PoolMode then return end
	for index = 0, 71 do
		local angle = index * math.pi / 36
		for _, power in ipairs({0.55, 0.8}) do
			add({angle = angle, power = power, side = 0, top = 0.2})
		end
	end
end


-- UI Library (external)
local UI_LIB_URL = "https://raw.githubusercontent.com/kingsmobile2026-design/-2/refs/heads/main/BilliardsUI.lua"
local function loadUILibrary()
	local env = (type(getgenv) == "function" and getgenv()) or _G
	if type(env.BilliardsUI) == "table" and type(env.BilliardsUI.CreateWindow) == "function" then
		return env.BilliardsUI
	end
	local source
	local ok, result = pcall(function()
		return game:HttpGet(UI_LIB_URL)
	end)
	if ok and type(result) == "string" and #result > 100 then
		source = result
	else
		-- fallback: some executors use http_request / request
		local requestFn = (syn and syn.request) or (http and http.request) or http_request or request
		if type(requestFn) == "function" then
			local resp = requestFn({ Url = UI_LIB_URL, Method = "GET" })
			source = resp and (resp.Body or resp.body)
		end
	end
	assert(type(source) == "string" and #source > 100, "당구 UI 라이브러리를 불러오지 못했습니다: " .. tostring(result))
	local chunk, err = loadstring(source)
	assert(chunk, "UI 라이브러리 파싱 실패: " .. tostring(err))
	local lib = chunk()
	assert(type(lib) == "table" and type(lib.CreateWindow) == "function", "UI 라이브러리 형식이 올바르지 않습니다.")
	env.BilliardsUI = lib
	return lib
end

local UI = loadUILibrary()

local function startPreview()
	local env = getgenv()
	if env.BilliardsPath then
		env.BilliardsPath.Stop()
	end
	local modules = game:GetService("ReplicatedStorage"):WaitForChild("Billiards", 10)
	assert(modules, "당구 모듈을 찾을 수 없습니다.")
	local preview = require(modules:WaitForChild("ShotPreview", 10))
	local geometry = require(modules:WaitForChild("TableGeometry", 10))
	local guides = require(modules:WaitForChild("GuideLines", 10))
	local originalShow = guides.Show
	local showWrapper
	local original = preview.Predict
	assert(type(original) == "function", "예상 경로 API가 변경되었습니다.")
	local runService = game:GetService("RunService")
	local folder = Instance.new("Folder")
	folder.Name = "당구예상경로"
	folder.Parent = workspace
	local state = {Enabled = true, Calls = 0, Segments = 0, Error = nil, HoldUntil = 0}
	local pool = {}
	local lastCall = 0
	local lastBuild = -math.huge
	local alive = true
	local busy = false
	local wrapper
	local heartbeat
	local colours = {
		Color3.fromRGB(80, 240, 255),
		Color3.fromRGB(255, 200, 65),
		Color3.fromRGB(255, 110, 140),
		Color3.fromRGB(135, 255, 130)
	}
	local function hide()
		for _, part in ipairs(pool) do
			part.Transparency = 1
		end
		state.Segments = 0
	end
	local function segment(a, b, colour, count)
		local length = (b - a).Magnitude
		if length < 0.012 or count >= 320 then
			return count
		end
		count = count + 1
		local part = pool[count]
		if not part then
			part = Instance.new("Part")
			part.Name = "경로"
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.CastShadow = false
			part.Material = Enum.Material.Neon
			part.Parent = folder
			pool[count] = part
		end
		part.Size = Vector3.new(0.025, 0.025, length)
		part.CFrame = CFrame.lookAt((a + b) / 2, b)
		part.Color = colour
		part.Transparency = 0.18
		return count
	end
	local function findGeometry(config)
		local views = workspace:FindFirstChild("BilliardsView")
		if not views then return nil end
		local chosen, best
		local camera = workspace.CurrentCamera
		for _, part in ipairs(views:GetDescendants()) do
			if part.Name == "PlayArea" and part:IsA("BasePart") then
				local mismatch = math.abs(part.Size.X / config.VisualScale - config.Width)
					+ math.abs(part.Size.Z / config.VisualScale - config.Height)
				if mismatch < 0.03 then
					local distance = camera and (camera.Focus.Position - part.Position).Magnitude or 0
					if not best or distance < best then
						chosen, best = part, distance
					end
				end
			end
		end
		if not chosen then return nil end

		return geometry.Configure(table.clone(config), chosen)
	end
	local function build(physics, balls, cueIndex, direction, power, spinX, spinY, boost)
		local config = physics.Config
		local geo = findGeometry(config)
		if not geo then
			hide()
			state.Error = "현재 물리 설정에 맞는 PlayArea를 찾지 못했습니다."
			return
		end
		local copies, paths = {}, {}
		for i, ball in ipairs(balls) do
			copies[i] = table.clone(ball)
			paths[i] = {ball.p}
		end
		local cue = copies[cueIndex]
		if not cue or cue.pocketed then hide() return end
		local reach = physics.Reach and physics.Reach(copies, cueIndex, direction) or boost or 1
		physics.Strike(cue, direction, math.clamp(power, 0, 1), spinX, spinY, reach)
		local started = os.clock()
		local dt = config.Step
		local steps = math.min(math.ceil(12 / dt), 900)
		local simulated = 0
		for step = 1, steps do
			physics.Step(copies, dt)
			simulated = step * dt
			local moving = false
			for i, ball in ipairs(copies) do
				if not ball.pocketed then
					if step % 3 == 0 or step == steps then
						local path = paths[i]
						if (ball.p - path[#path]).Magnitude > 0.002 then
							path[#path + 1] = ball.p
						end
					end
					if ball.v.Magnitude > 0.001 or (physics.Slip and physics.Slip(ball).Magnitude > 0.001) then
						moving = true
					end
				end
			end
			if not moving or os.clock() - started > 0.018 then
				for i, ball in ipairs(copies) do
					if not ball.pocketed then
						local path = paths[i]
						if (ball.p - path[#path]).Magnitude > 0.002 then
							path[#path + 1] = ball.p
						end
					end
				end
				break
			end
		end
		local count = 0

		for pass = 1, 2 do
			for i, path in ipairs(paths) do
				if (pass == 1 and i == cueIndex) or (pass == 2 and i ~= cueIndex) then
					local colour = i == cueIndex and colours[1] or colours[2 + ((i - 1) % 3)]
					for j = 2, #path do
						local lift = Vector3.new(0, 0.025, 0)
						count = segment(geo:World(path[j - 1]) + lift, geo:World(path[j]) + lift, colour, count)
					end
				end
			end
		end
		for i = count + 1, #pool do pool[i].Transparency = 1 end
		state.Segments = count
		state.SimulatedSeconds = simulated
		state.Error = nil
	end
	wrapper = function(physics, balls, cueIndex, direction, power, spinX, spinY, ...)

		local result = original(physics, balls, cueIndex, direction, power, spinX, spinY, ...)
		if alive then
			lastCall = os.clock()
			state.Calls = state.Calls + 1
			if state.Enabled and not busy and lastCall >= state.HoldUntil and lastCall - lastBuild >= 0.2 then
				lastBuild = lastCall
				busy = true
				local _, selectedPower = ...
				local ok, err = pcall(build, physics, balls, cueIndex, direction, selectedPower or power, spinX, spinY)
				busy = false
				if not ok then
					hide()
					state.Error = tostring(err)
				end
			end
		end
		return result
	end
	function state.SetEnabled(value)
		state.Enabled = value == true
		if not state.Enabled then state.HoldUntil = 0 hide() end
	end
	function state.DrawPlan(physics, balls, cueIndex, plan)
		if not alive or not state.Enabled then return false end
		local direction = Vector3.new(math.cos(plan.angle), 0, math.sin(plan.angle))
		local drawBalls = balls
		if plan.cue then
			drawBalls = table.clone(balls)
			drawBalls[1] = table.clone(balls[1])
			drawBalls[1].p = Vector3.new(plan.cue[1], 0, plan.cue[2])
			drawBalls[1].pocketed = nil
		end
		local ok, err = pcall(build, physics, drawBalls, cueIndex, direction, plan.power, plan.side, plan.top, plan.BreakBoost)
		if not ok then state.Error = tostring(err) hide() return false end
		lastCall = os.clock()
		state.HoldUntil = lastCall + 1.2
		return true
	end
	function state.Stop()
		if not alive then return end
		alive = false
		if preview.Predict == wrapper then preview.Predict = original end
		if guides.Show == showWrapper then guides.Show = originalShow end
		if heartbeat then heartbeat:Disconnect() end
		folder:Destroy()
		if env.BilliardsPath == state then env.BilliardsPath = nil end
	end
	preview.Predict = wrapper
	showWrapper = function(self, ...)
		local shown = originalShow(self, ...)
		if alive and shown then
			lastCall = os.clock()
			if state.Enabled and state.OnPoolGuide and lastCall >= state.HoldUntil and lastCall - lastBuild >= 0.2 then
				lastBuild = lastCall
				local data = ...
				local ok, err = pcall(state.OnPoolGuide, data)
				if not ok then state.Error = tostring(err) end
			end
		end
		return shown
	end
	guides.Show = showWrapper
	heartbeat = runService.Heartbeat:Connect(function()
		if not state.Enabled or (os.clock() > state.HoldUntil and os.clock() - lastCall > 0.5) then hide() end
	end)
	env.BilliardsPath = state
	return state
end
local function startAuto(preview)
	local env = getgenv()
	local modules = game:GetService("ReplicatedStorage"):WaitForChild("Billiards", 10)
	assert(modules, "당구 모듈을 찾지 못했습니다.")
	local basePhysics = require(modules:WaitForChild("Physics", 10))
	local poolPhysics = require(modules:WaitForChild("PoolPhysics", 10))
	local poolAI = __patchAI(modules, "PocketBallAI")
	local ai = __patchAI(modules, "FourBallAI")
	local cueMotion = require(modules:WaitForChild("CueMotion", 10))
	local geometry = require(modules:WaitForChild("TableGeometry", 10))
	local matchClass = require(modules:WaitForChild("Match", 10))
	__patchReport(modules, poolAI, ai) assert(true, "자동 조준 API가 변경되었습니다.")
	if env.BilliardsAuto then env.BilliardsAuto.Stop() end
	local player = game:GetService("Players").LocalPlayer
	local runService = game:GetService("RunService")
	local state = {
		Enabled = false, Status = "경기 상태 확인 중", ShotsSent = 0,
		ShotsAccepted = 0, Error = nil, LastPlan = nil, Thinking = false,
		ThinkSeconds = 10, Level = 4, StrongPlay = true, SmoothCue = true, SmoothCuePreference = true, AimSeconds = 1.0, HumanThinking = true,
		Style = "balanced", StyleName = "균형형",
	}
	local alive, generation = true, 0
	local remote, snapshot, listener, heartbeat, window, statusLabel, toggle, modeLabel, statsLabel
	state.Preview = preview
	state.Version = "20261018_09"
	state.Standalone = true
	local attempted, pending, plannedKey, readyAt
	local lastTick, lastSync = 0, -math.huge
	local tablePhysics, physicsRemote, physicsThree
	local function key(s)
		return table.concat({tostring(s.round), tostring(s.turnId), tostring(s.shots), tostring(s.turn)}, ":")
	end
	local function myTurn(s)
		if s.turnPlayerId ~= nil then return s.turnPlayerId == player.UserId end
		if s.doubles then return false end
		return s.seats and s.seats[s.turn] == player.UserId
	end
	local function ready(s)
		if not s or s.phase ~= "playing" or not myTurn(s) then return false end
		if s.LocalMoving or s.moving or s.striking or s.opening or s.openingWaiting or s.cleaning then return false end
		if s.winner ~= 0 or s.stale or not s.balls or not s.balls[s.PoolMode and 1 or s.turn] then return false end
		local now = workspace:GetServerTimeNow()
		return now >= (s.busyUntil or 0) and now + 0.6 < (s.turnDeadline or 0)
	end
	local function setStatus(text)
		if state.Status == text then return end
		state.Status = text
		if statusLabel then statusLabel:SetText(text) end
	end
	local function pause(reason)
		state.Enabled = false
		generation = generation + 1
		if toggle then toggle:Set(false, true) end
		setStatus(reason)
	end
	local function physicsFor(s, selectedRemote)
		if s.PoolMode then return poolPhysics end
		local three = s.threeBall == true or (s.rules and s.rules.threeBall == true)
		if tablePhysics and physicsRemote == selectedRemote and physicsThree == three then return tablePhysics end
		local physical = selectedRemote:FindFirstChild("Table")
		physical = physical and physical.Value
		assert(physical, "현재 경기의 테이블을 찾지 못했습니다.")
		local size = physical:GetAttribute("TableSize")
		local viewName = three and size ~= "중대" and "DaedaeView" or "ViewTable"
		local views = workspace:FindFirstChild("BilliardsView")
		local view = views and views:FindFirstChild(viewName)
		local area = view and view:FindFirstChild("PlayArea", true)
		assert(area and area:IsA("BasePart"), "경기에 맞는 PlayArea를 찾지 못했습니다.")
		local physics = basePhysics.ForTable(three)
		geometry.Configure(physics.Config, area)
		tablePhysics, physicsRemote, physicsThree = physics, selectedRemote, three
		return physics
	end
	local function normalizePool(raw)
		local s = table.clone(raw)
		s.PoolMode = true
		s.RawBalls = raw.balls
		s.shots = raw.shotSeq or 0
		s.balls = {}
		for i, b in ipairs(raw.balls or {}) do
			local ball = poolPhysics.NewBall(i, b[1], b[2])
			if b[3] and b[3] ~= 0 then ball.pocketed = b[3] end
			s.balls[i] = ball
		end
		return s
	end
	local function normalizePlanSpin(plan)
		plan.side = math.clamp(tonumber(plan.side) or 0, -0.65, 0.65)
		plan.top = math.clamp(tonumber(plan.top) or 0, -0.65, 0.65)
		local magnitude = math.sqrt(plan.side * plan.side + plan.top * plan.top)
		if magnitude > 0.65 then plan.side, plan.top = plan.side * 0.65 / magnitude, plan.top * 0.65 / magnitude end
		return plan
	end
	function state.EvaluatePool(s, inputPlan, cancelled)
		local group = s.groups and s.groups[s.turn] or nil
		local onEight = group and true or false
		local legal = {}
		for i = 2, 16 do
			local n = i - 1
			if not s.balls[i].pocketed and group and n ~= 8 and ((n < 8) == (group == "low")) then onEight = false end
		end
		for i = 2, 16 do
			local n = i - 1
			legal[i] = s.breakShot or (onEight and n == 8) or
				(not onEight and n ~= 8 and (not group or ((n < 8) == (group == "low"))))
		end
		local deadline = os.clock() + math.clamp(state.ThinkSeconds, 1, 15)
		local function interrupted()
			return not alive or os.clock() > deadline or (cancelled and cancelled())
		end
		local request = {kitchen = s.kitchen == true or s.breakShot == true}
		local plan = table.clone(inputPlan)
		normalizePlanSpin(plan)
		if interrupted() then return nil, "경기 상태 변경 또는 계산 중단" end
		for _, field in ipairs({"angle", "power", "side", "top"}) do
			local n = plan[field]
			assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "포켓볼 타격값 오류")
		end
		assert(plan.power >= 0.005 and plan.power <= 1, "포켓볼 힘 범위 오류")
		assert(Vector2.new(plan.side, plan.top).Magnitude <= 0.6501, "포켓볼 회전 범위 오류")
		local balls = {}
		for i, b in ipairs(s.balls) do balls[i] = table.clone(b) end
		if plan.cue then
			local c = poolPhysics.Config
			local pos = Vector3.new(plan.cue[1], 0, plan.cue[2])
			assert(s.ballInHand or s.breakShot or s.kitchen, "수구 배치 권한 없음")
			assert(pos.X >= c.Radius and pos.X <= c.Width - c.Radius and pos.Z >= c.Radius and pos.Z <= c.Height - c.Radius and not poolPhysics.PocketAt(pos), "수구 배치 범위 오류")
			assert(not request.kitchen or s.ballInHand or pos.X <= c.Width * 0.25, "브레이크 수구 배치 범위 오류")
			for i = 2, 16 do assert(balls[i].pocketed or (balls[i].p - pos).Magnitude >= 2 * c.Radius, "수구 배치 겹침") end
			balls[1].p, balls[1].pocketed = pos, nil
		end
		local first, scratched, eight, own, any, rail = nil, false, false, 0, 0, false
		local pocketedIndices = {}
		local function contact(a, b)
			if not first then if a == 1 then first = b elseif b == 1 then first = a end end
		end
		local function impact(kind)
			if first and kind == "rail" then rail = true end
		end
		local function pocket(i)
			table.insert(pocketedIndices, i)
			if i == 1 then scratched = true elseif i == 9 then eight = true
			else any = any + 1 if legal[i] then own = own + 1 end end
		end
		plan.BreakBoost = s.breakShot and poolPhysics.Config.BreakBoost or 1
		poolPhysics.Strike(balls[1], Vector3.new(math.cos(plan.angle), 0, math.sin(plan.angle)), plan.power, plan.side, plan.top, plan.BreakBoost)
		local settled, frameAt = false, os.clock()
		for _ = 1, math.ceil(30 / poolPhysics.Config.Step) do
			poolPhysics.Step(balls, poolPhysics.Config.Step, contact, impact, pocket)
			if poolPhysics.IsSettled(balls) then settled = true break end
			if os.clock() - frameAt > 0.003 then task.wait() frameAt = os.clock() if interrupted() then return nil, "포켓볼 검증 중 상태 변경 또는 시간 초과" end end
		end
		if not settled then return nil, "포켓볼 정지 확인 시간 초과" end
		plan.VerifiedFoul = scratched or not first or not legal[first] or (not rail and any == 0 and not eight)
		plan.VerifiedScore = group and own or any
		plan.VerifiedWinner = eight and onEight and not plan.VerifiedFoul and s.turn or 0
		plan.VerifiedLoss = eight and not s.breakShot and (not onEight or plan.VerifiedFoul)
		if plan.VerifiedLoss then return nil, "8번 공 조기 포켓 예상 타격 제외" end
		if plan.VerifiedFoul then return nil, "포켓볼 파울 예상 타격 제외" end
		plan.PocketedIndices = pocketedIndices
		return plan, balls
	end

	function state.EvaluateCarom(s, selectedRemote, inputPlan, cancelled)
		assert(s and s.balls and s.turn, "계산할 경기 상태가 없습니다.")
		if s.PoolMode then return state.EvaluatePool(s, inputPlan, cancelled) end
		local physics = physicsFor(s, selectedRemote)
		local balls = {}
		for i, ball in ipairs(s.balls) do
			assert(typeof(ball.p) == "Vector3", "공 위치 형식이 변경되었습니다.")
			balls[i] = physics.NewBall(i, ball.p.X, ball.p.Z)
			balls[i].v = ball.v or Vector3.new()
			balls[i].w = ball.w or Vector3.new()
		end
		local three = #balls == 3
		local final = s.finalThreeCushion and s.finalThreeCushion[s.turn] == true
		local deadline = os.clock() + math.clamp(state.ThinkSeconds, 1, 15)
		local function interrupted()
			return not alive or os.clock() > deadline or (cancelled and cancelled())
		end
		local plan = table.clone(inputPlan)
		normalizePlanSpin(plan)
		if interrupted() then return nil, "경기 상태 변경 또는 계산 중단" end
		for _, field in ipairs({"angle", "power", "side", "top"}) do
			local n = plan[field]
			assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "조준 계산값이 올바르지 않습니다.")
		end
		plan.power = math.clamp(plan.power, cueMotion.MinPower, 1)
		local spin = Vector2.new(plan.side, plan.top)
		assert(spin.Magnitude <= (cueMotion.MaxSpin or 0.65) + 0.0001, "회전값이 허용 범위를 벗어났습니다.")

		local test = matchClass.new(three, physics)
		test:SetRules(s.targetScore or (s.rules and s.rules.target) or 10,
			s.finalRule == true or (s.rules and s.rules.final == true),
			not s.rules or s.rules.penalty ~= false)
		test.balls = {}
		for i, ball in ipairs(balls) do test.balls[i] = table.clone(ball) end
		test.turn = s.turn
		test.scores = {s.scores and s.scores[1] or 0, s.scores and s.scores[2] or 0}
		test.turnStartScore = test.scores[s.turn]
		local scoreBefore = test.scores[s.turn]
		assert(test:Shoot(plan.angle, plan.power, plan.side, plan.top), "물리 엔진이 타격값을 거부했습니다.")
		local frameAt = os.clock()
		for _ = 1, math.ceil(35 / physics.Config.Step) do
			test:Step(physics.Config.Step)
			if not test.moving then break end
			if os.clock() - frameAt > 0.003 then
				task.wait()
				frameAt = os.clock()
				if interrupted() then return nil, "검증 중 경기 상태 변경 또는 시간 초과" end
			end
		end
		if test.moving then return nil, "정지까지 검증하지 못한 타격" end
		plan.VerifiedScore = test.scores[s.turn] - scoreBefore
		plan.VerifiedFoul = test.shot and test.shot.foul == true or false
		plan.VerifiedWinner = test.winner
		if plan.VerifiedFoul or plan.VerifiedScore < 0 then return nil, "파울 예상 타격 제외" end
		return plan, test.balls, test
	end
	local function groupFor(s)
		return s.groups and s.groups[s.turn] or nil
	end
	local function poolLegal(balls, group, breakShot)
		local onEight = group ~= nil
		if group then
			for i = 2, 16 do
				local n = i - 1
				if not balls[i].pocketed and n ~= 8 and ((n < 8) == (group == "low")) then onEight = false end
			end
		end
		local legal = {}
		for i = 2, 16 do
			local n = i - 1
			legal[i] = not balls[i].pocketed and (breakShot or (onEight and n == 8)
				or (not onEight and n ~= 8 and (not group or ((n < 8) == (group == "low")))))
		end
		return legal
	end
	local function clearLine(balls, a, b, skipA, skipB)
		local delta = b - a
		local length2 = delta:Dot(delta)
		if length2 < 1e-10 then return false end
		local width = poolPhysics.Config.Radius * 2.03
		for i, ball in ipairs(balls) do
			if i ~= skipA and i ~= skipB and not ball.pocketed then
				local t = math.clamp((ball.p - a):Dot(delta) / length2, 0, 1)
				if (ball.p - (a + delta * t)).Magnitude < width then return false end
			end
		end
		return true
	end

	function state.PoolChances(balls, group, origin)
		local cue = origin or balls[1].p
		local legal = poolLegal(balls, group, false)
		local choices = {}
		local c = poolPhysics.Config
		for i = 2, 16 do
			if legal[i] then
				local ball = balls[i]
				for _, pocket in ipairs(poolPhysics.Pockets) do
					local toHole = pocket.hole - ball.p
					if toHole.Magnitude > c.Radius then
						local ghost = ball.p - toHole.Unit * (2 * c.Radius)
						local aim = ghost - cue
						if aim.Magnitude > 0.001 and ghost.X >= c.Radius and ghost.X <= c.Width - c.Radius
							and ghost.Z >= c.Radius and ghost.Z <= c.Height - c.Radius then
							local cut = aim.Unit:Dot(toHole.Unit)
							if cut > 0.18 and clearLine(balls, cue, ghost, 1, i) and clearLine(balls, ball.p, pocket.hole, 1, i) then
								local quality = cut * cut / (1 + aim.Magnitude + toHole.Magnitude)
								table.insert(choices, {angle = math.atan2(aim.Z, aim.X), Quality = quality,
									Distance = aim.Magnitude + toHole.Magnitude / math.max(cut * cut, 0.12), Ball = i})
							end
						end
					end
				end
			end
		end
		table.sort(choices, function(a, b) return a.Quality > b.Quality end)
		return choices[1] and choices[1].Quality or 0, choices
	end
	local function nextPoolState(s, plan, balls)
		local nextState = table.clone(s)
		nextState.balls, nextState.RawBalls = balls, {}
		nextState.breakShot, nextState.ballInHand, nextState.kitchen = false, false, false
		nextState.groups = table.clone(s.groups or {})

		if not groupFor(s) and not s.breakShot then
			for _, i in ipairs(plan.PocketedIndices or {}) do
				if i > 1 and i ~= 9 then
					nextState.groups[s.turn] = i < 9 and "low" or "high"
					nextState.groups[3 - s.turn] = i < 9 and "high" or "low"
					break
				end
			end
		end
		for i, b in ipairs(balls) do nextState.RawBalls[i] = {b.p.X, b.p.Z, b.pocketed or 0} end
		return nextState
	end
	local function caromQuality(balls, turn)
		local targets = #balls == 3 and {3, 3 - turn} or {3, 4}
		local cue = balls[turn].p
		local a, b = balls[targets[1]].p, balls[targets[2]].p
		local nearest = math.min((a - cue).Magnitude, (b - cue).Magnitude)
		local spread = (a - b).Magnitude
		return 1 / (1 + spread * 1.7 + math.abs(nearest - 0.45))
	end
	function state.BuildShotCandidates(s, selectedRemote, seed)
		local list, seen = {}, {}
		local style = state.Style or "balanced"
		local function add(p)
			if not p then return end
			local angle = math.atan2(math.sin(p.angle), math.cos(p.angle))
			local power = math.clamp(p.power, s.PoolMode and 0.05 or cueMotion.MinPower, 1)
			local side, top = math.clamp(p.side or 0, -0.65, 0.65), math.clamp(p.top or 0, -0.65, 0.65)
			local spinMagnitude = math.sqrt(side * side + top * top)
			if spinMagnitude > 0.65 then side, top = side * 0.65 / spinMagnitude, top * 0.65 / spinMagnitude end
			local tag = string.format("%.5f:%.4f:%.3f:%.3f", angle, power, side, top)
			if seen[tag] then return end
			seen[tag] = true
			table.insert(list, {angle = angle, power = power, side = side, top = top, cue = p.cue})
		end
		add(seed) __patchEarly(s, selectedRemote, seed, add, physicsFor, poolPhysics, groupFor, poolLegal, clearLine)
		if seed then
			for _, d in ipairs({-0.003, 0.003, -0.008, 0.008, 0}) do
				for _, scale in ipairs({0.92, 1.08, 1}) do
					add({angle = seed.angle + d, power = seed.power * scale, side = seed.side, top = seed.top, cue = seed.cue})
				end
			end
			for _, spin in ipairs({{0.15, 0}, {-0.15, 0}, {0, 0.15}, {0, -0.15}}) do
				local side, top = math.clamp(seed.side + spin[1], -0.6, 0.6), math.clamp(seed.top + spin[2], -0.6, 0.6)
				if Vector2.new(side, top).Magnitude <= 0.65 then
					add({angle = seed.angle, power = seed.power, side = side, top = top, cue = seed.cue})
				end
			end
		end
		if s.PoolMode then
			local origin = seed and seed.cue and Vector3.new(seed.cue[1], 0, seed.cue[2]) or s.balls[1].p
			local _, choices = state.PoolChances(s.balls, groupFor(s), origin)
			for i = 1, math.min(#choices, 10) do
				local choice = choices[i]
				local c = poolPhysics.Config
				local approximate = math.clamp(math.sqrt(2.8 * c.RollingFriction * c.Gravity * choice.Distance) / c.MaxSpeed, 0.13, 0.6)
				for _, multiplier in ipairs({1.25, 1.8, 2.5}) do
					add({angle = choice.angle, power = approximate * multiplier, side = 0, top = 0, cue = seed and seed.cue})
				end
			end

			local legal = poolLegal(s.balls, groupFor(s), s.breakShot)
			for i = 2, 16 do
				if legal[i] then
					local delta = s.balls[i].p - origin
					if delta.Magnitude > 0.001 then
						local angle = math.atan2(delta.Z, delta.X)
						local edge = math.asin(math.min(0.99, 2 * poolPhysics.Config.Radius / delta.Magnitude)) * 0.5
						for _, d in ipairs({0, -edge, edge}) do
							for _, power in ipairs({0.18, 0.3}) do add({angle = angle + d, power = power, side = 0, top = 0, cue = seed and seed.cue}) end
						end
					end
				end
			end
		else
			local physics = physicsFor(s, selectedRemote)
			local c, origin = physics.Config, s.balls[s.turn].p
			local targets = #s.balls == 3 and {3, 3 - s.turn} or {3, 4}
			for _, i in ipairs(targets) do
				local p = s.balls[i].p
				for _, target in ipairs({p, Vector3.new(2 * c.Radius - p.X, 0, p.Z),
					Vector3.new(2 * (c.Width - c.Radius) - p.X, 0, p.Z),
					Vector3.new(p.X, 0, 2 * c.Radius - p.Z), Vector3.new(p.X, 0, 2 * (c.Height - c.Radius) - p.Z)}) do
					local delta = target - origin
					local angle = math.atan2(delta.Z, delta.X)
					for _, power in ipairs({0.38, 0.6, 0.82}) do
						add({angle = angle, power = power, side = 0, top = 0.1})
					end
				end
			end
		end
		-- 스타일별 보조 후보
		__patchLate(s, seed, add) if seed and style == "chess" then
			for _, d in ipairs({-0.018, -0.010, 0.010, 0.018}) do
				add({angle = seed.angle + d, power = seed.power * 0.82, side = seed.side * 0.5, top = seed.top * 0.5, cue = seed.cue})
			end
		elseif seed and style == "alien" then
			-- Alien: 방어로 전환하지 않고 득점 가능한 모든 루트를 끝까지 탐색합니다.
			for _, d in ipairs({-0.20, -0.14, -0.085, -0.045, 0.045, 0.085, 0.14, 0.20}) do
				for _, spin in ipairs({{-0.55, 0.42}, {0.55, -0.42}, {-0.42, -0.55}, {0.42, 0.55}, {0, 0.48}, {0, -0.48}}) do
					add({angle = seed.angle + d, power = math.clamp(seed.power * 1.05, 0.05, 1), side = spin[1], top = spin[2], cue = seed.cue})
				end
			end
		elseif seed and style == "defense" then
			-- 같은 안전 수만 반복하지 않도록 각도·힘·회전 패턴을 분산합니다.
			for _, d in ipairs({-0.11, -0.065, -0.025, 0.025, 0.055, 0.095, 0.14}) do
				for _, scale in ipairs({0.46, 0.58, 0.72}) do
					local spin = d < 0 and -0.22 or 0.22
					add({angle = seed.angle + d, power = math.clamp(seed.power * scale, 0.05, 1), side = spin, top = d * 0.8, cue = seed.cue})
				end
			end
		elseif style == "attack" or style == "art" then
			-- 공격형·예술당구형: 기본 공격 루트는 동일하게 전부 탐색합니다.
			local baseAngle = seed and seed.angle or 0
			local baseCue = seed and seed.cue or nil
				local artFactor = math.clamp(((state.ThinkSeconds or 6) - 3) / 12, 0, 1)
				local artSteps = math.floor(36 + artFactor * 72)
				local powers = style == "art" and {0.24, 0.40, 0.56, 0.70, 0.84, 0.94} or {0.20, 0.32, 0.46, 0.62, 0.78, 0.92, 1.0}
			local spins = {{0, 0.10}, {0, 0.32}, {0.22, 0.22}, {-0.22, 0.22}, {0.42, -0.28}, {-0.42, -0.28}}
				for index = 0, (style == "art" and artSteps - 1 or 71) do
				local angle = baseAngle + index * math.pi * 2 / (style == "art" and artSteps or 72)
				for _, power in ipairs(powers) do
					for _, spin in ipairs(spins) do add({angle = angle, power = power, side = spin[1], top = spin[2], cue = baseCue}) end
				end
			end
			if seed then
				for _, scale in ipairs({1.05, 1.18, 1.32, 1.48}) do
					for _, d in ipairs({-0.035, -0.018, 0, 0.018, 0.035}) do
						add({angle = seed.angle + d, power = math.clamp(seed.power * scale, 0.08, 1), side = seed.side, top = math.max(seed.top, 0.12), cue = seed.cue})
					end
				end
			end
			if style == "art" then
				-- 극단 회전·끌어치기·밀어치기·두께 변화·쿠션 각도를 추가 탐색합니다.
					local artSpins = {{0, 0.72}, {0, -0.72}, {0.72, 0.35}, {-0.72, 0.35}, {0.58, -0.58}, {-0.58, -0.58}, {0.38, 0.78}, {-0.38, 0.78}}
					local artPowers = artFactor > 0.55 and {0.24, 0.38, 0.52, 0.66, 0.80, 0.92} or {0.30, 0.48, 0.68, 0.88}
					for index = 0, math.floor(48 + artFactor * 48) - 1 do
					local angle = baseAngle + index * math.pi * 2 / math.floor(48 + artFactor * 48)
					for _, power in ipairs(artPowers) do
						for _, spin in ipairs(artSpins) do add({angle = angle, power = power, side = spin[1], top = spin[2], cue = baseCue, ArtShot = true}) end
					end
				end
				if seed then
					for _, d in ipairs({-0.28, -0.16, -0.08, 0.08, 0.16, 0.28}) do
						for _, spin in ipairs(artSpins) do add({angle = seed.angle + d, power = math.clamp(seed.power * 1.08, 0.08, 1), side = spin[1], top = spin[2], cue = seed.cue, ArtShot = true}) end
					end
				end
			end
		end
		return list
	end
	function state.PlanSnapshot(s, selectedRemote, cancelled)
		assert(s and s.balls and s.turn, "계산할 경기 상태가 없습니다.")
		local started = os.clock()
		local remaining = s.turnDeadline and s.turnDeadline - workspace:GetServerTimeNow() - 2.2 or state.ThinkSeconds
		local budget = math.max(0, math.min(state.ThinkSeconds, remaining))
		if budget < 0.2 then return nil, "계산할 차례 시간이 부족합니다" end
		local deadline = started + budget
		local artFactor = math.clamp(((state.ThinkSeconds or 6) - 3) / 12, 0, 1)
		local finishWindow = false
		if s.PoolMode then
			local live = 0
			for i = 2, 16 do if s.balls[i] and not s.balls[i].pocketed then live = live + 1 end end
			finishWindow = live <= 2
		else
			local target = s.targetScore or (s.rules and s.rules.target) or 10
			local current = s.scores and tonumber(s.scores[s.turn]) or 0
			local finalThree = s.finalThreeCushion and s.finalThreeCushion[s.turn] == true
			-- 3구·4구·3쿠션 모두 목표점수 1점 전 또는 마지막 3쿠션 상태를 마무리로 봅니다.
			finishWindow = target - current <= 1 or finalThree
		end
		local function hardCancel() return not alive or (cancelled and cancelled()) end
		local function exhausted() return hardCancel() or os.clock() >= deadline end
		local function seedPlanRaw(limit, selectedState)
			local function stop() return hardCancel() or os.clock() >= limit end
			if selectedState.PoolMode then
				return poolAI.Plan(poolPhysics, {balls = selectedState.RawBalls, group = groupFor(selectedState),
					ballInHand = selectedState.ballInHand, kitchen = selectedState.kitchen == true or selectedState.breakShot == true,
					breakShot = selectedState.breakShot, level = state.Level}, {frameBudget = 0.003, cancelled = stop})
			end
			local three = #selectedState.balls == 3
			return ai.Plan(physicsFor(selectedState, selectedRemote), cueMotion, selectedState.balls, selectedState.turn,
				{targets = three and {3, 3 - selectedState.turn} or {3, 4}, threeCushions = three or
					(selectedState.finalThreeCushion and selectedState.finalThreeCushion[selectedState.turn] == true),
					level = state.Level, frameBudget = 0.003, cancelled = stop})
		end
		local seed = __patchSeed(seedPlanRaw, math.min(deadline, started + math.max(0.1, budget * 0.42)), s, poolAI, ai)
		if hardCancel() then return nil, "경기 상태 변경으로 계산 취소" end
		local candidates = state.BuildShotCandidates(s, selectedRemote, seed)
		local finalists, checked = {}, 0
		local function evaluateRaw(selectedState, shot, stop)
			if selectedState.PoolMode then return state.EvaluatePool(selectedState, shot, stop) end
			return state.EvaluateCarom(selectedState, selectedRemote, shot, stop)
		end
		local function evaluate(a, b, c) return __patchEval(evaluateRaw, a, b, c) end local firstDeadline = state.StrongPlay and started + budget * 0.78 or deadline
		for _, shot in ipairs(candidates) do
			if exhausted() or (checked > 0 and os.clock() >= firstDeadline) then break end
			local plan, balls, match = evaluate(s, shot, exhausted)
			checked = checked + 1
			if plan then
				local nextState = s.PoolMode and nextPoolState(s, plan, balls) or table.clone(s)
				local own, opponent
				if s.PoolMode then
					local group = groupFor(nextState)
					own = state.PoolChances(balls, group)
					opponent = state.PoolChances(balls, group and (group == "low" and "high" or "low") or nil)
				else
					nextState.balls, nextState.scores = balls, table.clone(match.scores)
					own, opponent = caromQuality(balls, s.turn), caromQuality(balls, 3 - s.turn)
				end
				local score = (plan.VerifiedWinner == s.turn and 100000 or 0) + plan.VerifiedScore * 1000
				local style = state.Style or "balanced"
				local opponentReply = opponent or 0
				if style == "alien" then
					-- Alien 공수 통합: 내 득점·연속득점과 상대 반격 차단을 동시에 평가합니다.
					local continuation = own * 1.35 + (plan.VerifiedScore > 0 and 0.55 or 0)
					local opponentThreat = opponent or 0
					local routeValue = math.abs(plan.side or 0) * 120 + math.abs(plan.top or 0) * 80 + math.abs(plan.power - 0.5) * 35
					-- 상대에게 바로 득점 루트를 남기는 후보는 공격 후보라도 강하게 배제합니다.
					local dangerousReply = opponentThreat > 0.22 and continuation < 0.95
					local opponentPenalty = opponentThreat * 5200 + (dangerousReply and 100000 or 0)
					score = score + continuation * 1250 - opponentPenalty + plan.VerifiedScore * 720 + routeValue
					plan.OpponentReply, plan.DangerousReply = opponentThreat, dangerousReply
					plan.Strategy = dangerousReply and "Alien 상대 득점 차단" or (opponentThreat > continuation and "Alien 반격 차단" or "Alien 공격·연속득점")
				elseif style == "attack" or style == "art" then
					-- 예술당구형도 공격형과 동일한 득점 평가를 기본으로 사용합니다.
					local attackValue = (plan.VerifiedWinner == s.turn and 250000 or 0) + plan.VerifiedScore * 9000 + own * 6500
					score = score + attackValue + plan.power * 420 + math.abs(plan.side or 0) * 80 + math.abs(plan.top or 0) * 60
					if style == "art" then
						local verifiedScore = plan.VerifiedScore > 0 or plan.VerifiedWinner == s.turn
						local technique = math.abs(plan.side or 0) * (300 + artFactor * 520) + math.abs(plan.top or 0) * (260 + artFactor * 480)
						local flourish = math.abs(math.sin(plan.angle * 5.7 + (plan.side or 0) * 8.3 + (plan.top or 0) * 6.1))
						local artBonus = verifiedScore and math.min(technique + flourish * (80 + artFactor * 180) + (plan.ArtShot and (100 + artFactor * 260) or 0), 1500 + artFactor * 2200) or -18000
						score = score + artBonus
						plan.Strategy = verifiedScore and "예술당구 기술구·예술구 득점 루트" or "득점 우선 · 예술구 보류"
					else
						plan.Strategy = "공격형 전력 득점 루트"
					end
				elseif style == "defense" then
					-- 득점 가능한 수는 먼저 선택하고, 득점이 어려울 때만 비예측 수비로 전환합니다.
					local canScore = plan.VerifiedScore > 0 or own > 0.34
					local unpredictability = math.abs(math.sin(plan.angle * 7.13 + plan.power * 11.7 + (plan.side or 0) * 19.1 + (plan.top or 0) * 13.7))
					if canScore then
						score = score + own * 920 + plan.VerifiedScore * 760 - opponent * 420 + unpredictability * 95
						plan.Strategy = "방어형 득점 우선"
					else
						score = score + own * 180 - opponent * 1480 + unpredictability * 260 - math.abs(plan.power - 0.42) * 8
						plan.Strategy = "방어형 비예측 차단"
					end
				elseif state.StrongPlay then
					score = score + own * 120 - opponent * (plan.VerifiedScore > 0 and 15 or 220)
				end
				if finishWindow then
					local finishScore = plan.VerifiedScore > 0 or plan.VerifiedWinner == s.turn
					local complexity = math.abs(plan.side or 0) * 1800 + math.abs(plan.top or 0) * 1600 + math.abs((plan.power or 0.5) - 0.62) * 900 + (plan.ArtShot and 1400 or 0)
					if finishScore then
						score = score + 90000 - complexity
					else
						score = score - 45000 - complexity * 0.25
					end
				end
				score = score - plan.power * 2 - math.abs(plan.side) * 0.8
				table.insert(finalists, {Plan = plan, State = nextState, Value = score, Own = own, Opponent = opponent})
				if not state.StrongPlay then break end
			end
		end
		if hardCancel() then return nil, "경기 상태 변경으로 계산 취소" end
		if #finalists == 0 then return nil, "제한시간 안에 검증된 합법 타격을 찾지 못했습니다" end
		if finishWindow then
			-- 마무리에서는 득점 후보가 하나라도 있으면 무득점 후보를 절대 선택하지 않습니다.
			local scoring = {}
			for _, item in ipairs(finalists) do
				local p = item.Plan
				local scored = p.VerifiedScore > 0 or p.VerifiedWinner == s.turn
				if scored then
					p.FinishScored = true
					item.Value = item.Value - (item.Opponent or 0) * 50000
					table.insert(scoring, item)
				end
			end
			if #scoring > 0 then finalists = scoring end
		end
		table.sort(finalists, function(a, b) return a.Value > b.Value end)
		local legalCount = #finalists
		local deeper, robustChecks = 0, 0
		while #finalists > 3 do table.remove(finalists) end
		if state.StrongPlay then

			for i = 1, math.min(3, #finalists) do
				if exhausted() then break end
				local item = finalists[i]
				local safe, scored, trials = 0, 0, 0
				local limit = math.min(deadline, os.clock() + math.min(0.35, budget * 0.045))
				local function stop() return hardCancel() or os.clock() >= limit end
				for _, error in ipairs({{-0.0008, 0.98}, {0.0008, 1.02}}) do
					if stop() then break end
					local p = table.clone(item.Plan)
					p.angle, p.power = p.angle + error[1], math.clamp(p.power * error[2], s.PoolMode and 0.05 or cueMotion.MinPower, 1)
					local result, reason = evaluate(s, p, stop)
					if stop() and not result then break end
					trials, robustChecks = trials + 1, robustChecks + 1
					if result then
						safe = safe + 1
						if result.VerifiedScore >= item.Plan.VerifiedScore and result.VerifiedWinner == item.Plan.VerifiedWinner then scored = scored + 1 end
					end
				end
				if trials > 0 then
					item.Plan.RobustTrials, item.Plan.RobustSafe = trials, safe
					item.Value = item.Value - (1 - safe / trials) * 1500 - (1 - scored / trials) * 180
				end
			end
			table.sort(finalists, function(a, b) return a.Value > b.Value end)

			for i = 1, math.min(3, #finalists) do
				if exhausted() then break end
				local item = finalists[i]
				if item.Plan.VerifiedWinner ~= s.turn then
					local nextState = table.clone(item.State)
					local attack = item.Plan.VerifiedScore > 0
					if not attack then nextState.turn = 3 - s.turn end
					local limit = math.min(deadline, os.clock() + math.min(0.65, budget * 0.09))
					local function stop() return hardCancel() or os.clock() >= limit end
					local options = state.BuildShotCandidates(nextState, selectedRemote, nil)
					local nextBest = 0
					for j = 1, math.min(#options, 8) do
						if stop() then break end
						local nextPlan = evaluate(nextState, options[j], stop)
						deeper = deeper + 1
						if nextPlan then nextBest = math.max(nextBest, nextPlan.VerifiedWinner == nextState.turn and 3 or nextPlan.VerifiedScore) end
					end
					item.Plan.NextVerifiedScore = nextBest
					item.Value = item.Value + nextBest * (attack and 160 or -240)
				end
			end
		end
		if hardCancel() then return nil, "경기 상태 변경으로 계산 취소" end
		table.sort(finalists, function(a, b) return a.Value > b.Value end)
		local best = finalists[1]
		if state.Style ~= "art" or best.Plan.VerifiedScore <= 0 then best.Plan.Strategy = best.Plan.VerifiedWinner == s.turn and (finishWindow and "안정적 마무리 득점·상대 기회 차단" or "승리 경로") or (best.Plan.VerifiedScore > 0 and "득점·다음 배치" or "상대 기회 억제 수비") end
		best.Plan.SearchCandidates, best.Plan.SearchSeconds = checked, os.clock() - started
		state.LastSearch = {Candidates = checked, Legal = legalCount, NextChecks = deeper, RobustChecks = robustChecks, Seconds = os.clock() - started,
			Strategy = best.Plan.Strategy, NextQuality = best.Own, OpponentThreat = best.Opponent}
		return best.Plan
	end
	local cueStandModule = require(modules:WaitForChild("CueStand", 10))
	local originalCueNew = cueStandModule.new
	local cueNewWrapper
	local cueRecords, cueSeen = {}, {}
	local smoothStage, bypassUntil = nil, 0
	local lastCueDiscovery = 0
	local aimRandom = Random.new()
	state.SmoothFrames = 0
	local function ease(t)
		t = math.clamp(t, 0, 1)
		return t * t * (3 - 2 * t)
	end
	local function attachCue(stand, config, pool)
		if type(stand) ~= "table" or cueSeen[stand] or type(stand.place) ~= "function" or type(stand.frameAt) ~= "function" then return end
		cueSeen[stand] = true
		local record = {Stand = stand, Config = config, Pool = pool, Original = stand.place, Frames = {}, Times = {}}
		local function wrapper(seat, frame, hidden, ...)
			if alive and state.SmoothCue and snapshot and myTurn(snapshot) and seat == snapshot.turn
				and state.Enabled and record.Pool == (snapshot.PoolMode == true) and typeof(frame) == "CFrame" then
				local now = os.clock()
				local stage = smoothStage
				if stage and stage.Generation == generation and stage.Key == key(snapshot) and stage.Remote == remote and not (snapshot.LocalMoving or snapshot.moving or snapshot.striking) then
					local configNow = record.Config or stage.Config
					local shown = state.SampleAimSequence(stage.Sequence, now - stage.At)

					frame = stand.frameAt(configNow, stage.Position, shown.angle, shown.side, shown.top,
						cueMotion.TipGap + shown.power * cueMotion.PullDistance)
					hidden = false
					state.SmoothFrames = state.SmoothFrames + 1
				elseif now >= bypassUntil and ready(snapshot) and not hidden then
					local previous = record.Frames[seat]
					local dt = math.min(now - (record.Times[seat] or now), 0.1)
					if previous and dt > 0 then frame = previous:Lerp(frame, 1 - math.exp(-16 * dt)) end
				end
				record.Frames[seat], record.Times[seat] = frame, now
			else
				record.Frames[seat], record.Times[seat] = frame, os.clock()
			end
			local ok, result = pcall(record.Original, seat, frame, hidden, ...)
			if not ok then state.SmoothError = tostring(result); return nil end
			return result
		end
		record.Wrapper = wrapper
		record.OriginalFrameAt = stand.frameAt
		record.FrameWrapper = function(configNow, position, angle, ...)
			if not smoothStage then record.Angle = angle end
			local ok, result = pcall(record.OriginalFrameAt, configNow, position, angle, ...)
			if ok then return result end
			return CFrame.new()
		end
		stand.frameAt = record.FrameWrapper
		stand.place = wrapper
		table.insert(cueRecords, record)
		state.CueBindings = #cueRecords
	end
	local function discoverCues()
		if type(getconnections) ~= "function" or type(debug.getupvalues) ~= "function" or type(getfenv) ~= "function" then
			state.SmoothError = "현재 실행기에서 기존 큐대 연결 조회를 지원하지 않습니다."
			return
		end
		local visited = {}
		local function visit(fn, depth, pool)
			if depth > 2 or visited[fn] then return end
			visited[fn] = true
			local ok, values = pcall(debug.getupvalues, fn)
			if not ok then return end
			for _, value in pairs(values) do
				if type(value) == "table" then
					attachCue(value.stand or value, value.config, pool)
					if type(value.angle) == "number" and type(value.power) == "number" and value.sentAt ~= nil then
						state.ClientAim = value
					end
					for _, child in pairs(value) do
						if type(child) == "function" then visit(child, depth + 1, pool) end
					end
				elseif type(value) == "function" then visit(value, depth + 1, pool) end
			end
		end
		for _, signal in ipairs({runService.RenderStepped, runService.Heartbeat}) do
			for _, connection in ipairs(getconnections(signal)) do
				local fn = connection.Function
				if type(fn) == "function" then
					local ok, context = pcall(getfenv, fn)
					local owner = ok and context.script
					if owner and (owner.Name == "PocketBallClient" or owner.Name == "FourBallClient") then visit(fn, 0, owner.Name == "PocketBallClient") end
				end
			end
		end
	end
	cueNewWrapper = function(options, ...)
		local stand = originalCueNew(options, ...)
		local area = options.area
		local isPool = options.parent and options.parent.Name == "PocketBallCues"
		if not isPool and area and area.Parent then isPool = string.find(area.Parent.Name, "Pocket", 1, true) ~= nil end
		attachCue(stand, nil, isPool == true)
		return stand
	end
	cueStandModule.new = cueNewWrapper
	discoverCues()

	function state.CreateAimSequence(plan, fromAngle, budget)
		local sequence = {Duration = 0, Phases = {}}
		local current = {angle = fromAngle, power = 0, side = 0, top = 0}
		budget = math.max(0, budget)
		local finalSeconds = math.min(math.clamp(state.AimSeconds, 0.4, 2), budget)
		local extra = math.min(math.max(0, budget - finalSeconds), 3.2)
		local function add(target, duration, label)
			local delta = math.atan2(math.sin(target.angle - current.angle), math.cos(target.angle - current.angle))
			local nextValue = {angle = current.angle + delta, power = target.power, side = target.side, top = target.top}
			table.insert(sequence.Phases, {From = current, To = nextValue, At = sequence.Duration, Duration = duration, Label = label})
			sequence.Duration = sequence.Duration + duration
			current = nextValue
		end
		if state.HumanThinking and extra >= 1.25 then
			local sign = aimRandom:NextNumber() < 0.5 and -1 or 1
			local offset = math.rad(aimRandom:NextNumber(7, 19)) * sign
			local count = extra >= 2.2 and aimRandom:NextInteger(1, 2) or 1
			local used = math.min(extra, aimRandom:NextNumber(1.4, 2.0) + (count - 1) * 0.9)
			for i = 1, count do
				local target = {angle = plan.angle + offset, power = plan.power * aimRandom:NextNumber(0.12, 0.35), side = 0, top = 0}
				add(target, used / count * 0.68, i == 1 and "다른 방향 살펴보는 중" or "반대쪽 방향도 살펴보는 중")
				add(current, used / count * 0.32, "잠깐 멈춰 방향 검토 중")
				offset = -offset * aimRandom:NextNumber(0.55, 0.9)
			end
		end
		add(plan, finalSeconds, "방향 결정 · 최종 조준 중")
		return sequence
	end
	function state.SampleAimSequence(sequence, elapsed)
		local phases = sequence.Phases
		local phase = phases[#phases]
		local index = #phases
		for i, candidate in ipairs(phases) do
			if elapsed < candidate.At + candidate.Duration then phase, index = candidate, i break end
		end
		local u = phase.Duration > 0 and ease((elapsed - phase.At) / phase.Duration) or 1
		local a, b = phase.From, phase.To
		return {angle = a.angle + (b.angle - a.angle) * u, power = a.power + (b.power - a.power) * u,
			side = a.side + (b.side - a.side) * u, top = a.top + (b.top - a.top) * u}, index
	end
	function state.AnimateAim(plan, selectedState, selected, cancelled)
		if cancelled() then return false end
		if not state.SmoothCue then task.wait(0.25) return not cancelled() end
		local physics = physicsFor(selectedState, selected)
		local config = table.clone(physics.Config)
		config.CushionHeight = config.CushionHeight or 0
		config.RailTopRadius = config.RailTopRadius or cueMotion.RailTopRadius
		local cue = selectedState.balls[selectedState.PoolMode and 1 or selectedState.turn]
		local position = plan.cue and Vector3.new(plan.cue[1], 0, plan.cue[2]) or cue.p
		local fromAngle = selectedState.PoolMode and state.ClientAim and state.ClientAim.angle or state.LastAimAngle or plan.angle
		for _, record in ipairs(cueRecords) do
			if record.Pool == (selectedState.PoolMode == true) and record.Angle ~= nil
				and record.Stand.frames and record.Stand.frames[selectedState.turn] then fromAngle = record.Angle break end
		end

		local budget = math.max(0, math.min(4.5, (selectedState.turnDeadline or 0) - workspace:GetServerTimeNow() - 1.2))
		local sequence = state.CreateAimSequence(plan, fromAngle, budget)
		local stage = {Key = key(selectedState), Remote = selected, Position = position,
			Generation = generation, Config = config, At = os.clock(), Sequence = sequence}
		smoothStage = stage
		local lastSend, lastPhase = -math.huge, nil
		while true do
			if cancelled() then if smoothStage == stage then smoothStage = nil end return false end
			local now = os.clock()
			local elapsed = now - stage.At
			local shown, phase = state.SampleAimSequence(sequence, elapsed)
			if lastPhase ~= phase then lastPhase = phase setStatus(sequence.Phases[phase].Label) end
			if now - lastSend >= 0.11 then
				lastSend = now
				selected:FireServer("aim", {turnId = selectedState.turnId, angle = shown.angle,
					power = shown.power, side = shown.side, top = shown.top, cue = plan.cue,
					pulling = phase == #sequence.Phases and shown.power > plan.power * 0.45})
				if elapsed >= sequence.Duration then break end
			end
			runService.RenderStepped:Wait()
		end
		state.LastAimAngle = plan.angle
		bypassUntil = os.clock() + 0.6
		return not cancelled()
	end
	local function resolvePending(s)
		if not pending then return end
		if s.round ~= pending.round then pending = nil return end
		if (s.shots or 0) > pending.shots then
			state.ShotsAccepted = state.ShotsAccepted + 1
			state.LastReceipt = {Accepted = true, TurnId = pending.turnId, Shots = s.shots}
			pending = nil
		elseif s.turnId ~= pending.turnId then
			state.LastReceipt = {Accepted = false, TurnId = pending.turnId}
			pending = nil
		end
	end
	local function bind(selectedRemote)
		smoothStage = nil
		state.LastAimAngle = nil
		discoverCues()
		generation = generation + 1
		if listener then listener:Disconnect() end
		remote, snapshot, pending, attempted, plannedKey = selectedRemote, nil, nil, nil, nil
		state.Remote = selectedRemote and selectedRemote:GetFullName() or nil
		state.LastPlan = nil
		readyAt = nil
		if not selectedRemote then setStatus("포켓볼·4구·3구 경기에 입장하세요") return end
		listener = selectedRemote.OnClientEvent:Connect(function(kind, payload)
			if not alive or remote ~= selectedRemote then return end
			local isPool = selectedRemote.Parent and selectedRemote.Parent.Name == "PocketBallEvents"
			if isPool and kind == "shot" and type(payload) == "table" then
				if snapshot and payload.round == snapshot.round then snapshot.LocalMoving = true end
				if pending and snapshot and payload.round == pending.round and payload.shooter == snapshot.turn and (payload.turnId == nil or payload.turnId == pending.turnId) then
					state.ShotsAccepted = state.ShotsAccepted + 1
					state.LastReceipt = {Accepted = true, TurnId = pending.turnId, Seq = payload.seq}
					pending = nil
				end
				return
			end
			if isPool and kind == "result" and type(payload) == "table" and type(payload.result) == "table" then kind, payload = "state", payload.result end
			if kind == "state" and type(payload) == "table" then
				if isPool then payload = normalizePool(payload) end
				if snapshot and type(payload.sequence) == "number" and payload.sequence <= (snapshot.sequence or -1) then return end
				if payload.slim then
					if not snapshot then return end
					local merged = table.clone(snapshot)
					for k, v in pairs(payload) do merged[k] = v end
					merged.slim, merged.stale = nil, true
					snapshot = merged
				else snapshot = payload end
				state.Snapshot = snapshot
				resolvePending(snapshot)
				if not state.Enabled and not state.Error then setStatus("준비 완료 · 자동 플레이를 켜세요") end
			elseif kind == "error" or kind == "denied" then
				state.Error = tostring(payload)
				pause("타격 거부: " .. state.Error)
			end
		end)
		lastSync = os.clock()
		selectedRemote:FireServer("sync")
	end
	function state.SetStyle(value)
		local styles = {basic = {name = "기본형", level = 4, think = 10}, balanced = {name = "균형형", level = 4, think = 10}, chess = {name = "체스형", level = 5, think = 14}, alien = {name = "Alien", level = 5, think = 15}, attack = {name = "공격형", level = 6, think = 15}, art = {name = "예술당구형", level = 5, think = 6}, defense = {name = "방어형", level = 5, think = 13}}
		local preset = styles[value] or styles.balanced
		state.Style = styles[value] and value or "balanced"
		state.StyleName, state.Level, state.ThinkSeconds = preset.name, preset.level, preset.think
		state.LastPlan = nil
		if statusLabel then setStatus("스타일 변경: " .. state.StyleName .. " · 다음 차례부터 적용") end
	end
	function state.SetSmoothCue(value)
		state.SmoothCue = value == true
		state.SmoothCuePreference = state.SmoothCue
		if not state.SmoothCue then smoothStage = nil end
		if statusLabel then setStatus(state.SmoothCue and "부드러운 큐대 이동 유지" or "큐대 즉시 이동") end
	end
	function state.SetEnabled(value)
		if not alive then return end
		state.Enabled = value == true
		generation = generation + 1
		state.Error = nil
		smoothStage = nil
		if state.Enabled then plannedKey, readyAt = nil, nil end
		if toggle then toggle:Set(state.Enabled, true) end
		setStatus(state.Enabled and "자동 플레이 대기 중" or "자동 플레이 중지")
	end
	function state.Stop()
		if not alive then return end
		alive = false
		state.Enabled = false
		generation = generation + 1
		if listener then listener:Disconnect() end
		if heartbeat then heartbeat:Disconnect() end
		if window then local old = window window = nil state.Window = nil clearBackdrop() old:Destroy() end
		if cueStandModule.new == cueNewWrapper then cueStandModule.new = originalCueNew end
		for _, record in ipairs(cueRecords) do
			if record.Stand.place == record.Wrapper then record.Stand.place = record.Original end
			if record.Stand.frameAt == record.FrameWrapper then record.Stand.frameAt = record.OriginalFrameAt end
		end
		smoothStage = nil
		if preview then preview.Stop() end
		if env.BilliardsSuite == state then env.BilliardsSuite = nil end
		if env.BilliardsAuto == state then env.BilliardsAuto = nil end
	end
	local function tick()
		if not alive or os.clock() - lastTick < 0.2 then return end
		lastTick = os.clock()
		local events = modules:FindFirstChild("TableEvents")
		local name = player:GetAttribute("BilliardsMatch")
		local poolEvents = modules:FindFirstChild("PocketBallEvents")
		local selectedRemote = type(name) == "string" and ((poolEvents and poolEvents:FindFirstChild(name)) or (events and events:FindFirstChild(name))) or nil
		if selectedRemote ~= remote then bind(selectedRemote) end
		-- 라운드가 바뀌거나 새 큐대 객체가 만들어져도 SmoothCue 연결을 유지합니다.
		state.SmoothCue = state.SmoothCuePreference == true
		if state.SmoothCue and os.clock() - lastCueDiscovery > 1.5 then
			lastCueDiscovery = os.clock(); pcall(discoverCues)
		end
		if not remote then
			state.Mode = "경기 없음"
			if modeLabel then modeLabel:SetText("포켓볼·4구·3구 자동 감지 · 경기 입장 대기") end
			return
		end
		if snapshot then
			local three = snapshot.threeBall == true or (snapshot.rules and snapshot.rules.threeBall == true)
			state.Mode = snapshot.PoolMode and "포켓볼(8볼)" or (three and "3구" or "4구")
			local final = snapshot.finalThreeCushion and snapshot.finalThreeCushion[snapshot.turn]
			if modeLabel then modeLabel:SetText("현재 모드: " .. state.Mode .. (snapshot.PoolMode and " · 공 종류·8번 공 규칙" or ((three or final) and " · 3쿠션 규칙" or " · 일반 득점 규칙"))) end
			if statsLabel then
				statsLabel:SetText(string.format("타격 %d회 · 서버 확인 %d회 · 경로 %d개", state.ShotsSent, state.ShotsAccepted, preview.Segments))
			end
		end
		if pending then
			if os.clock() - pending.at > 5 then
				state.Error = "서버 타격 확인 없음"
				pause("타격 결과 미확인: 상태를 확인한 후 다시 켜세요")
			end
			return
		end
		if snapshot and snapshot.stale and not snapshot.moving and os.clock() - lastSync > 2 then
			lastSync = os.clock()
			remote:FireServer("sync")
		end
		if not state.Enabled then return end
		if not ready(snapshot) then
			readyAt = nil
			setStatus(snapshot and snapshot.phase == "finished" and "경기 종료" or "내 차례와 공 정지 대기 중")
			return
		end
		local shotKey = key(snapshot)
		if attempted == shotKey or plannedKey == shotKey or state.Thinking then return end
		if not readyAt then readyAt = os.clock() return end
		if os.clock() - readyAt < 0.7 then return end
		local selectedState, selected = snapshot, remote
		local token = generation
		plannedKey = shotKey
		state.Thinking = true
		setStatus("각도·힘·회전 계산 및 파울 검사 중")
		task.spawn(function()
			local function cancelled()
				return not alive or not state.Enabled or generation ~= token or remote ~= selected
					or not snapshot or key(snapshot) ~= shotKey or not ready(snapshot)
			end
			local ok, plan, reason = pcall(state.PlanSnapshot, selectedState, selected, cancelled)
			state.Thinking = false
			if cancelled() then return end
			if not ok then state.Error = tostring(plan) pause("계산 오류: " .. state.Error) return end
			if not plan then setStatus(reason or "가능한 타격을 찾지 못했습니다") return end
			state.LastPlan = plan
			if preview.Enabled then
				preview.DrawPlan(physicsFor(selectedState, selected), selectedState.balls, selectedState.PoolMode and 1 or selectedState.turn, plan)
			end
			setStatus("목표 방향으로 부드럽게 조준 중")
			local aimOK, aimed = pcall(state.AnimateAim, plan, selectedState, selected, cancelled)
			if not aimOK then smoothStage = nil state.Error = tostring(aimed) pause("조준 이동 오류: " .. state.Error) return end
			if not aimed or cancelled() then smoothStage = nil return end

			smoothStage = nil
			attempted = shotKey
			normalizePlanSpin(plan)
			pending = {round = snapshot.round, turnId = snapshot.turnId, shots = snapshot.shots or 0, at = os.clock()}
			local sent, err = pcall(function()
				selected:FireServer("shoot", {turnId = snapshot.turnId, angle = plan.angle,
					power = plan.power, side = plan.side, top = plan.top, cue = plan.cue,
					impactAt = workspace:GetServerTimeNow() + (cueMotion.StrokeTime or 0.18)})
			end)
			if not sent then state.Error = tostring(err) pause("타격 전송 오류: " .. state.Error) return end
			state.ShotsSent = state.ShotsSent + 1
			setStatus(string.format("타격 전송 %d회 · 서버 확인 대기", state.ShotsSent))
		end)
	end
	preview.OnPoolGuide = function(data)
		if not snapshot or not snapshot.PoolMode or snapshot.LocalMoving or not data or not data.start or not data.contact then return end
		local direction = data.contact - data.start
		if direction.Magnitude < 0.0001 then return end
		local cueLength = data.cueLine and (data.cueLine[2] - data.cueLine[1]).Magnitude or 0
		local objectLength = data.objectLine and (data.objectLine[2] - data.objectLine[1]).Magnitude or 0
		local power = math.clamp(math.sqrt(cueLength * cueLength + objectLength * objectLength) / (6 * poolPhysics.Config.Radius), 0.05, 1)
		local plan = {angle = math.atan2(direction.Z, direction.X), power = power, side = 0, top = 0,
			cue = {data.start.X, data.start.Z}, BreakBoost = snapshot.breakShot and poolPhysics.Config.BreakBoost or 1}
		preview.DrawPlan(poolPhysics, snapshot.balls, 1, plan)
		preview.HoldUntil = 0
	end
	env.BilliardsAuto = state
	env.BilliardsSuite = state
	local backdropLayer, backdropParts = nil, {}
	local backdropTheme = "Crystal"
	local backdropClock = 0
	local function clearBackdrop()
		if backdropLayer then backdropLayer:Destroy() end
		backdropLayer, backdropParts = nil, {}
	end
	local function buildBackdrop(themeName)
		clearBackdrop()
		backdropTheme = themeName or "Crystal"
		if not window or not window.Alive or not window._workspace then return end
		backdropLayer = Instance.new("Frame")
		backdropLayer.Name = "DecorativeBackground"
		backdropLayer.BackgroundTransparency = 1
		backdropLayer.BorderSizePixel = 0
		backdropLayer.Size = UDim2.fromScale(1, 1)
		backdropLayer.Position = UDim2.fromScale(0, 0)
		backdropLayer.ZIndex = 0
		backdropLayer.Active = false
		backdropLayer.Parent = window._workspace
		local accent, secondary = window.Theme.Accent, window.Theme.Secondary
		local animated = {}
		local function make(className, props, parent)
			local node = Instance.new(className)
			for key, value in pairs(props) do node[key] = value end
			node.Parent = parent or backdropLayer
				-- 모든 배경 레이어를 기본 애니메이션에 등록합니다.
				if node:IsA("GuiObject") then
					local pos = props.Position or UDim2.new(0, 0, 0, 0)
					animated[#animated + 1] = {node = node, kind = "generic", x = pos.X.Scale, xo = pos.X.Offset, y = pos.Y.Scale, yo = pos.Y.Offset, rotation = props.Rotation or 0, phase = #animated * 0.47, speed = 0.10 + (#animated % 9) * 0.018, amp = node.Name == "FullScreenAtmosphere" and 0 or 0.0025 + (#animated % 4) * 0.0015, rotAmp = node.Name == "FullScreenAtmosphere" and 0 or 0.8 + (#animated % 5) * 0.35, baseTransparency = props.BackgroundTransparency}
				end
			return node
		end
		local function pill(node, radius)
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(1, radius or 0)
			c.Parent = node
		end
		local function addAnimated(node, kind, data)
				for i = #animated, 1, -1 do if animated[i].node == node then table.remove(animated, i) end end
			data = data or {}; data.node, data.kind = node, kind
			animated[#animated + 1] = data
		end
		-- 공통 전면 베이스: 빈 공간 없이 화면 전체를 덮습니다.
		make("Frame", {Name = "FullScreenAtmosphere", Size = UDim2.fromScale(1, 1), BackgroundColor3 = window.Theme.Canvas, BackgroundTransparency = 0.04, BorderSizePixel = 0, ZIndex = 0})

		if backdropTheme == "Tidal" then
			local bands = {
				{0.00, 0.22, Color3.fromRGB(4, 20, 42), 0.02}, {0.16, 0.25, Color3.fromRGB(5, 39, 63), 0.04},
				{0.34, 0.27, Color3.fromRGB(6, 66, 83), 0.07}, {0.53, 0.28, Color3.fromRGB(5, 94, 104), 0.10},
				{0.73, 0.30, Color3.fromRGB(2, 126, 128), 0.14},
			}
			for i, band in ipairs(bands) do make("Frame", {Name = "OceanLayer" .. i, Size = UDim2.new(1, 0, band[2], 0), Position = UDim2.new(0, 0, band[1], 0), BackgroundColor3 = band[3], BackgroundTransparency = band[4], BorderSizePixel = 0, ZIndex = 0}) end
			-- 상단부터 전경까지 20겹으로 채워 상단 빈 공간을 없앱니다.
			for wave = 1, 20 do
				local depth = (wave - 1) / 19
				local row = make("Frame", {Name = "TidalWaveLayer" .. wave, Size = UDim2.new(1.34, 0, 0.17 + depth * 0.18, 0), Position = UDim2.new(-0.17, 0, -0.015 + depth * 0.82, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 1})
				local count, amplitude = 48, 0.022 + depth * 0.10
				for i = 1, count do
					local phase = i * (0.34 + depth * 0.07) + wave * 0.73
					local node = make("Frame", {Name = "Ripple", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0.032 + depth * 0.012, 0, 0, math.max(2, 8 - wave * 0.20)), Position = UDim2.new((i - 0.5) / count, 0, 0.5 + math.sin(phase) * amplitude, 0), Rotation = math.cos(phase) * (11 - depth * 5), BackgroundColor3 = wave % 3 == 0 and accent or (wave % 3 == 1 and secondary or Color3.fromRGB(62, 196, 201)), BackgroundTransparency = 0.66 + depth * 0.018, BorderSizePixel = 0, ZIndex = 1}, row)
					pill(node)
					addAnimated(node, "wave", {phase = phase, base = -0.015 + depth * 0.82 + 0.5 * (0.17 + depth * 0.18), amp = amplitude, x = (i - 0.5) / count, speed = 0.12 + depth * 0.42})
					if i % (wave < 8 and 6 or 12) == 0 then
						local foam = make("Frame", {Name = "Foam", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0.022 + depth * 0.012, 0, 0, math.max(1, 4 - depth * 2)), Position = UDim2.new((i - 0.5) / count, 0, 0.48 + math.sin(phase) * amplitude, 0), BackgroundColor3 = Color3.fromRGB(208, 255, 251), BackgroundTransparency = 0.50 + depth * 0.025, BorderSizePixel = 0, ZIndex = 2}, row)
						pill(foam)
						addAnimated(foam, "foam", {phase = phase, base = -0.035 + depth * 0.82 + 0.5 * (0.17 + depth * 0.18), amp = amplitude, x = (i - 0.5) / count, speed = 0.12 + depth * 0.42})
					end
				end
			end
			for i = 1, 130 do
				local bubble = make("Frame", {Name = "Bubble", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(1 + i % 5, 1 + i % 5), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.371) % 1, 0), BackgroundColor3 = i % 3 == 0 and Color3.fromRGB(218, 255, 251) or accent, BackgroundTransparency = 0.38 + (i % 5) * 0.09, BorderSizePixel = 0, ZIndex = 2})
				pill(bubble); addAnimated(bubble, "bubble", {seed = i, x = (i * 0.618) % 1, speed = 0.008 + (i % 7) * 0.002})
			end
		elseif backdropTheme == "Crystal" or backdropTheme == "Aurora" then
			for layer = 1, 11 do
				make("Frame", {Name = "GlassLayer" .. layer, Size = UDim2.new(1.45, 0, 0.34, 0), Position = UDim2.new(-0.22, 0, -0.08 + layer * 0.095, 0), Rotation = -22 + layer * 4, BackgroundColor3 = layer % 2 == 0 and accent or secondary, BackgroundTransparency = 0.945 + layer * 0.003, BorderSizePixel = 0, ZIndex = 0})
			end
			for i = 1, 65 do
				local shard = make("Frame", {Name = "Prism", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2 + i % 5, 60 + i % 13 * 15), Position = UDim2.new((i * 0.137) % 1, 0, (i * 0.217) % 1, 0), Rotation = -60 + (i * 17) % 120, BackgroundColor3 = i % 3 == 0 and Color3.fromRGB(240, 255, 255) or accent, BackgroundTransparency = 0.84 + (i % 5) * 0.022, BorderSizePixel = 0, ZIndex = 1})
				pill(shard)
			end
			for i = 1, 32 do
				local glint = make("Frame", {Name = "Glint", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2 + i % 4, 2 + i % 4), Position = UDim2.new((i * 0.271) % 1, 0, (i * 0.413) % 1, 0), Rotation = 45, BackgroundColor3 = Color3.fromRGB(245, 255, 255), BackgroundTransparency = 0.30 + (i % 5) * 0.10, BorderSizePixel = 0, ZIndex = 2})
				pill(glint)
			end
		elseif backdropTheme == "Crimson" or backdropTheme == "Ember" then
			for layer = 1, 14 do
				local glow = make("Frame", {Name = "HeatLayer" .. layer, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0.72 + layer * 0.055, 0, 0.23 + layer * 0.025, 0), Position = UDim2.new((layer * 0.37) % 1, 0, (layer * 0.113) % 1, 0), Rotation = -18 + layer * 5, BackgroundColor3 = layer % 2 == 0 and accent or secondary, BackgroundTransparency = 0.935, BorderSizePixel = 0, ZIndex = 0})
				pill(glow)
			end
			for i = 1, 150 do
				local spark = make("Frame", {Name = "Spark", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2 + i % 5, 3 + i % 7), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.347) % 1, 0), Rotation = -30 + (i * 19) % 60, BackgroundColor3 = i % 4 == 0 and Color3.fromRGB(255, 235, 150) or accent, BackgroundTransparency = 0.32 + (i % 5) * 0.09, BorderSizePixel = 0, ZIndex = 2})
				pill(spark); addAnimated(spark, "spark", {seed = i, x = (i * 0.618) % 1, y = (i * 0.347) % 1, speed = 0.018 + (i % 6) * 0.005})
			end
		end
		if backdropTheme == "Space" then
			for layer = 1, 12 do make("Frame", {Name = "NebulaBand" .. layer, Size = UDim2.new(1.55, 0, 0.20, 0), Position = UDim2.new(-0.25, 0, -0.10 + layer * 0.115, 0), Rotation = -24 + layer * 4, BackgroundColor3 = layer % 2 == 0 and Color3.fromRGB(120, 66, 232) or Color3.fromRGB(25, 130, 235), BackgroundTransparency = 0.925, BorderSizePixel = 0, ZIndex = 0}) end
			for i = 1, 300 do
				local star = make("Frame", {Name = "Star", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(1 + i % 4, 1 + i % 4), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.371) % 1, 0), BackgroundColor3 = i % 7 == 0 and Color3.fromRGB(173, 217, 255) or Color3.fromRGB(245, 249, 255), BackgroundTransparency = 0.12 + (i % 7) * 0.10, BorderSizePixel = 0, ZIndex = 2})
				pill(star); addAnimated(star, "star", {seed = i, base = (i * 0.371) % 0.96, x = (i * 0.618) % 1, speed = 0.014 + (i % 5) * 0.005})
			end
			for planet = 1, 5 do
				local orb = make("Frame", {Name = "Planet" .. planet, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(48 + planet * 25, 48 + planet * 25), Position = UDim2.new(0.08 + planet * 0.20, 0, 0.15 + (planet % 3) * 0.29, 0), BackgroundColor3 = planet % 2 == 0 and Color3.fromRGB(102, 68, 211) or Color3.fromRGB(35, 143, 220), BackgroundTransparency = 0.32, BorderSizePixel = 0, ZIndex = 1})
				pill(orb)
				local ring = Instance.new("UIStroke"); ring.Color = planet % 2 == 0 and Color3.fromRGB(230, 174, 255) or Color3.fromRGB(101, 229, 255); ring.Transparency = 0.35; ring.Thickness = 2; ring.Parent = orb
			end
		elseif backdropTheme == "Cyber" then
			for i = 1, 26 do make("Frame", {Name = "GridV" .. i, Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new((i - 1) / 25, 0, 0, 0), BackgroundColor3 = accent, BackgroundTransparency = 0.91, BorderSizePixel = 0, ZIndex = 1}) end
			for i = 1, 18 do make("Frame", {Name = "GridH" .. i, Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, (i - 1) / 17, 0), BackgroundColor3 = secondary, BackgroundTransparency = 0.91, BorderSizePixel = 0, ZIndex = 1}) end
			for i = 1, 90 do
				local node = make("Frame", {Name = "DataNode", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2 + i % 4, 2 + i % 4), Position = UDim2.new((i * 0.271) % 1, 0, (i * 0.413) % 1, 0), BackgroundColor3 = i % 2 == 0 and accent or Color3.fromRGB(255, 93, 219), BackgroundTransparency = 0.22 + (i % 5) * 0.10, BorderSizePixel = 0, ZIndex = 3})
				pill(node); addAnimated(node, "spark", {seed = i, x = (i * 0.271) % 1, y = (i * 0.413) % 1, speed = 0.015 + (i % 5) * 0.004})
			end
			for i = 1, 12 do make("Frame", {Name = "Scanline", Size = UDim2.new(1.2, 0, 0, 2), Position = UDim2.new(-0.1, 0, (i * 0.083) % 1, 0), Rotation = -2, BackgroundColor3 = accent, BackgroundTransparency = 0.86, BorderSizePixel = 0, ZIndex = 2}) end
		elseif backdropTheme == "Neon" then
			for i = 1, 20 do
				local bar = make("Frame", {Name = "NeonBar", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0.25 + (i % 5) * 0.12, 0, 0, 3 + i % 5), Position = UDim2.new((i * 0.193) % 1, 0, (i * 0.417) % 1, 0), Rotation = -42 + (i * 13) % 84, BackgroundColor3 = i % 2 == 0 and Color3.fromRGB(255, 47, 216) or Color3.fromRGB(45, 236, 255), BackgroundTransparency = 0.38 + (i % 4) * 0.10, BorderSizePixel = 0, ZIndex = 1})
				pill(bar)
			end
			for i = 1, 170 do
				local dot = make("Frame", {Name = "NeonParticle", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(1 + i % 5, 1 + i % 5), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.347) % 1, 0), BackgroundColor3 = i % 2 == 0 and Color3.fromRGB(52, 239, 255) or Color3.fromRGB(255, 75, 222), BackgroundTransparency = 0.25 + (i % 5) * 0.10, BorderSizePixel = 0, ZIndex = 2})
				pill(dot); addAnimated(dot, "spark", {seed = i, x = (i * 0.618) % 1, y = (i * 0.347) % 1, speed = 0.017 + (i % 5) * 0.004})
			end
		elseif backdropTheme == "Sakura" then
			for i = 1, 15 do make("Frame", {Name = "PetalGlow", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(0.7 + i * 0.05, 0, 0.12, 0), Position = UDim2.new((i * 0.31) % 1, 0, (i * 0.071) % 1, 0), Rotation = -18 + i * 5, BackgroundColor3 = i % 2 == 0 and Color3.fromRGB(255, 116, 185) or Color3.fromRGB(168, 84, 170), BackgroundTransparency = 0.94, BorderSizePixel = 0, ZIndex = 0}) end
			for i = 1, 130 do
				local petal = make("Frame", {Name = "Petal", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(4 + i % 6, 2 + i % 4), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.371) % 1, 0), Rotation = -50 + (i * 17) % 100, BackgroundColor3 = i % 3 == 0 and Color3.fromRGB(255, 221, 238) or Color3.fromRGB(255, 126, 183), BackgroundTransparency = 0.20 + (i % 5) * 0.10, BorderSizePixel = 0, ZIndex = 2})
				pill(petal); addAnimated(petal, "spark", {seed = i, x = (i * 0.618) % 1, y = (i * 0.371) % 1, speed = 0.012 + (i % 4) * 0.004})
			end
		elseif backdropTheme == "Forest" then
			for layer = 1, 14 do make("Frame", {Name = "Canopy" .. layer, Size = UDim2.new(1.4, 0, 0.22, 0), Position = UDim2.new(-0.2, 0, -0.04 + layer * 0.075, 0), Rotation = -8 + layer * 2, BackgroundColor3 = layer % 2 == 0 and Color3.fromRGB(7, 77, 52) or Color3.fromRGB(15, 111, 64), BackgroundTransparency = 0.82 + layer * 0.008, BorderSizePixel = 0, ZIndex = 0}) end
			for i = 1, 115 do
				local firefly = make("Frame", {Name = "Firefly", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2 + i % 4, 2 + i % 4), Position = UDim2.new((i * 0.271) % 1, 0, (i * 0.413) % 1, 0), BackgroundColor3 = i % 3 == 0 and Color3.fromRGB(255, 241, 126) or Color3.fromRGB(127, 255, 168), BackgroundTransparency = 0.22 + (i % 5) * 0.10, BorderSizePixel = 0, ZIndex = 2})
				pill(firefly); addAnimated(firefly, "star", {seed = i, base = (i * 0.413) % 0.94, x = (i * 0.271) % 1, speed = 0.018 + (i % 4) * 0.005})
			end
		elseif backdropTheme == "Prism" then
			for layer = 1, 18 do
				local hue = layer % 3 == 0 and Color3.fromRGB(112, 246, 255) or (layer % 3 == 1 and Color3.fromRGB(169, 105, 255) or Color3.fromRGB(255, 104, 214))
				make("Frame", {Name = "PrismGlow" .. layer, Size = UDim2.new(1.35, 0, 0.18 + layer * 0.012, 0), Position = UDim2.new(-0.18, 0, -0.08 + layer * 0.073, 0), Rotation = -28 + layer * 3, BackgroundColor3 = hue, BackgroundTransparency = 0.93, BorderSizePixel = 0, ZIndex = 0})
			end
			for i = 1, 160 do
				local shard = make("Frame", {Name = "PrismShard", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(2 + i % 6, 12 + i % 28), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.371) % 1, 0), Rotation = -55 + (i * 23) % 110, BackgroundColor3 = i % 3 == 0 and Color3.fromRGB(231, 253, 255) or (i % 2 == 0 and accent or secondary), BackgroundTransparency = 0.30 + (i % 7) * 0.075, BorderSizePixel = 0, ZIndex = 2})
				pill(shard); addAnimated(shard, "spark", {seed = i, x = (i * 0.618) % 1, y = (i * 0.371) % 1, speed = 0.010 + (i % 6) * 0.003})
			end
			for i = 1, 8 do
				local ring = make("Frame", {Name = "PrismRing", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(100 + i * 58, 100 + i * 58), Position = UDim2.new(0.52, 0, 0.48, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 1})
				local stroke = Instance.new("UIStroke"); stroke.Color = i % 2 == 0 and accent or secondary; stroke.Transparency = 0.84 + i * 0.012; stroke.Thickness = 2; stroke.Parent = ring; pill(ring)
			end
		elseif backdropTheme == "Void" then
			for i = 1, 180 do
				local star = make("Frame", {Name = "VoidStar", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(1 + i % 3, 1 + i % 3), Position = UDim2.new((i * 0.618) % 1, 0, (i * 0.371) % 1, 0), BackgroundColor3 = i % 4 == 0 and Color3.fromRGB(173, 101, 255) or Color3.fromRGB(238, 233, 255), BackgroundTransparency = 0.25 + (i % 5) * 0.11, BorderSizePixel = 0, ZIndex = 2})
				pill(star); addAnimated(star, "star", {seed = i, base = (i * 0.371) % 0.95, x = (i * 0.618) % 1, speed = 0.012 + (i % 4) * 0.004})
			end
			for i = 1, 9 do
				local ring = make("Frame", {Name = "GravityRing", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(70 + i * 45, 70 + i * 45), Position = UDim2.new(0.52, 0, 0.48, 0), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 1})
				local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(117, 75, 255); stroke.Transparency = 0.86 + i * 0.012; stroke.Thickness = 2; stroke.Parent = ring
				pill(ring)
			end
		end

		backdropParts = animated
	end
	local function animateBackdrop(dt)
		backdropClock = backdropClock + (dt or 0)
		for _, item in ipairs(backdropParts) do
			local node = item.node
			if node and node.Parent then
				if item.kind == "bubble" then node.Position = UDim2.new((item.x + math.sin(backdropClock + item.seed) * 0.012) % 1, 0, 1 - ((backdropClock * item.speed + item.seed * 0.037) % 0.96), 0)
				elseif item.kind == "spark" then node.Position = UDim2.new((item.x + math.sin(backdropClock * 0.6 + item.seed) * 0.015) % 1, 0, (item.y - backdropClock * item.speed) % 1, 0)
				elseif item.kind == "star" then node.Position = UDim2.new(item.x, 0, item.base + math.sin(backdropClock * item.speed + item.seed) * 0.012, 0)
				elseif item.kind == "generic" then
					local phase = item.phase + backdropClock * item.speed
					node.Position = UDim2.new(item.x + math.sin(phase) * item.amp, item.xo, item.y + math.cos(phase * 0.83) * item.amp, item.yo)
					node.Rotation = item.rotation + math.sin(phase * 0.71) * item.rotAmp
					if item.baseTransparency and item.baseTransparency < 0.98 then node.BackgroundTransparency = math.clamp(item.baseTransparency + math.sin(phase * 0.53) * 0.018, 0, 1) end
				else local phase = item.phase + backdropClock * item.speed; node.Position = UDim2.new(item.x, 0, item.base + math.sin(phase) * item.amp, 0); node.Rotation = math.cos(phase) * (item.kind == "foam" and 8 or 10) end
			end
		end
	end
	local ok, err = pcall(function()

		window = UI:CreateWindow({Id = "billiards-suite", Title = "당구 통합 도우미",
			Subtitle = "포켓볼·3구·4구 자동 감지 · 예상 경로 · 자동 플레이", Theme = "Crystal", Locale = "ko",
			CloseBehavior = "Minimize", Width = 540, Height = 540})
		local loadingSettings = true
		local settingsPath = "Billiards/autoplay_settings.json"
		local savedSettings = {}
		local HttpService = game:GetService("HttpService")
		local function loadSettings()
			local read = (getgenv and getgenv().readfile) or readfile
			if type(read) ~= "function" then return end
			local ok, raw = pcall(read, settingsPath)
			if ok and type(raw) == "string" then
				local decoded, data = pcall(HttpService.JSONDecode, HttpService, raw)
				if decoded and type(data) == "table" then savedSettings = data end
			end
		end
		local function saveSettings()
			if loadingSettings or not window or not window.Alive then return end
			local write = (getgenv and getgenv().writefile) or writefile
			local make = (getgenv and getgenv().makefolder) or makefolder
			if type(write) ~= "function" or type(make) ~= "function" then return end
			pcall(make, "Billiards")
			local g = window:GetGeometry()
			local data = {version = 1, enabled = state.Enabled == true, preview = preview.Enabled == true, strongPlay = state.StrongPlay == true, smoothCue = state.SmoothCue == true, humanThinking = state.HumanThinking == true, style = state.Style, thinkSeconds = state.ThinkSeconds,
				background = backdropTheme, guiScale = window.TextScale, geometry = {width = g.width, height = g.height, x = g.x, y = g.y}}
			local ok, raw = pcall(HttpService.JSONEncode, HttpService, data)
			if ok then pcall(write, settingsPath, raw) end
		end
		loadSettings()
		pcall(buildBackdrop, "Crystal")
		local section = window:Tab({Id = "main", Title = "당구 도우미"}):Section({Title = "경로 표시와 자동 플레이"})
		modeLabel = section:Label({Id = "mode", Text = "포켓볼·3구·4구 모드 확인 중"})
		section:Toggle({Id = "preview", Text = "예상 경로 표시", Default = savedSettings.preview ~= false, Persist = false, Callback = function(v) preview.SetEnabled(v); saveSettings() end})
		toggle = section:Toggle({Id = "enabled", Text = "자동 플레이", Default = false,
			Persist = true, Callback = function(v) state.SetEnabled(v); saveSettings() end})
		section:Label({Id = "shot-policy", Text = "득점·다음 수·수비를 비교 · 검증된 유효 타격 실행"})
		section:Toggle({Id = "strong-play", Text = "다음 수와 수비까지 비교", Default = savedSettings.strongPlay ~= false, Persist = false,
			Callback = function(v) state.StrongPlay = v == true; saveSettings() end})
		section:Toggle({Id = "smooth-cue", Text = "큐대 부드럽게 이동", Default = savedSettings.smoothCue ~= false, Persist = false,
			Callback = function(v) state.SetSmoothCue(v); saveSettings() end})
		section:Toggle({Id = "human-thinking", Text = "방향을 고민하는 동작", Default = savedSettings.humanThinking ~= false, Persist = false,
			Callback = function(v) state.HumanThinking = v == true; saveSettings() end})
		statusLabel = section:Label({Id = "status", Text = state.Status})
		statsLabel = section:Label({Id = "stats", Text = "타격 0회 · 서버 확인 0회"})
		section:Button({Id = "sync", Text = "경기 상태 다시 조회", ActionText = "조회",
			Callback = function() if remote then lastSync = os.clock() remote:FireServer("sync") end end})
		section:Button({Id = "stop", Text = "완전히 종료", ActionText = "종료", Callback = state.Stop})

		local styles = window:Tab({Id = "styles", Title = "당구 스타일"}):Section({Title = "자동플레이 전략 프리셋"})
		styles:Label({Id = "style-info", Text = "스타일은 후보 생성과 득점·수비 평가에 반영됩니다."})
		styles:Dropdown({Id = "play-style", Text = "플레이 스타일", Placeholder = "스타일 선택", Default = savedSettings.style or state.Style or "balanced", Persist = true, Options = {
			{Value = "balanced", Label = "균형형 · 득점과 수비"}, {Value = "chess", Label = "체스형 · 다음 수까지 계산"},
			{Value = "basic", Label = "기본형 · 원본 자동플레이"}, {Value = "alien", Label = "Alien · 연속득점·상대차단"}, {Value = "attack", Label = "공격형 · 최대 득점"}, {Value = "art", Label = "예술당구형 · 기술구·예술구"}, {Value = "defense", Label = "방어형 · 혼란·득점 차단"}},
			Callback = function(v) state.SetStyle(v); saveSettings() end})
		styles:Slider({Id = "think-seconds", Text = "계산 시간", Min = 3, Max = 15, Step = 1, Default = savedSettings.thinkSeconds or state.ThinkSeconds, Suffix = "초", Persist = true, OnCommit = function(v) state.ThinkSeconds = v; saveSettings() end})
		styles:Toggle({Id = "deep-search", Text = "후속 수까지 깊게 탐색", Default = savedSettings.strongPlay ~= false, Persist = false, Callback = function(v) state.StrongPlay = v == true; saveSettings() end})
		styles:Label({Id = "style-note", Text = "기본형은 원본 자동플레이 계산을 사용합니다. 공격형은 득점 루트를 전부 탐색하고, 예술당구형은 계산 시간이 길수록 더 많은 기술구·예술구를 탐색하되 득점을 우선합니다. Alien·방어형은 별도 전략을 사용합니다."})

		local settings = window:Tab({Id = "settings", Title = "설정"}):Section({Title = "GUI 크기·배율"})
		settings:Label({Id = "settings-info", Text = "배율을 줄이면 글자·버튼·클릭 영역·간격이 함께 줄어듭니다."})
		settings:Slider({Id = "gui-scale", Text = "전체 GUI 배율", Min = 0.85, Max = 1.5, Step = 0.05, Default = savedSettings.guiScale or 1.0, Suffix = "x", Persist = true,
			OnCommit = function(v) if window and window.Alive then window:SetTextScale(v); saveSettings() end end})
		settings:Slider({Id = "gui-width", Text = "창 가로 크기", Min = 320, Max = 900, Step = 10, Default = (savedSettings.geometry and savedSettings.geometry.width) or 540, Suffix = "px", Persist = true,
			OnCommit = function(v) if window and window.Alive then local g = window:GetGeometry(); window:SetGeometry({width = v, height = g.height, x = g.x, y = g.y}); saveSettings() end end})
		settings:Slider({Id = "gui-height", Text = "창 세로 크기", Min = 300, Max = 850, Step = 10, Default = (savedSettings.geometry and savedSettings.geometry.height) or 540, Suffix = "px", Persist = true,
			OnCommit = function(v) if window and window.Alive then local g = window:GetGeometry(); window:SetGeometry({width = g.width, height = v, x = g.x, y = g.y}); saveSettings() end end})
		settings:Button({Id = "gui-reset", Text = "GUI 크기 초기값", ActionText = "복원", Callback = function()
			if window and window.Alive then window:SetTextScale(1); window:SetGeometry({width = 540, height = 540}); saveSettings() end
		end})
		local backgrounds = window:Tab({Id = "background", Title = "배경"}):Section({Title = "배경 스타일"})
		backgrounds:Label({Id = "background-info", Text = "원하는 스타일을 고르면 전체 UI가 즉시 바뀝니다."})
		backgrounds:Dropdown({Id = "background-theme", Text = "배경 선택", Placeholder = "스타일 선택", Default = savedSettings.background or "Crystal", Persist = true, Options = {
			{Value = "Crystal", Label = "Crystal · 크리스탈"}, {Value = "Crimson", Label = "Crimson · 크림슨"},
			{Value = "Tidal", Label = "Tidal · 타이달"}, {Value = "Aurora", Label = "Aurora · 오로라"},
			{Value = "Ember", Label = "Ember · 엠버"}, {Value = "Space", Label = "Space · 스페이스"}, {Value = "Prism", Label = "Prism · 프리즘 글로우"}, {Value = "Neon", Label = "Neon · 네온"}, {Value = "Cyber", Label = "Cyber · 사이버"}, {Value = "Sakura", Label = "Sakura · 사쿠라"}, {Value = "Forest", Label = "Forest · 포레스트"}, {Value = "Void", Label = "Void · 보이드"}, {Value = "CodexDark", Label = "Codex Dark"}, {Value = "CodexLight", Label = "Codex Light"}},
			Callback = function(v) if window and window.Alive then window:SetTheme(v == "Prism" and "Crystal" or v); pcall(buildBackdrop, v); saveSettings() end end})
		state.Window = window
		if savedSettings.guiScale then window:SetTextScale(savedSettings.guiScale) end
		if savedSettings.geometry then window:SetGeometry(savedSettings.geometry) end
		if savedSettings.style then state.SetStyle(savedSettings.style) end
		if savedSettings.preview ~= nil then preview.SetEnabled(savedSettings.preview == true) end
		if savedSettings.strongPlay ~= nil then state.StrongPlay = savedSettings.strongPlay == true end
		if savedSettings.smoothCue ~= nil then state.SetSmoothCue(savedSettings.smoothCue == true) end
		if savedSettings.humanThinking ~= nil then state.HumanThinking = savedSettings.humanThinking == true end
		if savedSettings.background then window:SetTheme(savedSettings.background == "Prism" and "Crystal" or savedSettings.background); pcall(buildBackdrop, savedSettings.background) end
		if savedSettings.enabled == true then state.SetEnabled(true) end
		loadingSettings = false
		window:OnDestroy(function() saveSettings(); state.Stop() end)
	end)
	if not ok then state.UIError = tostring(err) warn("자동 플레이 창 오류: " .. state.UIError) end
	heartbeat = runService.Heartbeat:Connect(function(dt)
		pcall(animateBackdrop, dt)
		local ok, err = pcall(tick)
		if not ok then state.Error = tostring(err) pause("자동 플레이 오류: " .. state.Error) end
	end)
	tick()
	print("당구 통합 도우미 준비 완료: 포켓볼·3구·4구 자동 감지, 예상 경로 표시 켜짐, 자동 플레이 꺼짐")
	return state
end
local preview = startPreview()
local ok, suite = pcall(startAuto, preview)
if not ok then preview.Stop() error(suite) end
return suite
