--!strict
-- The authoring API behind UpdateLogData. Edit the CONTENT in UpdateLogData;
-- this file is the machinery that turns it into the shape the page renders.
--
-- Writing a release by hand means nesting groups inside items inside groups,
-- which is easy to get subtly wrong and impossible to skim. Instead:
--
--   Builder.version("0.4.1", "2 Aug 2026", "Bridges")
--       :added("Suspension bridges over any water body.", "ROADS")
--       :added("Bridge pillars follow the riverbed.")
--       :changed("Elevation steps are 4 m instead of 5 m.")
--       :fixed("Ramps could detach from the highway they joined.")
--
-- Call the same method twice and the lines join the SAME group -- you never end
-- up with two ADDED headings. Groups always render in ADDED, CHANGED, FIXED
-- order no matter which order you wrote them in, and any custom group you add
-- with :group() follows after those, in the order you declared it.
--
-- Credits sections use the same object with :group(name, { "line", ... }).
--
-- Stateless: every call returns a fresh builder, so requiring this module twice
-- can never leak content between them.

local Builder = {}

export type Item = {
	text: string,
	tag: string?,
}

export type Group = {
	name: string,
	items: { Item },
}

export type Version = {
	version: string,
	date: string,
	title: string,
	latest: boolean?,
	groups: { Group },
}

export type Credit = {
	name: string,
	meta: string,
	title: string,
	groups: { Group },
}

-- The three release-note groups, in the order the page shows them. A group name
-- outside this list is a custom one and sorts after all three.
local CANON = table.freeze({ "ADDED", "CHANGED", "FIXED" })
local function canonRank(name: string): number
	for i, n in CANON do
		if n == name then return i end
	end
	return #CANON + 1
end

export type Entry = {
	-- Append one line to a named group, creating the group on first use.
	group: (self: Entry, name: string, lines: ({ string } | { Item })?) -> Entry,
	added: (self: Entry, text: string, tag: string?) -> Entry,
	changed: (self: Entry, text: string, tag: string?) -> Entry,
	fixed: (self: Entry, text: string, tag: string?) -> Entry,
	-- Force the LATEST badge on or off. Left alone, the newest release gets it.
	latest: (self: Entry, on: boolean?) -> Entry,
	_kind: string,
	_data: any,
	_groups: { Group },
	_declared: { string },
}

local function newEntry(kind: string, data: any): Entry
	local self = {} :: any
	self._kind = kind
	self._data = data
	self._groups = {}
	self._declared = {}

	local function groupNamed(name: string): Group
		for _, g in self._groups do
			if g.name == name then return g end
		end
		local g: Group = { name = name, items = {} }
		table.insert(self._groups, g)
		table.insert(self._declared, name)
		return g
	end

	local function add(name: string, text: string, tag: string?): Entry
		if typeof(text) ~= "string" or text == "" then
			error(("[UpdateLog] %s \"%s\": %s line is empty"):format(kind, tostring(data.title), name), 3)
		end
		table.insert(groupNamed(name).items, { text = text, tag = tag })
		return self
	end

	function self.group(_, name: string, lines: any): Entry
		if typeof(name) ~= "string" or name == "" then
			error(("[UpdateLog] %s \"%s\": group needs a name"):format(kind, tostring(data.title)), 2)
		end
		local g = groupNamed(string.upper(name))
		if lines ~= nil then
			for _, line in lines do
				if typeof(line) == "string" then
					table.insert(g.items, { text = line })
				elseif typeof(line) == "table" and typeof(line.text) == "string" then
					table.insert(g.items, { text = line.text, tag = line.tag })
				else
					error(("[UpdateLog] %s \"%s\": group %s has a line that is neither a string nor { text = ... }")
						:format(kind, tostring(data.title), g.name), 2)
				end
			end
		end
		return self
	end

	function self.added(_, text: string, tag: string?): Entry return add("ADDED", text, tag) end
	function self.changed(_, text: string, tag: string?): Entry return add("CHANGED", text, tag) end
	function self.fixed(_, text: string, tag: string?): Entry return add("FIXED", text, tag) end

	function self.latest(_, on: boolean?): Entry
		self._data.latest = on ~= false
		self._data._latestExplicit = true
		return self
	end

	return self :: Entry
