--!nocheck
-- Harness bootstrap: installs Roblox datatype shims and mounts src/ as a mock DataModel.

local root = __kitRoot
local shimDir = root .. "/tools/harness/shim/"

-- 1) load shims with a tiny name-based loader
local shimCache = {}
local function shimRequire(name)
	if shimCache[name] then
		return shimCache[name]
	end
	local env = setmetatable({ require = shimRequire }, { __index = _G })
	local fn = __load(__readfile(shimDir .. name .. ".luau"), "@shim/" .. name, env)
	local value = fn()
	shimCache[name] = value
	return value
end

Vector3 = shimRequire("Vector3")
CFrame = shimRequire("CFrame")
Color3 = shimRequire("Color3")
Enum = shimRequire("Enum")
Instance = shimRequire("Instance")
local Json = shimRequire("Json")

local nativeTypeof = typeof
function typeof(v)
	if type(v) == "table" then
		if rawget(v, "__isVector3") then
			return "Vector3"
		elseif rawget(v, "__isCFrame") then
			return "CFrame"
		elseif rawget(v, "__isColor3") then
			return "Color3"
		elseif rawget(v, "__isEnumItem") then
			return "EnumItem"
		elseif rawget(v, "_isInstance") then
			return "Instance"
		end
	end
	return nativeTypeof(v)
end

function warn(...)
	print("[warn]", ...)
end

function tick()
	return os.clock()
end

task = {
	wait = function()
		return 0
	end,
	spawn = function(f, ...)
		return f(...)
	end,
	defer = function(f, ...)
		return f(...)
	end,
	delay = function() end,
}

-- 2) mock DataModel
game = Instance.new("DataModel")
game.Name = "Game"
local services = {}
local function getService(_, name)
	if services[name] then
		return services[name]
	end
	local ok = pcall(function()
		return Instance.new(name)
	end)
	local s
	if ok then
		s = Instance.new(name)
	else
		s = Instance.new("Folder")
	end
	s.Name = name
	s.Parent = game
	services[name] = s
	return s
end
rawset(game, "GetService", getService)
-- allow game:GetService through method lookup
local gameMeta = getmetatable(game)
local origIndex = gameMeta.__index
workspace = getService(game, "Workspace")
local sp = getService(game, "StarterPlayer")
local sps = Instance.new("StarterPlayerScripts")
sps.Name = "StarterPlayerScripts"
sps.Parent = sp
local scs = Instance.new("StarterCharacterScripts")
scs.Name = "StarterCharacterScripts"
scs.Parent = sp

-- 3) mount src/ into the mock DataModel
local scriptPaths = {}
local function classForFile(name)
	if name:match("%.server%.luau$") then
		return "Script", name:gsub("%.server%.luau$", "")
	elseif name:match("%.client%.luau$") then
		return "LocalScript", name:gsub("%.client%.luau$", "")
	elseif name:match("%.luau$") then
		return "ModuleScript", name:gsub("%.luau$", "")
	end
	return nil
end

local function mount(dirPath, parentInst)
	for _, e in __listdir(dirPath) do
		local full = dirPath .. "/" .. e.name
		if e.dir then
			local existing = parentInst:FindFirstChild(e.name)
			local folder = existing
			if not folder then
				folder = Instance.new("Folder")
				folder.Name = e.name
				folder.Parent = parentInst
			end
			mount(full, folder)
		else
			local cls, base = classForFile(e.name)
			if cls then
				local inst = Instance.new(cls)
				inst.Name = base
				inst.Parent = parentInst
				scriptPaths[inst] = full
			end
		end
	end
end

local srcDir = root .. "/src"
if __exists(srcDir) then
	for _, e in __listdir(srcDir) do
		if e.dir then
			local svc
			if e.name == "StarterPlayer" then
				svc = sp
			else
				svc = getService(game, e.name)
			end
			mount(srcDir .. "/" .. e.name, svc)
		end
	end
end

-- 4) Roblox-style require(ModuleScript)
local moduleCache = {}
local loading = {}
function require(mod)
	if type(mod) == "string" then
		return shimRequire(mod)
	end
	if moduleCache[mod] ~= nil then
		return moduleCache[mod]
	end
	local p = scriptPaths[mod]
	if not p then
		error("require: not a mounted ModuleScript: " .. tostring(mod), 2)
	end
	if loading[mod] then
		error("require: cyclic dependency on " .. mod:GetFullName(), 2)
	end
	loading[mod] = true
	local env = setmetatable({ script = mod }, { __index = _G, __newindex = _G })
	local rel = p:sub(#root + 2)
	local fn = __load(__readfile(p), "@" .. rel, env)
	local value = fn()
	loading[mod] = nil
	if value == nil then
		error("module " .. rel .. " did not return a value", 2)
	end
	moduleCache[mod] = value
	return value
end

-- helpers exposed to harness scripts
Harness = {
	Json = Json,
	root = root,
	serialize = Instance.__serialize,
	scriptPath = function(inst)
		return scriptPaths[inst]
	end,
	writeJson = function(path, value, precision)
		__writefile(path, Json.encode(value, precision))
	end,
	writeFile = function(path, content)
		__writefile(path, content)
	end,
	readFile = function(path)
		return __readfile(path)
	end,
	-- compile-check every script under src/ (syntax errors surface here)
	compileAll = function()
		local count = 0
		for inst, path in scriptPaths do
			local ok, err = pcall(__load, __readfile(path), "@" .. path:sub(#root + 2), {})
			if not ok then
				error("compile failed: " .. tostring(err))
			end
			count += 1
		end
		return count
	end,
	mounted = scriptPaths,
}

function __runScript(src, name)
	local env = setmetatable({ script = nil, args = __args }, { __index = _G, __newindex = _G })
	local fn = __load(src, name, env)
	return fn()
end
