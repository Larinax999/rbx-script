local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local Networking = require(SharedModules:WaitForChild("Networking"))

-- ── Config ───────────────────────────────────────────────────────────────────
local LIMIT       = 20     -- max total item count per gift (matches MailboxController)
local SEND_DELAY  = 1.5    -- seconds between batches (matches the client send cooldown)
local MAX_RETRIES = 5      -- retries per gift when the server rate-limits us
local WAIT_BUFFER = 0.25   -- extra seconds added on top of the server's "wait Ns"
local DEFAULT_CATEGORY = "Seeds"   -- fallback when a name can't be resolved

-- ── Category auto-resolver ────────────────────────────────────────────────────
-- Builds a name -> {category, canonical key} index from the game's own shared
-- data modules, using the same modules + name fields MailboxItemCatalog reads.
-- NOTE: only stackable categories work by name. Pets/HarvestedFruits are keyed
-- by inventory UUID, so they can't be sent through this name-based path.
local CATEGORY_SOURCES = {
	{ module = "SeedData",        category = "Seeds",        fields = { "SeedName" } },
	{ module = "SprinklerData",   category = "Sprinklers",   fields = { "SprinklerName" } },
	{ module = "WateringcanData", category = "WateringCans", fields = { "Name" } },
	{ module = "MushroomData",    category = "Mushrooms",    fields = { "Name" } },
	{ module = "RaccoonData",     category = "Raccoons",     fields = { "Name" } },
	{ module = "GnomeData",       category = "Gnomes",       fields = { "Name" } },
	{ module = "SeedPackData",    category = "SeedPacks",    fields = { "PackName" } },
	{ module = "PropData",        category = "Props",        fields = { "PropName" } },
}

-- Manual overrides for anything the auto-index can't enumerate (Crates/Trowels
-- expose GetData() instead of a list). key = lowercase name, value = category.
local CATEGORY_OVERRIDES = {
	-- ["common crate"] = "Crates",
}

local function requireData(name)
	local mod = SharedModules:FindFirstChild(name)
	if mod and mod:IsA("ModuleScript") then
		local ok, data = pcall(require, mod)
		if ok then return data end
	end
	return nil
end

local index = {}   -- lower(name) -> { category = ..., key = ... }
local function indexData(data, category, fields)
	if typeof(data) ~= "table" then return end
	local list = (typeof(data.Data) == "table") and data.Data or data  -- gear modules nest under .Data
	for _, entry in list do
		if typeof(entry) == "table" then
			for _, field in fields do
				local v = entry[field]
				if typeof(v) == "string" and v ~= "" then
					local k = string.lower(v)
					if not index[k] then
						index[k] = { category = category, key = v }
					end
				end
			end
		end
	end
end

for _, src in CATEGORY_SOURCES do
	indexData(requireData(src.module), src.category, src.fields)
end

-- Returns category, canonicalKey for a display name (case-insensitive, with a
-- "Carrot" <-> "Carrot Seed" fallback to match how seeds are stored).
local function resolveItem(name)
	local k = string.lower(name)
	if CATEGORY_OVERRIDES[k] then
		return CATEGORY_OVERRIDES[k], name
	end
	local hit = index[k]
		or index[(string.gsub(k, "%s+seed$", ""))]   -- "Carrot Seed" -> "Carrot"
		or index[k .. " seed"]                        -- "Carrot" -> "Carrot Seed"
	if hit then
		return hit.category, hit.key
	end
	return DEFAULT_CATEGORY, name
end

-- ── Note builder ──────────────────────────────────────────────────────────────
-- "Carrot Seed 5x, Rainbow Seed 5x, ..."  (clamped to the in-game 100-char limit)
local function displayName(item)
	if item.Category == "Seeds" and not string.match(string.lower(item.ItemKey), "seed$") then
		return item.ItemKey .. " Seed"
	end
	return item.ItemKey
end

local function buildNote(batch)
	local parts = {}
	for _, item in ipairs(batch) do
		table.insert(parts, ("%s %dx"):format(displayName(item), item.Count))
	end
	local note = table.concat(parts, ", ")
	if utf8.len(note) and utf8.len(note) > 100 then
		local cut = utf8.offset(note, 101)
		note = cut and string.sub(note, 1, cut - 1) or string.sub(note, 1, 100)
	end
	return note
end

