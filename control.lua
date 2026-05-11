local util = require("util")

---@alias BeltLikeEntity LuaEntity.TransportBelt|LuaEntity.UndergroundBelt|LuaEntity.Splitter|LuaEntity.LinkedBelt|LuaEntity.TransportBeltConnectable|LuaEntity.Ghost

---@class TerminalBelt
---@field indicator?  LuaEntity
---@field entity     BeltLikeEntity
---@field lines      integer[]
---@field list_index integer

---@class Array2D<T>: { [number]: { [number]: T } }
---@alias CurveBelts Array2D<"right"|"left">
---@alias DirectionInteger defines.direction|integer

-- POSD: a relative position + direction used for neighbourhood geometry.
-- px/py are numeric offsets; d is a direction integer.
---@class POSD
---@field px number
---@field py number
---@field d  DirectionInteger

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
storage.terminal_belts     = storage.terminal_belts
storage.terminal_belt_list = storage.terminal_belt_list
storage.hot_belts          = storage.hot_belts
storage.hot_belt_set       = storage.hot_belt_set
storage.scan_cursor        = storage.scan_cursor
storage.hot_cursor         = storage.hot_cursor
storage.curve_belts        = storage.curve_belts

local SCAN_SLICE = settings.global['belt_overflow_poll_frequency'].value
-- Max hot belts to process per tick. Caps UPS impact when many belts back up simultaneously.
local HOT_CAP = settings.global['belt_overflow_hot_cap'].value

-- ---------------------------------------------------------------------------
-- Direction constants (2.0: N=0 E=4 S=8 W=12)
-- ---------------------------------------------------------------------------
local defines_direction = defines.direction
local N, E, S, W = defines_direction.north, defines_direction.east, defines_direction.south, defines_direction.west

---Rotate a POSD 90° increments around the origin.
---@param posd POSD
---@param rotation DirectionInteger
---@return POSD
local function rotate_posd(posd, rotation)
  local x, y, d = posd.px, posd.py, posd.d
  if rotation == S then
    d = (d + 8) % 16; x, y = -x, -y
  elseif rotation == E then
    d = (d + 4) % 16; x, y = -y, x
  elseif rotation == W then
    d = (d + 12) % 16; x, y = y, -x
  end
  return {px=x, py=y, d=d}
end

---Rotate a plain x/y offset by rotation, returning a POSD (d=N).
---@param px number
---@param py number
---@param rotation DirectionInteger
---@return POSD
local function rotate_offset(px, py, rotation)
  return rotate_posd({px=px, py=py, d=N}, rotation)
end

-- ---------------------------------------------------------------------------
-- Entity helpers
-- ---------------------------------------------------------------------------
local function has_real_underground_neighbours(entity)
  return entity and entity.valid and entity.neighbours ~= nil and entity.neighbours.type ~= 'entity-ghost'
end

local function has_real_linked_neighbours(entity)
  return entity and entity.valid and entity.linked_belt_neighbour ~= nil and entity.linked_belt_neighbour.type ~= 'entity-ghost'
end

local function find_ghost_entities_filtered(surface, param)
  local p = util.table.deepcopy(param)
  p.ghost_name = p.name; p.ghost_type = p.type
  p.name = "entity-ghost"; p.type = "entity-ghost"
  return surface.find_entities_filtered(p)
end

local function find_belt_at(surface, x, y, ghosts)
  local param = {position={x, y}, radius=0, type="transport-belt"}
  local t = surface.find_entities_filtered(param)
  if t[1] then return t[1] end
  if ghosts then t = find_ghost_entities_filtered(surface, param); if t[1] then return t[1] end end
  param.type = "underground-belt"
  t = surface.find_entities_filtered(param)
  if t[1] then return t[1] end
  if ghosts then t = find_ghost_entities_filtered(surface, param); if t[1] then return t[1] end end
  param.type = "linked-belt"
  t = surface.find_entities_filtered(param)
  if t[1] then return t[1] end
  if ghosts then t = find_ghost_entities_filtered(surface, param); if t[1] then return t[1] end end
  param.radius = nil; param.type = "splitter"
  t = surface.find_entities_filtered(param)
  if t[1] then return t[1] end
  if ghosts then t = find_ghost_entities_filtered(surface, param); if t[1] then return t[1] end end
  return nil