end

-- A release. Newest first in the list you hand to compile().
function Builder.version(version: string, date: string, title: string): Entry
	if typeof(version) ~= "string" or version == "" then
		error("[UpdateLog] version() needs a version string, e.g. \"0.4.1\"", 2)
	end
	if typeof(date) ~= "string" or date == "" then
		error(("[UpdateLog] version %s needs a date, e.g. \"2 Aug 2026\""):format(version), 2)
	end
	if typeof(title) ~= "string" or title == "" then
		error(("[UpdateLog] version %s needs a title"):format(version), 2)
	end
	-- Stored without a leading "v": the page and the menu's build stamp both add
	-- their own formatting.
	return newEntry("version", { version = (version:gsub("^[vV]", "")), date = date, title = title })
end

-- A credits section: the index name, the line under it, and the heading shown
-- over the body.
function Builder.section(name: string, meta: string, title: string): Entry
	if typeof(name) ~= "string" or name == "" then
		error("[UpdateLog] section() needs a name, e.g. \"TEAM\"", 2)
	end
	return newEntry("section", {
		name = string.upper(name),
		meta = meta or "",
		title = title or name,
	})
end

local function sortedGroups(entry: Entry): { Group }
	local groups = table.clone(entry._groups)
	local declaredAt: { [string]: number } = {}
	for i, n in entry._declared do
		if declaredAt[n] == nil then declaredAt[n] = i end
	end
	table.sort(groups, function(a, b)
		local ra, rb = canonRank(a.name), canonRank(b.name)
		if ra ~= rb then return ra < rb end
		return (declaredAt[a.name] or 0) < (declaredAt[b.name] or 0)
	end)
	return groups
end

local function finish(entry: Entry): any
	local out = entry._data
	out._latestExplicit = nil
	out.groups = sortedGroups(entry)
	for _, g in out.groups do
		for _, item in g.items do
			table.freeze(item)
		end
		table.freeze(g.items)
		table.freeze(g)
	end
	table.freeze(out.groups)
	return table.freeze(out)
end

export type Content = {
	versions: { Entry },
	credits: { Entry }?,
}

-- Validates, applies the LATEST badge and freezes. Anything wrong throws HERE,
-- at module load, rather than rendering a broken page later.
function Builder.compile(content: Content): { Versions: { Version }, Credits: { Credit } }
	if typeof(content) ~= "table" or typeof(content.versions) ~= "table" or #content.versions == 0 then
		error("[UpdateLog] compile{} needs a non-empty `versions` list", 2)
	end

	-- The newest release wears LATEST unless something said otherwise.
	local anyExplicit = false
	for _, e in content.versions do
		if e._data._latestExplicit then anyExplicit = true end
	end
	if not anyExplicit then
		content.versions[1]._data.latest = true
	end

	local versions: { Version } = {}
	local seen: { [string]: boolean } = {}
	for _, e in content.versions do
		local v = e._data.version
		if seen[v] then
			error(("[UpdateLog] two releases both numbered %s"):format(v), 2)
		end
		seen[v] = true
		if #e._groups == 0 then
			error(("[UpdateLog] release %s has no notes -- add :added() / :changed() / :fixed()"):format(v), 2)
		end
		table.insert(versions, finish(e) :: Version)
	end

	local credits: { Credit } = {}
	for _, e in content.credits or {} do
		table.insert(credits, finish(e) :: Credit)
	end

	return table.freeze({
		Versions = table.freeze(versions),
		Credits = table.freeze(credits),
	})
end

return Builder
