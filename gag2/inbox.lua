local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Networking = require(ReplicatedStorage:WaitForChild("SharedModules"):WaitForChild("Networking"))

-- ── Config ───────────────────────────────────────────────────────────────────
local CLAIM_DELAY = 1.0   -- seconds between claims (avoid server anti-spam)

-- ── Optional: pretty item names via the game's own catalog ─────────────────────
-- MailboxItemCatalog.Resolve(category, itemName, payload) -> displayName, image
local Catalog
do
	local ok, mod = pcall(function()
		return Players.LocalPlayer.PlayerScripts.Controllers.MailboxController.MailboxItemCatalog
	end)
	if ok and mod then
		local ok2, res = pcall(require, mod)
		if ok2 and typeof(res) == "table" then
			Catalog = res
		end
	end
end

local function resolveName(category, itemName, payload)
	if Catalog and Catalog.Resolve then
		local ok, name = pcall(Catalog.Resolve, category, itemName, payload)
		if ok and type(name) == "string" and name ~= "" then
			return name
		end
	end
	return ("%s:%s"):format(tostring(category), tostring(itemName))
end

-- ── Inbox ─────────────────────────────────────────────────────────────────────
-- Fetch the inbox. Returns a { giftId = payload } table (empty table on failure).
function OpenInbox()
	local ok, result = pcall(function()
		return Networking.Mailbox.OpenInbox:Fire()
	end)
	if ok and typeof(result) == "table" then
		return result
	end
	warn("[Inbox] OpenInbox failed", result)
	return {}
end

-- Human-readable summary of one gift payload.
local function describe(payload)
	if typeof(payload) ~= "table" then
		return tostring(payload)
	end
	local from = payload.FromName or payload.From or "?"
	local parts = {}
	local items = payload.Items
	if typeof(items) == "table" and #items > 0 then          -- multi-item gift
		for _, it in ipairs(items) do
			local nm = resolveName(it.Category, it.ItemName, it.Pet or it.Fruit)
			table.insert(parts, ("%s x%d"):format(nm, it.Count or 1))
		end
	else                                                      -- single-item gift
		table.insert(parts, resolveName(payload.Category, payload.ItemName, payload.Payload) .. " x1")
	end
	local kind = payload.Kind and (" [" .. tostring(payload.Kind) .. "]") or ""
	return ("from @%s%s | %s"):format(tostring(from), kind, table.concat(parts, ", "))
end

-- Print everything currently in the inbox. Returns the inbox table.
function ListInbox()
	local inbox = OpenInbox()
	local n = 0
	for id, payload in inbox do
		n = n + 1
		print(("[Inbox] %s | %s"):format(tostring(id), describe(payload)))
	end
	if n == 0 then
		print("[Inbox] empty")
	end
	return inbox
end

-- ── Claim ─────────────────────────────────────────────────────────────────────
-- Claim a single gift by id. Returns success(boolean), message(string).
function Claim(giftId)
	local ok, success, message = pcall(function()
		return Networking.Mailbox.Claim:Fire(giftId)
	end)
	print(("[Inbox] claim %s | ok=%s success=%s msg=%s")
		:format(tostring(giftId), tostring(ok), tostring(success), tostring(message)))
	return ok and success == true, message
end

-- Claim every gift currently in the inbox. Returns claimed, total.
function ClaimAll()
	local inbox = OpenInbox()
	local ids = {}                       -- snapshot ids first (inbox changes as we claim)
	for id in inbox do
		table.insert(ids, id)
	end
	print(("[Inbox] claiming %d gift(s)..."):format(#ids))

	local claimed = 0
	for i, id in ipairs(ids) do
		if Claim(id) then
			claimed = claimed + 1
		end
		if i < #ids then
			task.wait(CLAIM_DELAY)
		end
	end
	print(("[Inbox] done: %d/%d claimed"):format(claimed, #ids))
	return claimed, #ids
end

-- ── Example ───────────────────────────────────────────────────────────────────
-- ListInbox()
ClaimAll()   -- uncomment to claim everything