-- ── Batch packer ──────────────────────────────────────────────────────────────
-- Splits items into gifts whose total Count never exceeds LIMIT, slicing a single
-- stack across gifts when its own Count is over the limit (e.g. Carrot 50 -> 20/20/10).
local function buildBatches(resolved, limit)
	local batches, current, currentCount = {}, {}, 0
	for _, it in ipairs(resolved) do
		local remaining = it.Count
		while remaining > 0 do
			if currentCount >= limit then
				table.insert(batches, current)
				current, currentCount = {}, 0
			end
			local take = math.min(limit - currentCount, remaining)
			table.insert(current, { Category = it.Category, ItemKey = it.ItemKey, Count = take })
			currentCount = currentCount + take
			remaining = remaining - take
		end
	end
	if #current > 0 then
		table.insert(batches, current)
	end
	return batches
end

-- ── Rate-limit parsing ────────────────────────────────────────────────────────
-- Pulls the seconds out of messages like "Wait 5s before sending another gift".
-- Returns the number of seconds, or nil if the message isn't a wait/cooldown.
local function parseWait(message)
	if type(message) ~= "string" then return nil end
	local lower = string.lower(message)
	if not (string.find(lower, "wait") or string.find(lower, "cooldown")) then
		return nil
	end
	local n = string.match(message, "(%d+%.?%d*)")
	return n and tonumber(n) or nil
end

local function fmtTime(seconds)
	if seconds >= 60 then
		return ("%dm %.1fs"):format(math.floor(seconds / 60), seconds % 60)
	end
	return ("%.2fs"):format(seconds)
end

-- ── Main ──────────────────────────────────────────────────────────────────────
-- items: { {Name, Count}, ... }   e.g. { {"Carrot", 5}, {"Rainbow", 5} }
function Send(username, items)
	local startClock = os.clock()
	local ok1, userId, displayName = pcall(function()
		return Networking.Mailbox.LookupPlayer:Fire(username)
	end)
	if not ok1 or type(userId) ~= "number" or userId <= 0 then
		warn("[Mail] lookup failed for " .. tostring(username), userId)
		return false
	end
	print(("[Mail] uid: %d | username: %s | displayName: %s"):format(userId, username, tostring(displayName)))

	-- resolve categories + drop invalid entries
	local resolved = {}
	for _, pair in ipairs(items) do
		local name = pair[1]
		local count = tonumber(pair[2]) or 1
		if type(name) == "string" and name ~= "" and count > 0 then
			local category, key = resolveItem(name)
			table.insert(resolved, { Category = category, ItemKey = key, Count = count })
			print(("[Mail]   %s -> %s:%s x%d"):format(name, category, key, count))
		end
	end
	if #resolved == 0 then
		warn("[Mail] nothing valid to send")
		return false
	end

	-- split over the per-gift limit and send each batch
	local batches = buildBatches(resolved, LIMIT)
	print(("[Mail] sending %d stack(s) across %d gift(s)"):format(#resolved, #batches))

	local allOk = true
	local sentCount = 0
	local waitedTotal = 0          -- total seconds spent sleeping (cooldowns + rate-limit waits)
	local cooldown = SEND_DELAY    -- adaptive: bumped to whatever the server tells us to wait

	for i, batch in ipairs(batches) do
		local note = buildNote(batch)
		local sent = false

		for attempt = 1, MAX_RETRIES + 1 do
			local ok2, success, message = pcall(function()
				return Networking.Mailbox.SendBatch:Fire(userId, batch, note)
			end)
			print(("[Mail] gift %d/%d (try %d) | ok=%s success=%s msg=%s | %s")
				:format(i, #batches, attempt, tostring(ok2), tostring(success), tostring(message), note))

			if ok2 and success then
				sent = true
				break
			end

			local waitFor = parseWait(message)
			if waitFor then
				cooldown = math.max(cooldown, waitFor)         -- remember it for the next batches
				local sleep = waitFor + WAIT_BUFFER
				print(("[Mail]   rate-limited, waiting %s..."):format(fmtTime(sleep)))
				task.wait(sleep)
				waitedTotal = waitedTotal + sleep
			else
				break   -- non-rate-limit failure: don't retry
			end
		end

		if sent then
			sentCount = sentCount + 1
		else
			allOk = false
		end

		-- proactively respect the (learned) cooldown before the next batch
		if sent and i < #batches then
			task.wait(cooldown)
			waitedTotal = waitedTotal + cooldown
		end
	end

	local elapsed = os.clock() - startClock
	print(("[Mail] done: %d/%d gift(s) sent | waited %s | total %s")
		:format(sentCount, #batches, fmtTime(waitedTotal), fmtTime(elapsed)))
	return allOk
end

-- ── Example ───────────────────────────────────────────────────────────────────
Send("larinax999", {
	{"Gold Seed", 10},
	-- {"Rainbow Seed", 10},
})