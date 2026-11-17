
ForeverScribeDB = {
	["addonVersion"] = "0.8.4",
	["chars"] = {
		["Forever-Test:Pixelpop"] = {
			["achievements"] = {
				["categories"] = {
					[15579] = {
						["done"] = 1,
						["n"] = 2,
						["name"] = "Mage Challenges",
						["parent"] = -1,
					},
					[15600] = {
						["done"] = 0,
						["n"] = 1,
						["name"] = "Exploration",
						["parent"] = -1,
					},
				},
				["earned"] = 1,
				["earnedAccount"] = 2,
				["list"] = {
					[50001] = {
						["c"] = 15579,
						["d"] = "2026-11-12",
						["done"] = true,
						["lp"] = 5,
						["n"] = "Frost Adept",
					},
					[50002] = {
						["c"] = 15579,
						["lp"] = 10,
						["n"] = "Polymorph Master",
						["q"] = "1/2",
						["todo"] = {
							"Polymorph a humanoid", -- [1]
						},
					},
					[50003] = {
						["account"] = true,
						["c"] = 15600,
						["d"] = "2026-10-01",
						["n"] = "Explore Loch Modan",
						["p"] = 5,
					},
				},
				["points"] = 15,
				["scannedAt"] = 1763250042,
				["total"] = 3,
			},
			["actionbars"] = {
				["capturedAt"] = 1763250003,
				["slots"] = {
					{
						["id"] = 133,
						["name"] = "Fireball",
						["type"] = "spell",
					}, -- [1]
					{
						["id"] = 2589,
						["name"] = "Linen Cloth",
						["type"] = "item",
					}, -- [2]
					{
						["id"] = 121,
						["name"] = "Sheep",
						["type"] = "macro",
					}, -- [3]
				},
			},
			["addons"] = {
				["capturedAt"] = 1763250003,
				["count"] = 3,
				["list"] = {
					{
						["enabled"] = true,
						["loadable"] = true,
						["loaded"] = true,
						["name"] = "ForeverScribe",
						["title"] = "ForeverScribe",
						["version"] = "0.3.0",
					}, -- [1]
					{
						["enabled"] = true,
						["loadable"] = true,
						["loaded"] = true,
						["name"] = "Polestar",
						["title"] = "Polestar",
						["version"] = "1.4.2",
					}, -- [2]
					{
						["loadable"] = false,
						["loaded"] = false,
						["name"] = "OldThing",
						["reason"] = "DISABLED",
						["title"] = "Old Thing",
					}, -- [3]
				},
			},
			["bindings"] = {
				["capturedAt"] = 1763250003,
				["list"] = {
					{
						["action"] = "MOVEFORWARD",
						["cat"] = "BINDING_HEADER_MOVEMENT",
						["key1"] = "W",
						["key2"] = "UP",
					}, -- [1]
					{
						["action"] = "JUMP",
						["cat"] = "BINDING_HEADER_MOVEMENT",
						["key1"] = "SPACE",
					}, -- [2]
				},
			},
			["collections"] = {
				["mounts"] = {
					[11] = {
						["n"] = "Black Ram",
						["s"] = 6896,
					},
				},
				["numMounts"] = 1,
				["numPets"] = 1,
				["numToys"] = 1,
				["pets"] = {
					{
						["l"] = 1,
						["n"] = "Mechanical Squirrel",
						["s"] = 40,
					}, -- [1]
				},
				["scannedAt"] = 1763250030,
				["toys"] = {
					[1973] = "Orb of Deception",
				},
			},
			["currencies"] = {
				["list"] = {
					{
						["group"] = "Player vs. Player",
						["id"] = 1901,
						["max"] = 75000,
						["name"] = "Honor Points",
						["qty"] = 150,
					}, -- [1]
					{
						["group"] = "Legacy",
						["id"] = 4300,
						["name"] = "Legacy Marks",
						["qty"] = 3,
					}, -- [2]
				},
				["scannedAt"] = 1763250030,
			},
			["equipSlots"] = {
				[9] = "|cff1eff00|Hitem:6268:0:0:0:0:0:0:0:23|h[Pioneer Bracers]|h|r",
			},
			["equipmentSets"] = {
				["scannedAt"] = 1763250003,
				["sets"] = {
				},
			},
			["events"] = {
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 23,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-9ff6-1:1",
					["payload"] = {
						["level"] = 23,
						["money"] = 123456,
						["version"] = "0.8.4",
						["zone"] = "Loch Modan",
					},
					["schema"] = 1,
					["source"] = "addon",
					["t"] = 1763250000,
					["type"] = "SESSION_START",
				}, -- [1]
			},
			["explored"] = {
				["scannedAt"] = 1763250035,
				["zones"] = {
					[1426] = {
						["at"] = 1763250035,
						["continent"] = "Eastern Kingdoms",
						["n"] = 0,
						["name"] = "Dun Morogh",
					},
					[1432] = {
						["areas"] = {
							"Thelsamar", -- [1]
							"Silver Stream Mine", -- [2]
						},
						["at"] = 1763250035,
						["continent"] = "Eastern Kingdoms",
						["n"] = 2,
						["name"] = "Loch Modan",
					},
				},
				["zonesScanned"] = 2,
				["zonesWithExploration"] = 1,
			},
			["key"] = "Forever-Test:Pixelpop",
			["lastSeq"] = 1,
			["legacy"] = {
				["points"] = {
					["currencyID"] = 4225,
					["max"] = 10,
					["maxAvailable"] = 10,
					["spent"] = 3,
					["spentInTree"] = 3,
					["unspent"] = 2,
				},
				["track"] = {
					["earned"] = 120,
					["level"] = 3,
					["maxLevel"] = 20,
					["name"] = "Legacy",
					["threshold"] = 500,
					["unlocked"] = true,
					["week"] = 3,
				},
				["trees"] = {
					{
						["configID"] = 62,
						["currency"] = {
							["currencyID"] = 4225,
							["max"] = 10,
							["maxAvailable"] = 10,
							["spent"] = 3,
							["spentInTree"] = 3,
							["unspent"] = 2,
						},
						["key"] = "adventure",
						["name"] = "Legacy Adventure",
						["points"] = 3,
						["talents"] = {
							{
								["max"] = 1,
								["name"] = "Swift Travels",
								["nodeID"] = 110298,
								["rank"] = 1,
								["spellID"] = 1400001,
								["type"] = 0,
							}, -- [1]
							{
								["canBuy"] = true,
								["max"] = 3,
								["name"] = "Gatherer's Fortune",
								["nodeID"] = 110299,
								["rank"] = 2,
								["spellID"] = 1400002,
								["type"] = 0,
							}, -- [2]
							{
								["canBuy"] = true,
								["max"] = 1,
								["name"] = "Hearty Appetite",
								["nodeID"] = 110300,
								["rank"] = 0,
								["spellID"] = 1400003,
								["type"] = 0,
							}, -- [3]
						},
						["treeID"] = 1188,
					}, -- [1]
				},
				["unlocked"] = true,
			},
			["lockouts"] = {
				["list"] = {
					{
						["bosses"] = "2/6",
						["difficulty"] = "Normal",
						["instanceID"] = 36,
						["locked"] = true,
						["name"] = "The Deadmines",
						["resetAt"] = 1763336431,
						["size"] = 5,
					}, -- [1]
				},
				["scannedAt"] = 1763250031,
			},
			["macros"] = {
				["account"] = {
					"Mount", -- [1]
				},
				["capturedAt"] = 1763250003,
				["character"] = {
					"Sheep", -- [1]
				},
				["numAccount"] = 1,
				["numCharacter"] = 1,
			},
			["mailPending"] = {
				["capturedAt"] = 1763250030,
				["hasNew"] = false,
				["senders"] = {
				},
			},
			["npcs"] = {
				["2327:1453"] = {
					["first"] = 1763250040,
					["id"] = 2327,
					["kind"] = "gossip",
					["map"] = 1453,
					["n"] = 2,
					["name"] = "Shaina Fuller",
					["r"] = 5,
					["spots"] = {
						{
							["n"] = 2,
							["t"] = 1763250100,
							["x"] = 52.64,
							["y"] = 44.9,
						}, -- [1]
					},
					["sub"] = "First Aid Trainer",
					["t"] = 1763250100,
					["x"] = 52.64,
					["y"] = 44.9,
					["zone"] = "Stormwind City",
				},
				["5150:1455"] = {
					["first"] = 1763250160,
					["id"] = 5150,
					["kind"] = "gossip",
					["map"] = 1455,
					["n"] = 1,
					["name"] = "Nissa Firestone",
					["r"] = 5,
					["spots"] = {
						{
							["n"] = 1,
							["t"] = 1763250160,
							["x"] = 50.1,
							["y"] = 50.2,
						}, -- [1]
					},
					["sub"] = "First Aid Trainer",
					["t"] = 1763250160,
					["x"] = 50.1,
					["y"] = 50.2,
					["zone"] = "Ironforge",
				},
				["990001:1429"] = {
					["first"] = 1763250220,
					["id"] = 990001,
					["kind"] = "vendor",
					["map"] = 1429,
					["n"] = 1,
					["name"] = "Quartermaster Vell",
					["r"] = 5,
					["spots"] = {
						{
							["n"] = 1,
							["t"] = 1763250220,
							["x"] = 44,
							["y"] = 66,
						}, -- [1]
					},
					["sub"] = "Supplies",
					["t"] = 1763250220,
					["x"] = 44,
					["y"] = 66,
					["zone"] = "Elwynn Forest",
				},
			},
			["questTitles"] = {
				[33] = "Collecting Kelp",
				[783] = "A Threat Within",
			},
			["reputation"] = {
				["count"] = 4,
				["factions"] = {
					{
						["group"] = "Alliance",
						["id"] = 72,
						["max"] = 9000,
						["min"] = 3000,
						["name"] = "Stormwind",
						["standing"] = 5,
						["value"] = 4000,
						["watched"] = true,
					}, -- [1]
					{
						["group"] = "Alliance",
						["id"] = 47,
						["max"] = 3000,
						["min"] = 0,
						["name"] = "Ironforge",
						["standing"] = 4,
						["value"] = 2500,
					}, -- [2]
					{
						["group"] = "Alliance",
						["id"] = 54,
						["max"] = 21000,
						["min"] = 9000,
						["name"] = "Gnomeregan",
						["standing"] = 6,
						["value"] = 9500,
					}, -- [3]
					{
						["atWar"] = true,
						["group"] = "Other",
						["id"] = 15,
						["max"] = -6000,
						["min"] = -42000,
						["name"] = "Defias Brotherhood",
						["standing"] = 1,
						["value"] = -42000,
					}, -- [4]
				},
				["scannedAt"] = 1763250030,
				["watched"] = 72,
			},
			["sessions"] = {
				{
					["events"] = 1,
					["id"] = "1763250000-9ff6-1",
					["last"] = 1763250000,
					["level"] = 23,
					["money"] = 123456,
					["start"] = 1763250000,
					["xp"] = 1200,
				}, -- [1]
			},
			["snapshot"] = {
				["addonVersion"] = "0.8.4",
				["bags"] = {
					["free"] = 25,
					["items"] = {
						[2589] = {
							["count"] = 7,
							["itemID"] = 2589,
							["link"] = "|cff1eff00|Hitem:2589:0:0:0:0:0:0:0:23|h[Linen Cloth]|h|r",
							["name"] = "Linen Cloth",
							["quality"] = 1,
						},
						[3647] = {
							["count"] = 1,
							["equipLoc"] = "INVTYPE_WRIST",
							["ilvl"] = 26,
							["itemID"] = 3647,
							["link"] = "|cff1eff00|Hitem:3647:0:0:0:0:0:0:0:23|h[Bright Bracers]|h|r",
							["name"] = "Bright Bracers",
							["quality"] = 2,
							["reqLevel"] = 21,
							["stats"] = {
								["ITEM_MOD_INTELLECT_SHORT"] = 5,
								["ITEM_MOD_SPIRIT_SHORT"] = 2,
							},
							["subType"] = "Cloth",
						},
						[6948] = {
							["count"] = 1,
							["itemID"] = 6948,
							["link"] = "|cff1eff00|Hitem:6948:0:0:0:0:0:0:0:23|h[Hearthstone]|h|r",
							["name"] = "Hearthstone",
							["quality"] = 1,
						},
					},
					["slots"] = 28,
				},
				["buffs"] = {
					{
						["dur"] = 1800,
						["n"] = "Arcane Intellect",
						["rem"] = 1470,
						["s"] = 1459,
						["self"] = true,
					}, -- [1]
				},
				["capturedAt"] = 1763250000,
				["durability"] = {
					["avg"] = 86,
					["broken"] = 0,
					["capturedAt"] = 1763250030,
					["damaged"] = {
						["wrist"] = 86,
					},
					["items"] = 1,
					["min"] = 86,
				},
				["equipment"] = {
					["wrist"] = {
						["dur"] = 30,
						["durMax"] = 35,
						["equipLoc"] = "INVTYPE_WRIST",
						["ilvl"] = 18,
						["itemID"] = 6268,
						["link"] = "|cff1eff00|Hitem:6268:0:0:0:0:0:0:0:23|h[Pioneer Bracers]|h|r",
						["name"] = "Pioneer Bracers",
						["quality"] = 2,
						["reqLevel"] = 13,
						["slot"] = 9,
						["stats"] = {
							["ITEM_MOD_INTELLECT_SHORT"] = 3,
						},
						["subType"] = "Cloth",
					},
				},
				["guild"] = {
					["name"] = "Muffin Mafia",
					["rank"] = "Member",
					["rankIndex"] = 3,
				},
				["hearth"] = "Thelsamar",
				["identity"] = {
					["class"] = "MAGE",
					["classID"] = 8,
					["client"] = {
						["build"] = "70532",
						["toc"] = 16001,
						["version"] = "1.60.1",
					},
					["faction"] = "Alliance",
					["guild"] = "Muffin Mafia",
					["identitySecret"] = false,
					["name"] = "Pixelpop",
					["race"] = "Gnome",
					["raceID"] = 7,
					["realm"] = "Forever-Test",
					["sex"] = 2,
				},
				["level"] = 23,
				["location"] = {
					["inInstance"] = false,
					["instance"] = {
						["difficulty"] = "",
						["difficultyID"] = 0,
						["instanceID"] = 0,
						["maxPlayers"] = 5,
						["name"] = "Loch Modan",
						["type"] = "none",
					},
					["mapID"] = 1432,
					["mapName"] = "Loch Modan",
					["minimap"] = "Thelsamar",
					["subzone"] = "Thelsamar",
					["x"] = 35.12,
					["y"] = 47.21,
					["zone"] = "Loch Modan",
				},
				["maxLevel"] = 60,
				["mode"] = {
					["experiencePreset"] = "enhanced",
					["gameMode"] = 0,
					["gameModeRecordID"] = 18,
				},
				["money"] = 123456,
				["played"] = {
					["at"] = 1763250008,
					["level"] = 3600,
					["total"] = 360000,
				},
				["pvp"] = {
					["flagged"] = true,
					["honor"] = 150,
					["honorLevel"] = 0,
					["honorMax"] = 0,
					["lifetimeHK"] = 12,
					["lifetimeMaxRank"] = 0,
					["rank"] = {
						["earned"] = 0,
						["level"] = 0,
						["maxLevel"] = 14,
						["threshold"] = 100,
						["week"] = 3,
					},
					["season"] = 1,
					["seasonEndsAt"] = 1764978030,
					["sessionDK"] = 0,
					["sessionHK"] = 1,
					["yesterdayDK"] = 0,
					["yesterdayHK"] = 3,
				},
				["quests"] = {
					{
						["complete"] = false,
						["level"] = 20,
						["obj"] = {
							{
								["done"] = false,
								["have"] = 1,
								["need"] = 4,
								["text"] = "Miners' League Crates",
							}, -- [1]
						},
						["questID"] = 307,
						["title"] = "Filthy Paws",
						["zone"] = "Loch Modan",
					}, -- [1]
				},
				["questsCompleted"] = {
					7, -- [1]
					33, -- [2]
					783, -- [3]
				},
				["questsCompletedAt"] = 1763250000,
				["rested"] = 500,
				["resting"] = false,
				["session"] = "1763250000-9ff6-1",
				["skills"] = {
					{
						["group"] = "Professions",
						["max"] = 150,
						["name"] = "Tailoring",
						["rank"] = 75,
						["skillID"] = 197,
					}, -- [1]
					{
						["group"] = "Secondary Skills",
						["max"] = 150,
						["name"] = "First Aid",
						["rank"] = 80,
						["skillID"] = 129,
					}, -- [2]
				},
				["spells"] = {
					[116] = {
						["name"] = "Frostbolt",
						["sub"] = "Rank 3",
						["tab"] = "Mage",
					},
					[133] = {
						["name"] = "Fireball",
						["sub"] = "Rank 4",
						["tab"] = "Mage",
					},
				},
				["stats"] = {
					["armor"] = 230,
					["attackPower"] = 30,
					["block"] = 0,
					["capturedAt"] = 1763250030,
					["defense"] = 115,
					["dodge"] = 3.2,
					["healing"] = 12,
					["health"] = 640,
					["itemLevel"] = 17.9,
					["manaRegen"] = {
						["base"] = 12,
						["casting"] = 2,
						["per"] = "5s",
					},
					["meleeCrit"] = 5.1,
					["meleeDamage"] = {
						20, -- [1]
						31, -- [2]
					},
					["meleeHaste"] = 0,
					["meleeHit"] = 0,
					["meleeSpeed"] = 2.9,
					["parry"] = 0,
					["power"] = 910,
					["powerType"] = 0,
					["primary"] = {
						["agi"] = {
							["base"] = 25,
							["buff"] = 0,
							["eff"] = 25,
						},
						["int"] = {
							["base"] = 70,
							["buff"] = 8,
							["eff"] = 78,
						},
						["spi"] = {
							["base"] = 60,
							["buff"] = 2,
							["eff"] = 62,
						},
						["sta"] = {
							["base"] = 38,
							["buff"] = 2,
							["eff"] = 40,
						},
						["str"] = {
							["base"] = 20,
							["buff"] = 2,
							["eff"] = 22,
						},
					},
					["rangedAttackPower"] = 10,
					["rangedCrit"] = 5.1,
					["resist"] = {
						["frost"] = 10,
					},
					["spellCrit"] = 4.5,
					["spellHaste"] = 0,
					["spellHit"] = 3,
					["spellPen"] = 0,
					["spellPower"] = {
						["arcane"] = 12,
						["fire"] = 12,
						["frost"] = 28,
						["holy"] = 12,
						["nature"] = 12,
						["shadow"] = 12,
					},
					["spellPowerMax"] = 28,
				},
				["talentPointsUnspent"] = 1,
				["talents"] = {
					["system"] = "classic",
					["trees"] = {
						{
							["name"] = "Arcane",
							["points"] = 2,
							["talents"] = {
								{
									["col"] = 1,
									["max"] = 2,
									["name"] = "Arcane Subtlety",
									["rank"] = 2,
									["tier"] = 1,
								}, -- [1]
							},
						}, -- [1]
						{
							["name"] = "Fire",
							["points"] = 5,
							["talents"] = {
								{
									["col"] = 1,
									["max"] = 5,
									["name"] = "Improved Fireball",
									["rank"] = 5,
									["tier"] = 1,
								}, -- [1]
								{
									["col"] = 2,
									["max"] = 5,
									["name"] = "Impact",
									["rank"] = 0,
									["tier"] = 1,
								}, -- [2]
							},
						}, -- [2]
					},
					["unspent"] = 1,
				},
				["xp"] = 1200,
				["xpMax"] = 13000,
			},
			["statistics"] = {
				["count"] = 2,
				["scannedAt"] = 1763250042,
				["values"] = {
					[60001] = {
						["c"] = "Character",
						["n"] = "Total deaths",
						["v"] = 12,
					},
					[60003] = {
						["c"] = "Character",
						["n"] = "Creatures killed",
						["v"] = 347,
					},
				},
			},
			["titles"] = {
				["count"] = 1,
				["current"] = 1,
				["currentName"] = "Private %s",
				["known"] = {
					"Private %s", -- [1]
				},
				["scannedAt"] = 1763250030,
			},
		},
	},
	["lastChar"] = "Forever-Test:Pixelpop",
	["schema"] = 1,
	["sessionCounter"] = 1,
	["settings"] = {
	},
}
