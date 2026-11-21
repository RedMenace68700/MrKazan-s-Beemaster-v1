-- Item names and helpers to read bee stacks as returned by the inventory controller.
--
-- summarize() turns a full stack table into a small summary. The robot sends only
-- summaries to the server, and the server keeps only summaries in its inventory:
--   { name, size, kind = "princess"|"drone"|"queen", species, inactive,
--     analyzed, natural, generation }
-- Non-bee items keep only name and size.

local bees = {}

bees.ITEM = {
  drone = "Forestry:beeDroneGE",
  princess = "Forestry:beePrincessGE",
  queen = "Forestry:beeQueenGE",
  comb = "Forestry:beeComb",
  honey = "Forestry:honeyDrop",
}

local KIND_BY_NAME = {
  [bees.ITEM.drone] = "drone",
  [bees.ITEM.princess] = "princess",
  [bees.ITEM.queen] = "queen",
}

local LABEL_SUFFIX = { drone = " Drone", princess = " Princess", queen = " Queen" }

-- "princess", "drone", "queen" or nil for anything that is not a bee.
function bees.kind(name)
  return KIND_BY_NAME[name]
end

local function species_name(chromosomes)
  if type(chromosomes) ~= "table" then return nil end
  local species = chromosomes.species
  if type(species) == "table" then return species.name end
  if type(species) == "string" then return species end
  return nil
end

local function species_from_label(label, kind)
  if type(label) ~= "string" then return nil end
  local suffix = LABEL_SUFFIX[kind]
  if suffix and label:sub(-#suffix) == suffix then
    return label:sub(1, -#suffix - 1)
  end
  return nil
end

function bees.summarize(stack)
  if type(stack) ~= "table" or type(stack.name) ~= "string" then return nil end
  local summary = { name = stack.name, size = stack.size or 1 }
  local kind = KIND_BY_NAME[stack.name]
  if not kind then return summary end
  summary.kind = kind
  local individual = type(stack.individual) == "table" and stack.individual or {}
  summary.analyzed = individual.isAnalyzed == true
  summary.natural = individual.isNatural
  summary.generation = individual.generation
  -- The active species is visible for every bee. The inactive one only counts after
  -- analysis; before that a hybrid looks exactly like a pure bee.
  summary.species = species_name(individual.active)
    or species_from_label(stack.label, kind)
    or individual.displayName
  if summary.analyzed then
    summary.inactive = species_name(individual.inactive)
  end
  return summary
end

function bees.same_species(a, b)
  return type(a) == "string" and type(b) == "string" and a:lower() == b:lower()
end

-- true = pure, false = hybrid, nil = unknown (not analyzed or not a bee).
function bees.purity(summary)
  if type(summary) ~= "table" or not summary.kind then return nil end
  if not summary.analyzed or not summary.inactive or not summary.species then return nil end
  return bees.same_species(summary.species, summary.inactive)
end

-- Short text for logs, e.g. "pure Clay princess" or "Diligent/Rural princess".
function bees.describe(summary)
  if type(summary) ~= "table" then return "nothing" end
  if not summary.kind then return string.format("%dx %s", summary.size or 1, summary.name) end
  local purity = bees.purity(summary)
  local species
  if purity == true then
    species = "pure " .. summary.species
  elseif purity == false then
    species = summary.species .. "/" .. summary.inactive
  else
    species = "unanalyzed " .. tostring(summary.species)
  end
  local text = species .. " " .. summary.kind
  if (summary.size or 1) > 1 then text = string.format("%dx %s", summary.size, text) end
  return text
end

return bees
