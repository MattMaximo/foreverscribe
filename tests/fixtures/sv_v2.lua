
ForeverScribeDB = {
	["addonVersion"] = "0.8.2",
	["chars"] = {
		["Forever-Test:Coilbyte"] = {
			["actionbars"] = {
				["capturedAt"] = 1763250108,
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
				["capturedAt"] = 1763250108,
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
				["capturedAt"] = 1763250108,
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
				["scannedAt"] = 1763250108,
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
				["scannedAt"] = 1763250108,
			},
			["equipSlots"] = {
				[9] = "|cff1eff00|Hitem:3647:0:0:0:0:0:0:0:20|h[Bright Bracers]|h|r",
			},
			["equipmentSets"] = {
				["scannedAt"] = 1763250108,
				["sets"] = {
				},
			},
			["events"] = {
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 20,
						["map"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["id"] = "1763250105-8df9-3:1",
					["payload"] = {
						["level"] = 20,
						["money"] = 123456,
						["version"] = "0.8.2",
						["zone"] = "Dun Morogh",
					},
					["schema"] = 1,
					["source"] = "addon",
					["t"] = 1763250105,
					["type"] = "SESSION_START",
				}, -- [1]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 20,
						["map"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["id"] = "1763250105-8df9-3:2",
					["payload"] = {
						["from"] = 140,
						["group"] = "Professions",
						["max"] = 150,
						["skill"] = "Mining",
						["to"] = 141,
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250115,
					["type"] = "PROFESSION_SKILL_UP",
				}, -- [2]
			},
			["explored"] = {
				["scannedAt"] = 1763250113,
				["zones"] = {
					[1426] = {
						["areas"] = {
							"Kharanos", -- [1]
						},
						["at"] = 1763250113,
						["continent"] = "Eastern Kingdoms",
						["n"] = 1,
						["name"] = "Dun Morogh",
					},
					[1432] = {
						["areas"] = {
							"Thelsamar", -- [1]
							"Silver Stream Mine", -- [2]
						},
						["at"] = 1763250113,
						["continent"] = "Eastern Kingdoms",
						["n"] = 2,
						["name"] = "Loch Modan",
					},
				},
				["zonesScanned"] = 2,
				["zonesWithExploration"] = 2,
			},
			["key"] = "Forever-Test:Coilbyte",
			["lastSeq"] = 2,
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
						["resetAt"] = 1763336509,
						["size"] = 5,
					}, -- [1]
				},
				["scannedAt"] = 1763250109,
			},
			["macros"] = {
				["account"] = {
					"Mount", -- [1]
				},
				["capturedAt"] = 1763250108,
				["character"] = {
					"Sheep", -- [1]
				},
				["numAccount"] = 1,
				["numCharacter"] = 1,
			},
			["mailPending"] = {
				["capturedAt"] = 1763250108,
				["hasNew"] = false,
				["senders"] = {
				},
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
						["max"] = 9000,
						["min"] = 3000,
						["name"] = "Ironforge",
						["standing"] = 5,
						["value"] = 3100,
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
				["scannedAt"] = 1763250108,
				["watched"] = 72,
			},
			["sessions"] = {
				{
					["events"] = 2,
					["id"] = "1763250105-8df9-3",
					["last"] = 1763250115,
					["level"] = 20,
					["money"] = 123456,
					["start"] = 1763250105,
					["xp"] = 1200,
				}, -- [1]
			},
			["snapshot"] = {
				["addonVersion"] = "0.8.2",
				["bags"] = {
					["free"] = 25,
					["items"] = {
						[2589] = {
							["count"] = 12,
							["itemID"] = 2589,
							["link"] = "|cff1eff00|Hitem:2589:0:0:0:0:0:0:0:20|h[Linen Cloth]|h|r",
							["name"] = "Linen Cloth",
							["quality"] = 1,
						},
						[6268] = {
							["count"] = 1,
							["equipLoc"] = "INVTYPE_WRIST",
							["ilvl"] = 18,
							["itemID"] = 6268,
							["link"] = "|cff1eff00|Hitem:6268:0:0:0:0:0:0:0:20|h[Pioneer Bracers]|h|r",
							["name"] = "Pioneer Bracers",
							["quality"] = 2,
							["reqLevel"] = 13,
							["stats"] = {
								["ITEM_MOD_INTELLECT_SHORT"] = 3,
							},
							["subType"] = "Cloth",
						},
						[6948] = {
							["count"] = 1,
							["itemID"] = 6948,
							["link"] = "|cff1eff00|Hitem:6948:0:0:0:0:0:0:0:20|h[Hearthstone]|h|r",
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
						["rem"] = 1402,
						["s"] = 1459,
						["self"] = true,
					}, -- [1]
				},
				["capturedAt"] = 1763250105,
				["durability"] = {
					["avg"] = 86,
					["broken"] = 0,
					["capturedAt"] = 1763250108,
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
						["ilvl"] = 26,
						["itemID"] = 3647,
						["link"] = "|cff1eff00|Hitem:3647:0:0:0:0:0:0:0:20|h[Bright Bracers]|h|r",
						["name"] = "Bright Bracers",
						["quality"] = 2,
						["reqLevel"] = 21,
						["slot"] = 9,
						["stats"] = {
							["ITEM_MOD_INTELLECT_SHORT"] = 5,
							["ITEM_MOD_SPIRIT_SHORT"] = 2,
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
					["class"] = "WARLOCK",
					["classID"] = 8,
					["client"] = {
						["build"] = "70532",
						["toc"] = 16001,
						["version"] = "1.60.1",
					},
					["faction"] = "Alliance",
					["guild"] = "Muffin Mafia",
					["identitySecret"] = false,
					["name"] = "Coilbyte",
					["race"] = "Gnome",
					["raceID"] = 7,
					["realm"] = "Forever-Test",
					["sex"] = 2,
				},
				["level"] = 20,
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
					["mapID"] = 1426,
					["mapName"] = "Dun Morogh",
					["minimap"] = "Kharanos",
					["subzone"] = "Kharanos",
					["x"] = 35.12,
					["y"] = 47.21,
					["zone"] = "Dun Morogh",
				},
				["maxLevel"] = 60,
				["mode"] = {
					["experiencePreset"] = "enhanced",
					["gameMode"] = 0,
					["gameModeRecordID"] = 18,
				},
				["money"] = 123456,
				["played"] = {
					["at"] = 1763250113,
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
					["seasonEndsAt"] = 1764978108,
					["sessionDK"] = 0,
					["sessionHK"] = 1,
					["yesterdayDK"] = 0,
					["yesterdayHK"] = 3,
				},
				["quests"] = {
				},
				["questsCompleted"] = {
					7, -- [1]
					33, -- [2]
					307, -- [3]
					783, -- [4]
				},
				["questsCompletedAt"] = 1763250105,
				["rested"] = 500,
				["resting"] = false,
				["session"] = "1763250105-8df9-3",
				["skills"] = {
					{
						["group"] = "Professions",
						["max"] = 150,
						["name"] = "Mining",
						["rank"] = 141,
						["skillID"] = 186,
					}, -- [1]
					{
						["group"] = "Professions",
						["max"] = 150,
						["name"] = "Engineering",
						["rank"] = 150,
						["skillID"] = 202,
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
					["capturedAt"] = 1763250108,
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
			["titles"] = {
				["count"] = 1,
				["current"] = 1,
				["currentName"] = "Private %s",
				["known"] = {
					"Private %s", -- [1]
				},
				["scannedAt"] = 1763250108,
			},
		},
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
				["scannedAt"] = 1763250094,
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
				["scannedAt"] = 1763250082,
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
				["scannedAt"] = 1763250082,
			},
			["equipSlots"] = {
				[9] = "|cff1eff00|Hitem:3647:0:0:0:0:0:0:0:24|h[Bright Bracers]|h|r",
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
					["id"] = "1763250000-f492-1:1",
					["payload"] = {
						["level"] = 23,
						["money"] = 123456,
						["version"] = "0.8.2",
						["zone"] = "Loch Modan",
					},
					["schema"] = 1,
					["source"] = "addon",
					["t"] = 1763250000,
					["type"] = "SESSION_START",
				}, -- [1]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 23,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-f492-1:2",
					["payload"] = {
						["from"] = 23,
						["level"] = 24,
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250040,
					["type"] = "LEVEL_UP",
				}, -- [2]
				{
					["confidence"] = "medium",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-f492-1:3",
					["payload"] = {
						["items"] = {
							{
								["itemID"] = 2589,
								["name"] = "Linen Cloth",
								["qty"] = 5,
								["quality"] = 1,
							}, -- [1]
						},
					},
					["schema"] = 1,
					["source"] = "loot_window",
					["t"] = 1763250040,
					["type"] = "LOOT_WINDOW",
				}, -- [3]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-f492-1:4",
					["payload"] = {
						["itemID"] = 2589,
						["name"] = "Linen Cloth",
						["qty"] = 5,
						["quality"] = 1,
						["reason"] = "loot",
						["total"] = 12,
					},
					["schema"] = 1,
					["source"] = "bag_diff",
					["t"] = 1763250040,
					["type"] = "ITEM_ACQUIRED",
				}, -- [4]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-f492-1:5",
					["payload"] = {
						["itemID"] = 2589,
						["name"] = "Linen Cloth",
						["qty"] = 5,
						["quality"] = 1,
						["reason"] = "loot",
						["total"] = 12,
					},
					["schema"] = 1,
					["source"] = "bag_diff",
					["t"] = 1763250040,
					["type"] = "LOOT",
				}, -- [5]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-f492-1:6",
					["payload"] = {
						["from"] = 80,
						["group"] = "Secondary Skills",
						["max"] = 150,
						["skill"] = "First Aid",
						["to"] = 81,
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250041,
					["type"] = "PROFESSION_SKILL_UP",
				}, -- [6]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250000-f492-1:7",
					["payload"] = {
						["money"] = 1500,
						["questID"] = 307,
						["title"] = "Filthy Paws",
						["xp"] = 1450,
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250042,
					["type"] = "QUEST_COMPLETED",
				}, -- [7]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1432,
						["zone"] = "Loch Modan",
					},
					["id"] = "1763250052-bf90-2:1",
					["payload"] = {
						["level"] = 24,
						["money"] = 123456,
						["version"] = "0.8.2",
						["zone"] = "Loch Modan",
					},
					["schema"] = 1,
					["source"] = "addon",
					["t"] = 1763250052,
					["type"] = "SESSION_START",
				}, -- [8]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["id"] = "1763250052-bf90-2:2",
					["payload"] = {
						["new"] = {
							["ilvl"] = 26,
							["itemID"] = 3647,
							["name"] = "Bright Bracers",
							["quality"] = 2,
						},
						["old"] = {
							["ilvl"] = 18,
							["itemID"] = 6268,
							["name"] = "Pioneer Bracers",
							["quality"] = 2,
						},
						["slot"] = "wrist",
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250062,
					["type"] = "EQUIPMENT_CHANGED",
				}, -- [9]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["id"] = "1763250052-bf90-2:3",
					["payload"] = {
						["from"] = "Loch Modan",
						["fromMapID"] = 1432,
						["mapID"] = 1426,
						["subzone"] = "Kharanos",
						["zone"] = "Dun Morogh",
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250082,
					["type"] = "ZONE_CHANGED",
				}, -- [10]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["id"] = "1763250052-bf90-2:4",
					["payload"] = {
						["delta"] = 600,
						["factionID"] = 47,
						["max"] = 9000,
						["name"] = "Ironforge",
						["standingFrom"] = 4,
						["standingTo"] = 5,
						["to"] = 3100,
					},
					["schema"] = 1,
					["source"] = "faction_diff",
					["t"] = 1763250095,
					["type"] = "REPUTATION_CHANGED",
				}, -- [11]
				{
					["confidence"] = "high",
					["ctx"] = {
						["lvl"] = 24,
						["map"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["id"] = "1763250052-bf90-2:5",
					["payload"] = {
						["areas"] = {
							"Kharanos", -- [1]
						},
						["explored"] = 1,
						["mapID"] = 1426,
						["zone"] = "Dun Morogh",
					},
					["schema"] = 1,
					["source"] = "event",
					["t"] = 1763250097,
					["type"] = "EXPLORATION_DISCOVERED",
				}, -- [12]
			},
			["explored"] = {
				["scannedAt"] = 1763250087,
				["zones"] = {
					[1426] = {
						["areas"] = {
							"Kharanos", -- [1]
						},
						["at"] = 1763250097,
						["continent"] = "Eastern Kingdoms",
						["n"] = 1,
						["name"] = "Dun Morogh",
					},
					[1432] = {
						["areas"] = {
							"Thelsamar", -- [1]
							"Silver Stream Mine", -- [2]
						},
						["at"] = 1763250087,
						["continent"] = "Eastern Kingdoms",
						["n"] = 2,
						["name"] = "Loch Modan",
					},
				},
				["zonesScanned"] = 2,
				["zonesWithExploration"] = 1,
			},
			["key"] = "Forever-Test:Pixelpop",
			["lastSeq"] = 5,
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
						["resetAt"] = 1763336483,
						["size"] = 5,
					}, -- [1]
				},
				["scannedAt"] = 1763250083,
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
			["mail"] = {
				["capturedAt"] = 1763250099,
				["count"] = 2,
				["mails"] = {
					{
						["days"] = 29.5,
						["from"] = "Thomas Miller",
						["money"] = 5000,
						["subject"] = "Your auction sold",
					}, -- [1]
					{
						["days"] = 29.5,
						["from"] = "player",
						["items"] = {
							{
								["count"] = 20,
								["itemID"] = 2589,
								["name"] = "Linen Cloth",
							}, -- [1]
						},
						["money"] = 0,
					}, -- [2]
				},
			},
			["mailPending"] = {
				["capturedAt"] = 1763250082,
				["hasNew"] = false,
				["senders"] = {
				},
			},
			["questTitles"] = {
				[33] = "Collecting Kelp",
				[307] = "Filthy Paws",
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
						["max"] = 9000,
						["min"] = 3000,
						["name"] = "Ironforge",
						["standing"] = 5,
						["value"] = 3100,
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
				["scannedAt"] = 1763250095,
				["watched"] = 72,
			},
			["sessions"] = {
				{
					["ended"] = 1763250047,
					["events"] = 7,
					["id"] = "1763250000-f492-1",
					["last"] = 1763250042,
					["level"] = 23,
					["levelEnd"] = 24,
					["money"] = 123456,
					["moneyEnd"] = 123456,
					["start"] = 1763250000,
					["xp"] = 1200,
					["xpEnd"] = 1200,
				}, -- [1]
				{
					["ended"] = 1763250100,
					["events"] = 5,
					["id"] = "1763250052-bf90-2",
					["last"] = 1763250097,
					["level"] = 24,
					["levelEnd"] = 24,
					["money"] = 123456,
					["moneyEnd"] = 123456,
					["start"] = 1763250052,
					["xp"] = 1200,
					["xpEnd"] = 1200,
				}, -- [2]
			},
			["snapshot"] = {
				["addonVersion"] = "0.8.2",
				["bags"] = {
					["free"] = 25,
					["items"] = {
						[2589] = {
							["count"] = 12,
							["itemID"] = 2589,
							["link"] = "|cff1eff00|Hitem:2589:0:0:0:0:0:0:0:24|h[Linen Cloth]|h|r",
							["name"] = "Linen Cloth",
							["quality"] = 1,
						},
						[6268] = {
							["count"] = 1,
							["equipLoc"] = "INVTYPE_WRIST",
							["ilvl"] = 18,
							["itemID"] = 6268,
							["link"] = "|cff1eff00|Hitem:6268:0:0:0:0:0:0:0:24|h[Pioneer Bracers]|h|r",
							["name"] = "Pioneer Bracers",
							["quality"] = 2,
							["reqLevel"] = 13,
							["stats"] = {
								["ITEM_MOD_INTELLECT_SHORT"] = 3,
							},
							["subType"] = "Cloth",
						},
						[6948] = {
							["count"] = 1,
							["itemID"] = 6948,
							["link"] = "|cff1eff00|Hitem:6948:0:0:0:0:0:0:0:24|h[Hearthstone]|h|r",
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
						["rem"] = 1423,
						["s"] = 1459,
						["self"] = true,
					}, -- [1]
				},
				["capturedAt"] = 1763250100,
				["durability"] = {
					["avg"] = 86,
					["broken"] = 0,
					["capturedAt"] = 1763250082,
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
						["ilvl"] = 26,
						["itemID"] = 3647,
						["link"] = "|cff1eff00|Hitem:3647:0:0:0:0:0:0:0:24|h[Bright Bracers]|h|r",
						["name"] = "Bright Bracers",
						["quality"] = 2,
						["reqLevel"] = 21,
						["slot"] = 9,
						["stats"] = {
							["ITEM_MOD_INTELLECT_SHORT"] = 5,
							["ITEM_MOD_SPIRIT_SHORT"] = 2,
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
				["level"] = 24,
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
					["mapID"] = 1426,
					["mapName"] = "Dun Morogh",
					["minimap"] = "Kharanos",
					["subzone"] = "Kharanos",
					["x"] = 35.12,
					["y"] = 47.21,
					["zone"] = "Dun Morogh",
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
					["seasonEndsAt"] = 1764978082,
					["sessionDK"] = 0,
					["sessionHK"] = 1,
					["yesterdayDK"] = 0,
					["yesterdayHK"] = 3,
				},
				["quests"] = {
				},
				["questsCompleted"] = {
					7, -- [1]
					33, -- [2]
					307, -- [3]
					783, -- [4]
				},
				["questsCompletedAt"] = 1763250052,
				["rested"] = 500,
				["resting"] = false,
				["session"] = "1763250052-bf90-2",
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
						["rank"] = 81,
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
					["capturedAt"] = 1763250082,
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
				["scannedAt"] = 1763250094,
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
				["scannedAt"] = 1763250082,
			},
		},
	},
	["lastChar"] = "Forever-Test:Coilbyte",
	["schema"] = 1,
	["sessionCounter"] = 3,
	["settings"] = {
	},
}