end


local function is_belt_full(tb)
  local entity = tb.entity
  if not entity.valid then return false end
  for _, line in pairs(tb.lines) do
    if entity.get_transport_line(line).get_item_count() > 0 then
      return true
    end
  end
  return false
end

local function do_overflow(tb)
  local entity = tb.entity
  if not entity.valid then return false end
  local etype  = entity.type
  local pos    = entity.position
  local epx, epy = pos.x, pos.y
  local any_full = false
  local ground_prefill = {}

  for i = 1, #tb.lines do
    local line = tb.lines[i]
    local tl = entity.get_transport_line(line)
    if tl.get_item_count() <= 0 then goto continue end
    any_full = true
    local item_name = tl[1].name

    if etype == "underground-belt" and entity.belt_to_ground_type == "input"
      and has_real_underground_neighbours(entity) then
      if line < 3 then ground_prefill[line] = true; goto continue
      elseif not ground_prefill[line - 2] then goto continue end
    end

    do
      local dir = entity.direction
      local dx, dy = 0, 0
      if (etype == "underground-belt" and entity.belt_to_ground_type == "input")
        or (etype == "linked-belt" and entity.linked_belt_type == "input") then
        dy = 0.25
        dx = (line % 2 == 0) and 0.65 or -0.65
      else
        dy = -1.05
        if etype == "splitter" then dx = (line == 5 or line == 6) and -0.5 or 0.5 end
        dx = dx + ((line % 2 == 0) and 0.23 or -0.23)
      end
      local r = rotate_offset(dx, dy, dir)
      -- Scatter items across the spill zone. Base offset already positions the
      -- spill past the belt end; scatter adds natural spread around that point.
      -- ±0.7 tiles gives a spread comparable to the original spill_item_stack
      -- behaviour without being excessively wide.
      local scatter_x = (math.random() - 0.5) * 1.4
      local scatter_y = (math.random() - 0.5) * 1.4
      local itemstack = {name=item_name, count=1}
      local spill_pos = {epx + r.px + scatter_x, epy + r.py + scatter_y}
      -- Use create_entity at the exact position so items land precisely,
      -- including into lava which destroys them immediately.
      -- If create_entity returns nil the tile is impassable (liquid etc.)
      -- and we simply void the item — correct behaviour for all deadly terrain.
      entity.surface.create_entity{
        name     = "item-on-ground",
        position = spill_pos,
        stack    = itemstack,
      }
      tl.remove_item(itemstack)
    end
    ::continue::
  end
  return any_full
end

