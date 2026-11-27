--!strict
--[[
	Palette
	-------
	Suit color schemes. Keys used by the builder:
		Suit       primary suit color (webbed areas)
		Accent     secondary suit color (sides, legs, upper arms)
		Web        raised web-line color
		Emblem     chest/back spider emblem
		LensFrame  lens border
		Lens       lens fill
		Shooter    web-shooter metal
		ShooterDark web-shooter dark trim
		Sole       boot soles
	Add your own palette and pass its name to Builder.build({ palette = "MyPalette" }).
]]

export type Palette = {
	Suit: Color3,
	Accent: Color3,
	Web: Color3,
	Emblem: Color3,
	LensFrame: Color3,
	Lens: Color3,
	Shooter: Color3,
	ShooterDark: Color3,
	Sole: Color3,
	LensReflectance: number?,
}

local Palette: { [string]: Palette } = {}

-- Crimson and midnight blue: the classic web-slinger look.
Palette.Classic = {
	Suit = Color3.fromRGB(178, 20, 33),
	Accent = Color3.fromRGB(27, 47, 120),
	Web = Color3.fromRGB(30, 8, 12),
	Emblem = Color3.fromRGB(16, 15, 19),
	LensFrame = Color3.fromRGB(14, 14, 17),
	Lens = Color3.fromRGB(236, 241, 247),
	Shooter = Color3.fromRGB(160, 166, 178),
	ShooterDark = Color3.fromRGB(42, 45, 54),
	Sole = Color3.fromRGB(104, 14, 24),
	LensReflectance = 0.22,
}

-- Black suit with gunmetal webbing and smoky lenses.
Palette.Noir = {
	Suit = Color3.fromRGB(22, 22, 26),
	Accent = Color3.fromRGB(34, 35, 41),
	Web = Color3.fromRGB(92, 95, 104),
	Emblem = Color3.fromRGB(196, 199, 206),
	LensFrame = Color3.fromRGB(8, 8, 10),
	Lens = Color3.fromRGB(170, 176, 186),
	Shooter = Color3.fromRGB(120, 124, 134),
	ShooterDark = Color3.fromRGB(20, 21, 25),
	Sole = Color3.fromRGB(14, 14, 16),
	LensReflectance = 0.35,
}

-- Charcoal and gold stealth suit.
Palette.Gilded = {
	Suit = Color3.fromRGB(28, 26, 30),
	Accent = Color3.fromRGB(46, 42, 40),
	Web = Color3.fromRGB(201, 160, 72),
	Emblem = Color3.fromRGB(214, 172, 80),
	LensFrame = Color3.fromRGB(150, 116, 46),
	Lens = Color3.fromRGB(255, 236, 190),
	Shooter = Color3.fromRGB(201, 160, 72),
	ShooterDark = Color3.fromRGB(30, 28, 30),
	Sole = Color3.fromRGB(20, 19, 21),
	LensReflectance = 0.3,
}

-- White and teal arctic suit.
Palette.Arctic = {
	Suit = Color3.fromRGB(226, 232, 238),
	Accent = Color3.fromRGB(24, 92, 112),
	Web = Color3.fromRGB(70, 140, 160),
	Emblem = Color3.fromRGB(22, 64, 80),
	LensFrame = Color3.fromRGB(18, 40, 52),
	Lens = Color3.fromRGB(140, 236, 255),
	Shooter = Color3.fromRGB(180, 190, 200),
	ShooterDark = Color3.fromRGB(32, 44, 52),
	Sole = Color3.fromRGB(30, 60, 72),
	LensReflectance = 0.3,
}

return Palette
