--!strict

local ZoneTypes = {}

export type ZoneName = "None" | "Residential" | "Commercial" | "Office" | "Industrial"

export type ZoneInfo = {
	Name: ZoneName,
	DisplayName: string,
	Color: Color3,
	Transparency: number,
	Paintable: boolean,
	DemandKey: string?,
	TemplateFolder: string?,
}

local DEFINITIONS: { [ZoneName]: ZoneInfo } = {
	None = {
		Name = "None",
		DisplayName = "None",
		Color = Color3.fromRGB(105, 125, 105),
		Transparency = 0.6,
		Paintable = false,
		DemandKey = nil,
		TemplateFolder = nil,
	},

	Residential = {
		Name = "Residential",
		DisplayName = "Residential",
		Color = Color3.fromRGB(82, 196, 110),
		Transparency = 0.35,
		Paintable = true,
		DemandKey = "R",
		TemplateFolder = "Residential",
	},

	Commercial = {
		Name = "Commercial",
		DisplayName = "Commercial",
		Color = Color3.fromRGB(70, 160, 230),
		Transparency = 0.35,
		Paintable = true,
		DemandKey = "C",
		TemplateFolder = "Commercial",
	},

	-- Offices are disabled for now: kept valid so saved cities with Office lots still
	-- load, but not paintable, so the UI and the paint remote both reject new ones.
	Office = {
		Name = "Office",
		DisplayName = "Office",
		Color = Color3.fromRGB(120, 120, 205),
		Transparency = 0.35,
		Paintable = false,
		DemandKey = "O",
		TemplateFolder = "Office",
	},

	Industrial = {
		Name = "Industrial",
		DisplayName = "Industrial",
		Color = Color3.fromRGB(220, 185, 55),
		Transparency = 0.35,
		Paintable = true,
		DemandKey = "I",
		TemplateFolder = "Industrial",
	},
}

ZoneTypes.Definitions = table.freeze(DEFINITIONS)

ZoneTypes.Order = table.freeze({
	"None",
	"Residential",
	"Commercial",
	"Office",
	"Industrial",
}) :: { ZoneName }

ZoneTypes.Paintable = table.freeze({
	"Residential",
	"Commercial",
	"Industrial",
}) :: { ZoneName }

local colors: { [string]: Color3 } = {}
local transparency: { [string]: number } = {}
local isValid: { [string]: boolean } = {}
local isPaintable: { [string]: boolean } = {}
local demandKeys: { [string]: string } = {}
local templateFolders: { [string]: string } = {}

for _, zoneName in ZoneTypes.Order do
	local info = DEFINITIONS[zoneName]

	isValid[zoneName] = true
	colors[zoneName] = info.Color
	transparency[zoneName] = info.Transparency

	if info.Paintable then
		isPaintable[zoneName] = true
	end

	if info.DemandKey then
		demandKeys[zoneName] = info.DemandKey
	end

	if info.TemplateFolder then
		templateFolders[zoneName] = info.TemplateFolder
	end
end

ZoneTypes.Colors = table.freeze(colors)
ZoneTypes.Transparency = table.freeze(transparency)
ZoneTypes.IsValid = table.freeze(isValid)
ZoneTypes.IsPaintable = table.freeze(isPaintable)
ZoneTypes.DemandKeys = table.freeze(demandKeys)
ZoneTypes.TemplateFolders = table.freeze(templateFolders)

function ZoneTypes.isValid(value: any): boolean
	return typeof(value) == "string" and ZoneTypes.IsValid[value] == true
end

function ZoneTypes.isPaintable(value: any): boolean
	return typeof(value) == "string" and ZoneTypes.IsPaintable[value] == true
end

function ZoneTypes.getInfo(zoneName: ZoneName): ZoneInfo
	return DEFINITIONS[zoneName]
end

function ZoneTypes.getColor(zoneName: ZoneName): Color3
	return DEFINITIONS[zoneName].Color
end

function ZoneTypes.getTransparency(zoneName: ZoneName): number
	return DEFINITIONS[zoneName].Transparency
end

function ZoneTypes.getDemandKey(zoneName: ZoneName): string?
	return DEFINITIONS[zoneName].DemandKey
end

function ZoneTypes.getTemplateFolder(zoneName: ZoneName): string?
	return DEFINITIONS[zoneName].TemplateFolder
end

function ZoneTypes.isResidential(zoneName: string): boolean
	return zoneName == "Residential"
end

return table.freeze(ZoneTypes)