-- ---------------------------------------------------------------------------
-- Hot set
-- ---------------------------------------------------------------------------
local function add_to_hot(x, y)
  if storage.hot_belt_set[y] and storage.hot_belt_set[y][x] then return end
  if not storage.hot_belt_set[y] then storage.hot_belt_set[y] = {} end
  storage.hot_belt_set[y][x] = true
  storage.hot_belts[#storage.hot_belts + 1] = {x=x, y=y}
end

local function remove_from_hot(x, y)
  if not (storage.hot_belt_set[y] and storage.hot_belt_set[y][x]) then return end
  storage.hot_belt_set[y][x] = nil
  if next(storage.hot_belt_set[y]) == nil then storage.hot_belt_set[y] = nil end
  local hb = storage.hot_belts
  for i = 1, #hb do
    if hb[i].x == x and hb[i].y == y then
      hb[i] = hb[#hb]; hb[#hb] = nil; return
    end
  end
end

-- ---------------------------------------------------------------------------
-- Terminal belt registry
-- ---------------------------------------------------------------------------
local function cleartermbelt(x, y)
  if not (storage.terminal_belts[y] and storage.terminal_belts[y][x]) then return end
  local belt = storage.terminal_belts[y][x]
  if belt.indicator and belt.indicator.valid then belt.indicator.destroy() end

  local list = storage.terminal_belt_list
  local idx  = belt.list_index
  local tail = list[#list]
  if tail and not (tail.x == x and tail.y == y) then
    list[idx] = tail
    storage.terminal_belts[tail.y][tail.x].list_index = idx
  end
  list[#list] = nil
  if storage.scan_cursor > #list then storage.scan_cursor = #list end

  storage.terminal_belts[y][x] = nil
  if next(storage.terminal_belts[y]) == nil then storage.terminal_belts[y] = nil end
  remove_from_hot(x, y)
end

local function create_indicator(entity)
  if not settings.global['belt_overflow_draw_indicators'].value then return nil end
  local name = "belt-overflow-indicator"
  local pos  = entity.position
  local ipos -- indicator position

  if entity.type == "splitter" then
    name = name .. ((entity.direction % 8 == 0) and "-wide" or "-tall")
    -- splitter spills one tile ahead
    local ahead = rotate_offset(0, -1, entity.direction)
    ipos = {pos.x + ahead.px, pos.y + ahead.py}
  elseif (entity.type == "underground-belt" and entity.belt_to_ground_type == "input")
      or (entity.type == "linked-belt"      and entity.linked_belt_type    == "input") then
    -- input spills beside itself — place two indicators, one each side
    -- (we only create one entity here; use the left-side offset as representative)
    local left = rotate_offset(-0.65, 0.25, entity.direction)
    ipos = {pos.x + left.px, pos.y + left.py}
  else
    -- normal belt: one tile ahead
    local ahead = rotate_offset(0, -1, entity.direction)
    ipos = {pos.x + ahead.px, pos.y + ahead.py}
  end

  return entity.surface.create_entity{name=name, position=ipos}
end

-- ---------------------------------------------------------------------------
-- on_tick
-- ---------------------------------------------------------------------------
local function onTick()
  -- Stage 1: hot set — rotate through up to HOT_CAP entries per tick.
  -- Uses hot_cursor so we don't always hammer the same front-of-list entries.
  local hb     = storage.hot_belts
  local hb_len = #hb
  if hb_len > 0 then
    local hot_cursor = storage.hot_cursor or 0
    local limit      = math.min(hb_len, HOT_CAP)
    local to_cool    = {}  -- {x,y} pairs to evict after the loop
    for _ = 1, limit do
      hot_cursor = hot_cursor % hb_len + 1
      local entry  = hb[hot_cursor]
      local tb_row = storage.terminal_belts[entry.y]
      local tb     = tb_row and tb_row[entry.x]
      if not tb or not tb.entity.valid then
        to_cool[#to_cool + 1] = {x=entry.x, y=entry.y}
      elseif not do_overflow(tb) then
        to_cool[#to_cool + 1] = {x=entry.x, y=entry.y}
      end
    end
    storage.hot_cursor = hot_cursor

    -- Evict after the loop so swap-with-last doesn't corrupt our cursor mid-iteration
    for _, pos in ipairs(to_cool) do
      remove_from_hot(pos.x, pos.y)
    end
    -- Clamp hot_cursor in case evictions shrank the array
    if storage.hot_cursor > #hb then storage.hot_cursor = #hb end
  end

  -- Stage 2: rotating scan
  local list     = storage.terminal_belt_list
  local list_len = #list
  if list_len == 0 then return end
  local cursor = storage.scan_cursor
  for _ = 1, SCAN_SLICE do
    cursor = cursor % list_len + 1
    local entry = list[cursor]
    if not (storage.hot_belt_set[entry.y] and storage.hot_belt_set[entry.y][entry.x]) then
      local tb_row = storage.terminal_belts[entry.y]
      local tb     = tb_row and tb_row[entry.x]
      if tb and tb.entity.valid and is_belt_full(tb) then
        add_to_hot(entry.x, entry.y)
        do_overflow(tb)
      end
    end
  end
  storage.scan_cursor = cursor
end

-- ---------------------------------------------------------------------------
-- Terminal belt line detection
-- ---------------------------------------------------------------------------
---@class check_and_update_entity_param
---@field entity BeltLikeEntity
---@field entity_to_ignore? BeltLikeEntity

---Filter splitter terminal lines based on output priority.
---If a splitter has output priority set and the priority output has a valid
---target ahead, exclude unprioritised lines from being marked terminal.
---This prevents unprioritised outputs from overflowing when the priority
---output is still available.
---@param entity BeltLikeEntity
---@param base_lines integer[]
---@return integer[]
local function filter_splitter_priority_lines(entity, base_lines)
  local priority = entity.splitter_output_priority
  if not priority then return base_lines end

  -- Determine which lines are prioritized based on output direction
  -- Left output: lines 5,6  |  Right output: lines 7,8
  local priority_lines = (priority == "left") and {5, 6} or {7, 8}

  -- Check if the priority output has a valid target ahead
  local ahead = rotate_offset(0, -1, entity.direction)
  local priority_offset = (priority == "left") and -0.5 or 0.5
  local r = rotate_offset(priority_offset, 0, entity.direction)
  local tx, ty = entity.position.x + ahead.px + r.px, entity.position.y + ahead.py + r.py
  local target = find_belt_at(entity.surface, tx, ty, false)

  -- If priority output has a valid target (not a splitter), only mark priority lines as terminal
  if target and target.type ~= "splitter" then
    return priority_lines
  end

  -- If priority output is blocked/unavailable, mark all lines as terminal
  return base_lines
end

local function terminal_belt_lines(args)
  local entity           = args.entity
  local entity_to_ignore = args.entity_to_ignore
  local entity_type      = entity.type
  if entity == entity_to_ignore then return {} end

  if entity_type == "underground-belt" and entity.belt_to_ground_type == "input" then
    if has_real_underground_neighbours(entity) and entity.neighbours ~= entity_to_ignore then return {} end
    return {1, 2, 3, 4}
  end
  if entity_type == "linked-belt" and entity.linked_belt_type == "input" then
    if has_real_linked_neighbours(entity) and entity.linked_belt_neighbour ~= entity_to_ignore then return {} end
    return {1, 2}
  end

  local entity_direction = entity.direction
  local pos = entity.position
  local epx, epy = pos.x, pos.y

  -- to_check: list of {px, py, lines} — positions to look ahead from
  local to_check = {}
  if entity_type == "splitter" then
    local r = rotate_offset(-0.5, 0, entity_direction)
    to_check = {
      {px=epx+r.px, py=epy+r.py, lines={5,6}},
      {px=epx-r.px, py=epy-r.py, lines={7,8}},
    }
  elseif entity_type == "underground-belt" and entity.belt_to_ground_type == "input" then
    to_check = {{px=epx, py=epy, lines={3,4}}}
  else
    to_check = {{px=epx, py=epy, lines={1,2}}}
  end

  local result_lines = {}
  local function push(lines)
    for _, l in pairs(lines) do result_lines[#result_lines+1] = l end
  end

  for _, check in pairs(to_check) do
    -- one tile ahead in the entity's facing direction
    local ahead = rotate_offset(0, -1, entity_direction)
    local tx, ty = check.px + ahead.px, check.py + ahead.py
    local target = find_belt_at(entity.surface, tx, ty, false)

    if target ~= nil and target ~= entity_to_ignore then
      local td = target.direction
      if entity.prototype.belt_speed > target.prototype.belt_speed then
        push(check.lines)
      elseif math.abs(td - entity_direction) == 8 then
        -- target faces back at us
        push(check.lines)
      elseif ((target.type=="underground-belt" and target.belt_to_ground_type=="output")
           or (target.type=="linked-belt"      and target.linked_belt_type=="output"))
        and td == entity_direction then
        push(check.lines)
      elseif target.type == "splitter" and td ~= entity_direction then
        push(check.lines)
      elseif td ~= entity_direction then
        -- side-loading — might curve or might be a T-junction
        local turn = false
        if target.type == "transport-belt" then
          local belt_shape = target.belt_shape
          if belt_shape == "straight" then
            -- check if something feeds in from behind the target
            local belt_behind = false
            local r1 = rotate_offset(0,  1, td)
            local r2 = rotate_offset(0, -2, entity_direction)
            local checks = {
              {x=target.position.x+r1.px, y=target.position.y+r1.py, dir=td},
              {x=epx+r2.px,               y=epy+r2.py,               dir=(entity_direction+8)%16},
            }
            for _, bpos in pairs(checks) do
              local cand = find_belt_at(entity.surface, bpos.x, bpos.y, true)
              if cand and cand ~= entity_to_ignore then
                if not (
                  ((cand.type=="underground-belt" or (cand.type=="entity-ghost" and cand.ghost_type=="underground-belt")) and cand.belt_to_ground_type=="input") or
                  ((cand.type=="linked-belt"      or (cand.type=="entity-ghost" and cand.ghost_type=="linked-belt"))      and cand.linked_belt_type=="input")
                ) then
                  if cand.direction == bpos.dir then belt_behind = true end
                  break
                end
              end
              if belt_behind then break end
            end
            if belt_behind then
              -- clear stale curve cache
              if storage.curve_belts[target.position.y] then
                storage.curve_belts[target.position.y][target.position.x] = nil
                if next(storage.curve_belts[target.position.y]) == nil then
                  storage.curve_belts[target.position.y] = nil
                end
              end
            else
              turn = true
              if not storage.curve_belts[target.position.y] then storage.curve_belts[target.position.y] = {} end
              storage.curve_belts[target.position.y][target.position.x] =
                ((td - entity_direction + 16) % 16 == 4) and "right" or "left"
            end
          else
            -- belt_shape is "left" or "right" — definitively a curve
            turn = true
            if not storage.curve_belts[target.position.y] then storage.curve_belts[target.position.y] = {} end
            storage.curve_belts[target.position.y][target.position.x] = belt_shape
          end
        end
        if not turn then push(check.lines) end
      end
    else
      -- nothing ahead — definitely terminal
      push(check.lines)
    end
  end

  if entity_type == "splitter" and #result_lines > 0 then
    result_lines = filter_splitter_priority_lines(entity, result_lines)
  end
  return result_lines
end

-- ---------------------------------------------------------------------------
-- Registry update
-- ---------------------------------------------------------------------------
local function check_and_update_entity(args)
  local entity = args.entity
  if not entity then return end
  -- Space platforms don't support items on ground, so overflow is meaningless there
  if entity.surface.platform then return end
  local pos = entity.position
  local x, y = pos.x, pos.y
  local t = terminal_belt_lines(args)
  if #t > 0 then
    if not storage.terminal_belts[y] then storage.terminal_belts[y] = {} end
    local existing = storage.terminal_belts[y][x]
    if not existing then
      local list = storage.terminal_belt_list
      local idx  = #list + 1
      list[idx]  = {x=x, y=y}
      storage.terminal_belts[y][x] = {
        entity=entity, lines=t, indicator=create_indicator(entity), list_index=idx,
      }
    else
      existing.entity = entity
      existing.lines  = t
      if not existing.indicator then existing.indicator = create_indicator(entity) end
    end
  else
    cleartermbelt(x, y)
  end
end

local function check_and_update_posd(posd, surface, entity_to_ignore)
  local x, y      = posd.px, posd.py
  local candidates = surface.find_entities({{x-0.5,y-0.5},{x+0.5,y+0.5}})
  for _, candidate in pairs(candidates) do
    if candidate.valid
      and (candidate.type=="transport-belt" or candidate.type=="underground-belt"
           or candidate.type=="linked-belt"  or candidate.type=="splitter")
      and candidate.direction == posd.d
      and candidate ~= entity_to_ignore then
      check_and_update_entity{entity=candidate, entity_to_ignore=entity_to_ignore}
    end
  end
end

-- ---------------------------------------------------------------------------
-- Neighbourhoods (offsets are relative, rotation applied at runtime)
-- ---------------------------------------------------------------------------
---@class params_entity_removal
---@field entity BeltLikeEntity
---@field removal boolean

---@type { [string]: POSD[] }
local neighborhoods = {
  belt = {
    {px=0,py=0,d=N},
    {px=-1,py=0,d=E},{px=1,py=0,d=W},
    {px=0,py=1,d=N},
    {px=-1,py=-1,d=E},{px=1,py=-1,d=W},
    {px=0,py=-2,d=S},
  },
  input = {
    {px=0,py=0,d=N},
    {px=0,py=1,d=N},
  },
  output = {
    {px=0,py=0,d=N},
    {px=-1,py=-1,d=E},{px=1,py=-1,d=W},
    {px=0,py=-2,d=S},
  },
  splitter = {
    {px=0,py=0,d=N},
    {px=-0.5,py=1,d=N},{px=0.5,py=1,d=N},
    {px=-1.5,py=-1,d=E},{px=1.5,py=-1,d=W},
    {px=-0.5,py=-2,d=S},{px=0.5,py=-2,d=S},
  },
}

local function check_and_update_neighborhood(args)
  local entity  = args.entity
  local removal = args.removal
  local neighborhood
  if entity.type == "transport-belt" then
    neighborhood = neighborhoods.belt
  elseif entity.type == "underground-belt" then
    neighborhood = (entity.belt_to_ground_type == "input") and neighborhoods.input or neighborhoods.output
    if has_real_underground_neighbours(entity) then
      check_and_update_entity{entity=entity.neighbours, entity_to_ignore=removal and entity or nil}
    end
  elseif entity.type == "linked-belt" then
    neighborhood = (entity.linked_belt_type == "input") and neighborhoods.input or neighborhoods.output
    if has_real_linked_neighbours(entity) then
      check_and_update_entity{entity=entity.neighbours, entity_to_ignore=removal and entity or nil}
    end
  elseif entity.type == "splitter" then
    neighborhood = neighborhoods.splitter
  end
  local epos = entity.position
  for _, posd in pairs(neighborhood) do
    local rp = rotate_posd(posd, entity.direction)
    if not (removal and rp.px == 0 and rp.py == 0) then
      check_and_update_posd(
        {px=epos.x+rp.px, py=epos.y+rp.py, d=rp.d},
        entity.surface, removal and entity or nil
      )
    end
  end
  if removal then cleartermbelt(epos.x, epos.y) end
end

local function onModifyEntity(args)
  local entity = args.entity
  if entity.type=="transport-belt" or entity.type=="underground-belt"
    or entity.type=="linked-belt"  or entity.type=="splitter" then
    check_and_update_neighborhood(args)
  end
end

local function onPlaceEntity(event)
  onModifyEntity{entity=event.created_entity or event.entity, removal=false}
end
local function onRemoveEntity(event)
  onModifyEntity{entity=event.entity, removal=true}
end

-- ---------------------------------------------------------------------------
-- World scan
-- ---------------------------------------------------------------------------
local function find_all_entities(args)
  local entities = {}
  for _, surface in pairs(game.surfaces) do
    if not surface.platform then  -- skip space platforms
      for chunk in surface.get_chunks() do
        args.area = chunk.area
        for _, ent in pairs(surface.find_entities_filtered(args)) do
          entities[#entities+1] = ent
        end
      end
    end
  end
  return entities
end

local function refreshData()
  if storage.terminal_belts then
    for y, row in pairs(storage.terminal_belts) do
      for x, _ in pairs(row) do cleartermbelt(x, y) end
    end
  end
  for _, name in pairs({"belt-overflow-indicator","belt-overflow-indicator-wide","belt-overflow-indicator-tall"}) do
    for _, e in pairs(find_all_entities{name=name}) do e.destroy() end
  end
  storage.terminal_belts     = {}
  storage.terminal_belt_list = {}
  storage.hot_belts          = {}
  storage.hot_belt_set       = {}
  storage.scan_cursor        = 0
  storage.hot_cursor         = 0
  storage.curve_belts        = {}
  for _, btype in pairs({"transport-belt","underground-belt","linked-belt","splitter"}) do
    for _, e in pairs(find_all_entities{type=btype}) do
      check_and_update_entity{entity=e}
    end
  end
end

local function updateIndicators()
  if not storage.terminal_belts then return end
  local draw = settings.global['belt_overflow_draw_indicators'].value
  for _, row in pairs(storage.terminal_belts) do
    for _, belt in pairs(row) do
      if draw then
        if not belt.indicator or not belt.indicator.valid then belt.indicator = create_indicator(belt.entity) end
      else
        if belt.indicator and belt.indicator.valid then belt.indicator.destroy() end
        belt.indicator = nil
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Debug
-- ---------------------------------------------------------------------------
local function getDebugInfo()
  local list_len = storage.terminal_belt_list and #storage.terminal_belt_list or 0
  local hot_len  = storage.hot_belts          and #storage.hot_belts          or 0
  local inv_list, inv_hot = 0, 0
  if storage.terminal_belt_list then
    for _, e in pairs(storage.terminal_belt_list) do
      local tb = storage.terminal_belts[e.y] and storage.terminal_belts[e.y][e.x]
      if not tb or not tb.entity.valid then inv_list = inv_list + 1 end
    end
  end
  if storage.hot_belts then
    for _, e in pairs(storage.hot_belts) do
      local tb = storage.terminal_belts[e.y] and storage.terminal_belts[e.y][e.x]
      if not tb or not tb.entity.valid then inv_hot = inv_hot + 1 end
    end
  end
  return string.format(
    "BeltOverflow: terminal=%d (invalid=%d)  hot=%d (invalid=%d)  cursor=%d  slice=%d  hot_cap=%d",
    list_len, inv_list, hot_len, inv_hot,
    storage.scan_cursor or 0, SCAN_SLICE, HOT_CAP
  )
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function onInit()
  if storage.terminal_belts == nil then refreshData() end
end

local function onConfigurationChanged()
  refreshData(); updateIndicators()
end

local function onRuntimeModSettingChanged(args)
  if args.setting == "belt_overflow_poll_frequency" then
    SCAN_SLICE = settings.global['belt_overflow_poll_frequency'].value
  elseif args.setting == "belt_overflow_hot_cap" then
    HOT_CAP = settings.global['belt_overflow_hot_cap'].value
  elseif args.setting == "belt_overflow_draw_indicators" then
    updateIndicators()
  end
end

script.on_init(onInit)
script.on_configuration_changed(onConfigurationChanged)
script.on_event(defines.events.on_runtime_mod_setting_changed, onRuntimeModSettingChanged)

local belt_filter = {
  {filter="type", type="transport-belt"},
  {filter="type", type="underground-belt"},
  {filter="type", type="splitter"},
  {filter="type", type="linked-belt"},
}
script.on_event(defines.events.on_built_entity,          onPlaceEntity,  belt_filter)
script.on_event(defines.events.on_robot_built_entity,    onPlaceEntity,  belt_filter)
script.on_event(defines.events.on_player_rotated_entity, onPlaceEntity)
script.on_event(defines.events.on_pre_player_mined_item, onRemoveEntity, belt_filter)
script.on_event(defines.events.on_robot_pre_mined,       onRemoveEntity, belt_filter)
script.on_event(defines.events.on_entity_died,           onRemoveEntity, belt_filter)
script.on_event(defines.events.on_tick, onTick)

remote.add_interface("belt-overflow", {
  refreshData  = refreshData,
  getDebugInfo = getDebugInfo,
})
