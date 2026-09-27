--!strict
-- NameGen
-- Library module (no lifecycle, no state): builds citizen first names and family names
-- by mixing big pools of parts, so every citizen gets a varied, plausible name.

local NameGen = {}

-- First names are split by gender so a household's father/mother and children can be
-- named to match their gender. NameGen.firstName(rng) with no gender picks either pool.
local FIRST_MALE = {
	"Aaron", "Adrian", "Alan", "Albert", "Alex", "Andre", "Anton", "Arlo", "Bart", "Ben",
	"Bruno", "Caleb", "Carl", "Cole", "Conor", "Dario", "Dean", "Dmitri", "Dorian", "Eli",
	"Elias", "Elliot", "Emil", "Enzo", "Felix", "Finn", "Floyd", "Gabriel", "Gideon", "Hassan",
	"Hugo", "Idris", "Ivan", "Jonas", "Kai", "Karl", "Lars", "Leo", "Liam", "Lucas",
	"Mads", "Marco", "Mateo", "Milo", "Nadir", "Niko", "Noah", "Omar", "Oscar", "Otto",
	"Paolo", "Pavel", "Quinn", "Rafael", "Ravi", "Reuben", "Rocco", "Rory", "Sasha", "Soren",
	"Sven", "Theo", "Tobias", "Tomas", "Victor", "Vlad", "Wade", "Xander", "Yusuf", "Zane",
	"Cyrus", "Bjorn",
}
local FIRST_FEMALE = {
	"Ada", "Amara", "Anika", "Anya", "Aria", "Astrid", "Bianca", "Camila", "Cara", "Carmen",
	"Cora", "Dahlia", "Dana", "Delia", "Dilara", "Elena", "Elif", "Elsa", "Esme", "Esra",
	"Farah", "Fern", "Freya", "Gemma", "Greta", "Hana", "Hazel", "Ines", "Ingrid", "Iris",
	"Isolde", "Jenna", "Juna", "Kira", "Lara", "Leila", "Lena", "Lila", "Liv", "Lucia",
	"Maeve", "Maren", "Maya", "Mei", "Mira", "Nadia", "Noor", "Nora", "Nova", "Olivia",
	"Petra", "Priya", "Rania", "Rosa", "Saira", "Sana", "Sasha", "Selin", "Sienna", "Sofia",
	"Stella", "Suri", "Talia", "Tara", "Thea", "Uma", "Vera", "Wren", "Yara", "Yuki",
	"Zara", "Zoe",
}

-- Family names are mixed from a root + an optional suffix ("" leaves the root standalone).
-- 130 roots x 40 distinct suffixes => ~5,200 plausible family names from a compact pool of
-- "subnames" -- far more than a hand-written list, and trivially extended by adding parts.
local FAM_ROOT = {
	"Ash", "Ald", "Aber", "Ack", "Bram", "Brad", "Black", "Brook", "Brid", "Bex",
	"Cald", "Carl", "Cope", "Cross", "Comb", "Cren", "Crane", "Dane", "Day", "Dun",
	"Dale", "Darn", "Dorn", "East", "Eld", "Elm", "Ever", "Fair", "Far", "Fern",
	"Foss", "Frith", "Gale", "Gar", "Gold", "Gore", "Green", "Hale", "Hart", "Hask",
	"Haw", "Heath", "Holt", "Holm", "Hud", "Iron", "Kemp", "Kirk", "Lake", "Lang",
	"Lark", "Led", "Lind", "Lyn", "Marsh", "Mead", "Med", "Mor", "Nash", "Norr",
	"North", "Oak", "Ock", "Orm", "Pen", "Pim", "Pres", "Quar", "Quill", "Rad",
	"Ral", "Red", "Ross", "Roth", "Rye", "Sax", "Sel", "Shaw", "Skel", "Stan",
	"Stone", "Strad", "Tan", "Tarn", "Thatch", "Thorn", "Vale", "Vane", "Wake", "Wal",
	"Wel", "West", "Whit", "White", "Wick", "Wind", "Wol", "Yard", "Yarn", "Bart",
	"Brace", "Cobb", "Dell", "Esk", "Garr", "Holl", "Knap", "Lock", "Mapp", "Pad",
	"Quen", "Raby", "Sable", "Tipp", "Upt", "Vint", "Wexh", "Yale", "Brim", "Crag",
	"Dorr", "Fenn", "Grim", "Harl", "Mell", "Pell", "Rook", "Tern", "Wyn", "Cobble",
}
local FAM_SUFFIX = {
	"", "", "",
	"ton", "ford", "wood", "well", "field", "son", "berg", "ridge", "brook", "dale", "worth",
	"man", "by", "ley", "more", "wick", "ham", "stead", "burn", "wall", "gate", "hill", "shaw",
	"combe", "den", "leigh", "mont", "stone", "thorpe", "win", "low", "moor", "cliff", "bury",
	"court", "haven", "crest", "mere", "grove",
}

function NameGen.firstName(rng: Random, gender: string?): string
	local pool = if gender == "M" then FIRST_MALE
		elseif gender == "F" then FIRST_FEMALE
		elseif rng:NextNumber() < 0.5 then FIRST_MALE
		else FIRST_FEMALE
	return pool[rng:NextInteger(1, #pool)]
end

function NameGen.familyName(rng: Random): string
	local root = FAM_ROOT[rng:NextInteger(1, #FAM_ROOT)]
	local suffix = FAM_SUFFIX[rng:NextInteger(1, #FAM_SUFFIX)]
	return root .. suffix
end

function NameGen.fullName(rng: Random, family: string?): string
	return NameGen.firstName(rng) .. " " .. (family or NameGen.familyName(rng))
end

return table.freeze(NameGen)
