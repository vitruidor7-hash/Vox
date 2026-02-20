--  - Space Explorer RPG — Planet & Cave Overhaul
--  - Larger, more detailed planets (procedural surface, stable visuals, no flicker)
--  - Interactables beyond resources (relics/data, crates, hazards)
--  - Caves with entrances, lighting, wall-embedded ore veins, and diggable terrain
--  - Expanded ore set (+4 new ores)
--
-- Controls:
--  Arrows: move
--  Z (A/btn4): interact / harvest / mine (hold in caves)
--  X (B/btn5): land/takeoff / back / exit cave
--  C (X/btn6): build base (planet)
--  V (Y/btn7): skills
--
-- Tip: On planets, look for cave entrances to mine ores. Food mostly comes from surface plants/crates.

----------------------------
-- Utilities
----------------------------
local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function lerp(a,b,t) return a+(b-a)*t end

-- LuaJIT/LÖVE2D compatibility
local bit = bit or require("bit")

local function dist(ax,ay,bx,by) local dx=ax-bx; local dy=ay-by; return math.sqrt(dx*dx+dy*dy) end

----------------------------
-- RNG + hash (deterministic)
----------------------------
local RNG = {}; RNG.__index=RNG
function RNG:new(seed) return setmetatable({seed=seed or 1}, self) end
function RNG:next() self.seed = (1103515245*self.seed + 12345) % 2147483648; return self.seed end
function RNG:randf() return self:next()/2147483648 end
function RNG:randi(a,b) return a + math.floor(self:randf()*((b-a)+1)) end

local function ihash(x,y,seed)
  -- integer-ish hash -> 0..1 (LuaJIT-compatible)
  local n = x*374761393 + y*668265263 + seed*1442695041
  n = bit.tobit(n)
  n = bit.tobit(bit.bxor(n, bit.rshift(n, 13)) * 1274126177)
  n = bit.bxor(n, bit.rshift(n, 16))
  n = n % 2147483647
  return n/2147483647
end

local function smoothstep(t) return t*t*(3-2*t) end

local function vnoise(x,y,seed)
  -- value noise with bilinear interpolation
  local x0 = math.floor(x); local y0 = math.floor(y)
  local x1 = x0+1; local y1 = y0+1
  local sx = smoothstep(x-x0)
  local sy = smoothstep(y-y0)
  local n00 = ihash(x0,y0,seed)
  local n10 = ihash(x1,y0,seed)
  local n01 = ihash(x0,y1,seed)
  local n11 = ihash(x1,y1,seed)
  local ix0 = n00 + (n10-n00)*sx
  local ix1 = n01 + (n11-n01)*sx
  return ix0 + (ix1-ix0)*sy
end

----------------------------
-- Constants
----------------------------
local W,H = 240,136
local WORLD = { w=2400, h=2400 }

local UI = {
  text=15, dim=12, faint=13,
  ink=0, panel=1, panel2=2, border=12,
  ok=11, warn=10, bad=8,
}

-- planet palettes also influence cave "rock" tint slightly
local PLANET_TYPES = {
  {name="Arid",     pal={bg=3,  mid=4,  hi=6,  deco=9},  food=0.75, caves=1.10},
  {name="Ice",      pal={bg=12, mid=13, hi=15, deco=6},  food=0.55, caves=1.00},
  {name="Jungle",   pal={bg=2,  mid=3,  hi=11, deco=5},  food=1.35, caves=0.95},
  {name="Volcanic", pal={bg=1,  mid=8,  hi=9,  deco=15}, food=0.45, caves=1.20},
  {name="Ocean",    pal={bg=4,  mid=12, hi=6,  deco=15}, food=1.10, caves=0.90},
}

-- Expanded ore set (6 total: original ore->IRON + original CRYSTAL +4 new)
local ORE_KEYS = {"iron","copper","silver","gold","titanium","crystal"}
local ORE = {
  iron     ={name="IRON",     col=9},
  copper   ={name="COPPER",   col=4},
  silver   ={name="SILVER",   col=12},
  gold     ={name="GOLD",     col=10},
  titanium ={name="TITANIUM", col=13},
  crystal  ={name="CRYSTAL",  col=15},
}

local RES = {
  food ={name="FOOD", col=11},
  data ={name="DATA", col=14},
}

local COST = {
  base={iron=10, crystal=5},
  up_engine={iron=10, copper=6, crystal=3},
  up_drill ={iron=12, titanium=4, crystal=6},
  up_cargo ={iron=16, silver=6, crystal=2},
  up_suit  ={iron=8,  gold=4, crystal=8},
  trade_data={data=2}, -- convert DATA to skill point
}

----------------------------
-- State
----------------------------
local G = {
  t=0,
  state="space", -- space|planet|cave|base|skills
  camx=0, camy=0,               -- space camera
  planet_camx=0, planet_camy=0, -- surface camera
  cave_camx=0, cave_camy=0,     -- cave camera
  active_planet=nil,
  active_cave=nil,
  surface_return=nil,
  toast={text="", t=0, dur=0},
  particles={},
  last_base=nil,
  fade=nil, -- transition overlay
  scan_t=0,
  scan_mode="",
  c_hold=0,
  c_hold_used=false,
}

local Player = {
  -- ship in space
  sx=WORLD.w/2, sy=WORLD.h/2,
  svx=0, svy=0,

  -- on-foot (planet OR cave)
  px=256, py=256,
  pvx=0, pvy=0,

  hunger=100,
  health=100,

  inv={iron=0,copper=0,silver=0,gold=0,titanium=0,crystal=0,food=3,data=0},

  level=1,
  xp=0,
  next_xp=30,
  sp=0,

  upgrades={engine=0, drill=0, cargo=0, suit=0},
  skills={mining=0, metabolism=0, piloting=0},
}

local CARGO_KEYS = {"iron","copper","silver","gold","titanium","crystal","food","data"}
local function inv_total()
  local s=0
  for i=1,#CARGO_KEYS do s=s + (Player.inv[CARGO_KEYS[i]] or 0) end
  return s
end
local function inv_max() return 30 + Player.upgrades.cargo*10 end
local function ship_speed() return 1.15 + Player.upgrades.engine*0.25 + Player.skills.piloting*0.15 end
local function walk_speed() return 1.0 + Player.skills.piloting*0.05 end
local function mining_power() return 1 + Player.upgrades.drill*1 + Player.skills.mining*0.5 end
local function hunger_rate()
  local r=0.016
  r = r * (1 - 0.12*Player.skills.metabolism)
  r = r * (1 - 0.07*Player.upgrades.suit)
  return clamp(r, 0.004, 0.03)
end

local function toast(s,frames)
  G.toast.text=s
  G.toast.t=frames or 150
  G.toast.dur=frames or 150
end

local function add_xp(n)
  Player.xp = Player.xp + n
  while Player.xp >= Player.next_xp do
    Player.xp = Player.xp - Player.next_xp
    Player.level = Player.level + 1
    Player.sp = Player.sp + 1
    Player.next_xp = math.floor(Player.next_xp*1.25 + 8)
    toast("LEVEL UP! +1 skill", 200)
  end
end

local function has_cost(cost)
  for k,v in pairs(cost) do
    if (Player.inv[k] or 0) < v then return false end
  end
  return true
end

local function pay_cost(cost)
  for k,v in pairs(cost) do
    Player.inv[k] = (Player.inv[k] or 0) - v
  end
end

----------------------------
-- Planets
----------------------------
local Planets={}

local function gen_planets(seed)
  local rng=RNG:new(seed)
  Planets={}
  local count=8
  local tries=0
  while #Planets<count and tries<8000 do
    tries=tries+1
    local x=rng:randi(150, WORLD.w-150)
    local y=rng:randi(150, WORLD.h-150)
    local r=rng:randi(18,38)
    local typ=rng:randi(1,#PLANET_TYPES)

    local ok=true
    for i=1,#Planets do
      if dist(x,y,Planets[i].x,Planets[i].y) < (r+Planets[i].r+125) then ok=false break end
    end
    if ok then
      local seed2=rng:next()
      Planets[#Planets+1]={
        id=#Planets+1,
        x=x,y=y,r=r, typ=typ,
        seed=seed2,
        discovered=false,
        name="P-"..string.format("%03d", rng:randi(1,999)),
        surface={w=1536,h=1536},
        nodes=nil,   -- surface interactables
        caves=nil,   -- cave entrances + persistent modifiers
        base=nil,
        landing=nil,
      }
    end
  end
end

-- Stable procedural surface tile color (no pre-gen tables needed)
local function surface_col(p, tx, ty)
  local pal=PLANET_TYPES[p.typ].pal
  local s=p.seed
  local n1 = vnoise(tx/16, ty/16, s)
  local n2 = vnoise(tx/42, ty/42, (s*7+13)%2147483647)
  local h = n1*0.75 + n2*0.25

  local c=pal.bg
  if h>0.52 then c=pal.mid end
  if h>0.70 then c=pal.hi end

  -- special features: dark rock / shallow water / dunes
  local f = vnoise(tx/9, ty/9, (s*19+101)%2147483647)
  if p.typ==5 and f>0.78 then c=12 end -- ocean: deep patches
  if p.typ==4 and f<0.28 then c=0 end  -- volcanic: basalt cracks
  if p.typ==1 and f>0.82 then c=4 end  -- arid: dunes

  return c
end

local function gen_planet_content(p)
  -- surface interactables + cave entrances
  local rng=RNG:new(p.seed)
  local t=PLANET_TYPES[p.typ]

  -- interactables
  local nodes={}
  -- food plants
  local food_count=math.floor(28*(0.85+rng:randf()*0.5)*t.food)
  for i=1,food_count do
    nodes[#nodes+1]={kind="food", x=rng:randi(20,p.surface.w-20), y=rng:randi(20,p.surface.h-20), hp=1, alive=true}
  end
  -- relics (data)
  local relic_count=rng:randi(6,10)
  for i=1,relic_count do
    nodes[#nodes+1]={kind="relic", x=rng:randi(40,p.surface.w-40), y=rng:randi(40,p.surface.h-40), alive=true}
  end
  -- crates (small guaranteed survival refills)
  local crate_count=rng:randi(4,7)
  for i=1,crate_count do
    nodes[#nodes+1]={kind="crate", x=rng:randi(30,p.surface.w-30), y=rng:randi(30,p.surface.h-30), alive=true}
  end
  -- hazards (vents / spores)
  local haz_count=rng:randi(5,9)
  for i=1,haz_count do
    nodes[#nodes+1]={kind="haz", x=rng:randi(30,p.surface.w-30), y=rng:randi(30,p.surface.h-30), alive=true}
  end
  -- scanner discovery flags
  for i=1,#nodes do nodes[i].seen=false end
  p.nodes=nodes

  -- caves
  local caves={}
  -- more entrances + guarantee one near landing zone (center) so players always find caves
  local cave_count=clamp(math.floor(4 + rng:randf()*4*t.caves), 4, 7)
  local cx=math.floor(p.surface.w/2)
  local cy=math.floor(p.surface.h/2)
  for i=1,cave_count do
    local ex,ey
    if i==1 then
      local ang=rng:randf()*6.283185
      local rad=90 + rng:randf()*160
      ex=clamp(cx + math.floor(math.cos(ang)*rad), 60, p.surface.w-60)
      ey=clamp(cy + math.floor(math.sin(ang)*rad), 60, p.surface.h-60)
    else
      -- Keep entrances spaced out so caves don't cluster.
      local tries = 0
      local ok = false
      local min_d2 = (110*110) -- tweak spacing here (in surface pixels)
      while tries < 40 and not ok do
        ex = rng:randi(60,p.surface.w-60)
        ey = rng:randi(60,p.surface.h-60)
        ok = true
        for j=1,#caves do
          local dx = ex - caves[j].ex
          local dy = ey - caves[j].ey
          if (dx*dx + dy*dy) < min_d2 then
            ok = false
            break
          end
        end
        tries = tries + 1
      end
    end
    caves[#caves+1]={
      id=i,
      ex=ex, ey=ey, -- entrance on surface
      seed=(p.seed*31 + i*997) % 2147483647,
      w=160, h=120, -- cells (8px): 1280x960 cave
      cells={},     -- sparse: key -> int (0 floor, 1 wall, -k ore wall)
      hp={},        -- key -> remaining hp while mining
      visited=false,
      spawn=nil,    -- computed on first entry: {x,y} in pixels
      exit=nil,     -- exit cell (same as spawn)
    }
  end
  -- caves are always visible on minimap
  for i=1,#caves do caves[i].seen=true end
  p.caves=caves
  -- minimap cache (built lazily)
  p.mm=nil
end

----------------------------
-- Skills (2D navigation) (unchanged)
----------------------------
local SkillTree={
  nodes={
    {id="min1", name="Mining I",     branch="mining",     x=40,y=28, req={},        desc="+0.5 mining power"},
    {id="min2", name="Mining II",    branch="mining",     x=24,y=52, req={"min1"}, desc="+0.5 mining power"},
    {id="min3", name="Mining III",   branch="mining",     x=56,y=52, req={"min1"}, desc="+0.5 mining power"},

    {id="met1", name="Metabolism I", branch="metabolism", x=120,y=28, req={},        desc="-12% hunger rate"},
    {id="met2", name="Metabolism II",branch="metabolism", x=104,y=52, req={"met1"}, desc="-12% hunger rate"},
    {id="met3", name="Meta III",     branch="metabolism", x=136,y=52, req={"met1"}, desc="-12% hunger rate"},

    {id="pil1", name="Piloting I",   branch="piloting",   x=200,y=28, req={},        desc="+0.15 ship speed"},
    {id="pil2", name="Piloting II",  branch="piloting",   x=184,y=52, req={"pil1"}, desc="+0.15 ship speed"},
    {id="pil3", name="Piloting III", branch="piloting",   x=216,y=52, req={"pil1"}, desc="+0.15 ship speed"},
  },
  owned={},
  cur=1,
}

local function has_skill(id) return SkillTree.owned[id]==true end
local function can_buy(node)
  if has_skill(node.id) then return false end
  if Player.sp<=0 then return false end
  for i=1,#node.req do if not has_skill(node.req[i]) then return false end end
  return true
end

local function apply_skill(node)
  if node.branch=="mining" then Player.skills.mining=Player.skills.mining+1 end
  if node.branch=="metabolism" then Player.skills.metabolism=Player.skills.metabolism+1 end
  if node.branch=="piloting" then Player.skills.piloting=Player.skills.piloting+1 end
end

local function skill_move(dirx,diry)
  local cur=SkillTree.nodes[SkillTree.cur]
  local best=nil
  local bestScore=1e9
  for i=1,#SkillTree.nodes do
    if i~=SkillTree.cur then
      local n=SkillTree.nodes[i]
      local dx=n.x-cur.x
      local dy=n.y-cur.y
      if (dirx~=0 and dx*dirx>0) or (diry~=0 and dy*diry>0) then
        local primary = (dirx~=0) and math.abs(dx) or math.abs(dy)
        local off = (dirx~=0) and math.abs(dy) or math.abs(dx)
        local score = primary + off*1.4
        if score<bestScore then bestScore=score; best=i end
      end
    end
  end
  if best then SkillTree.cur=best end
end

----------------------------
-- Base menu
----------------------------
local BaseMenu={
  idx=1,
  items={
    {id="rest", name="Rest", cost="1 FOOD", desc="Restore HP/Hunger.",
      can=function() return (Player.inv.food or 0)>=1 and (Player.health<100 or Player.hunger<100) end,
      do_it=function()
        Player.inv.food=Player.inv.food-1
        Player.health=clamp(Player.health+35,0,100)
        Player.hunger=clamp(Player.hunger+50,0,100)
        toast("Rested at base.",140)
      end
    },
    {id="trade", name="Trade DATA → Skill", cost="2 DATA", desc="+1 Skill Point.",
      can=function() return has_cost(COST.trade_data) end,
      do_it=function()
        pay_cost(COST.trade_data)
        Player.sp=Player.sp+1
        toast("Uploaded data. +1 skill",160)
      end
    },
    {id="engine", name="Upgrade Engine", cost="10 IRN + 6 CUP + 3 CRY", desc="Faster ship.",
      can=function() return has_cost(COST.up_engine) end,
      do_it=function()
        pay_cost(COST.up_engine)
        Player.upgrades.engine=Player.upgrades.engine+1
        toast("Engine upgraded!",160)
      end
    },
    {id="drill", name="Upgrade Drill", cost="12 IRN + 4 TIT + 6 CRY", desc="Mine faster.",
      can=function() return has_cost(COST.up_drill) end,
      do_it=function()
        pay_cost(COST.up_drill)
        Player.upgrades.drill=Player.upgrades.drill+1
        toast("Drill upgraded!",160)
      end
    },
    {id="cargo", name="Upgrade Cargo", cost="16 IRN + 6 SLV + 2 CRY", desc="Carry more.",
      can=function() return has_cost(COST.up_cargo) end,
      do_it=function()
        pay_cost(COST.up_cargo)
        Player.upgrades.cargo=Player.upgrades.cargo+1
        toast("Cargo expanded!",160)
      end
    },
    {id="suit", name="Upgrade Suit", cost="8 IRN + 4 GLD + 8 CRY", desc="Less hunger drain.",
      can=function() return has_cost(COST.up_suit) end,
      do_it=function()
        pay_cost(COST.up_suit)
        Player.upgrades.suit=Player.upgrades.suit+1
        toast("Suit upgraded!",160)
      end
    },
  }
}

----------------------------
-- Input helpers
----------------------------
local BtnPrev={false,false,false,false,false,false,false,false}
local function btnp(i)
  local now=btn(i)
  local prev=BtnPrev[i+1]
  BtnPrev[i+1]=now
  return now and not prev
end

----------------------------
-- Particles
----------------------------
local function add_particle(x,y,vx,vy,life,col)
  G.particles[#G.particles+1]={x=x,y=y,vx=vx,vy=vy,life=life,col=col}
end

local function update_particles()
  for i=#G.particles,1,-1 do
    local p=G.particles[i]
    p.life=p.life-1
    p.x=p.x+p.vx
    p.y=p.y+p.vy
    p.vx=p.vx*0.96
    p.vy=p.vy*0.96
    if p.life<=0 then table.remove(G.particles,i) end
  end
end

local function draw_particles(camx,camy)
  for i=1,#G.particles do
    local p=G.particles[i]
    local x=p.x-camx
    local y=p.y-camy
    if x>-2 and x<W+2 and y>-2 and y<H+2 then
      pix(x,y,p.col)
      if (p.life%3)==0 then pix(x+1,y,p.col) end
    end
  end
end

----------------------------
-- UI primitives
----------------------------
local function panel(x,y,w,h)
  rect(x+1,y+1,w,h,UI.ink)
  rect(x,y,w,h,UI.panel)
  rectb(x,y,w,h,UI.border)
end

local function bar(x,y,w,h,val,maxv,col)
  rect(x,y,w,h,UI.ink)
  local pw=math.floor((w-2)*clamp(val/maxv,0,1))
  rect(x+1,y+1,pw,h-2,col)
end

-- icons
local function icon_ore(x,y,c) circ(x,y,3,c or 9); circ(x-1,y-1,1,15) end
local function icon_crystal(x,y,c)
  tri(x,y-3, x-3,y, x,y+3, c or 15)
  tri(x,y-3, x+3,y, x,y+3, c or 15)
  pix(x,y,15)
end
local function icon_food(x,y) circ(x,y,2,11); line(x,y-3,x+2,y-5,5) end
local function icon_data(x,y) rect(x-2,y-2,4,4,14); rect(x-1,y-1,2,2,15) end

local function draw_toast()
  if G.toast.t<=0 then return end
  local t=G.toast.t
  local dur=G.toast.dur
  local w=math.min(220, #G.toast.text*6+14)
  local x=math.floor((W-w)/2)
  local y=10
  rect(x+1,y+1,w,12,UI.ink)
  rect(x,y,w,12,UI.panel2)
  rectb(x,y,w,12,UI.border)
  print(G.toast.text, x+7, y+3, UI.text)
end

local function draw_hud(compact)
  local x0=4
  local y0=4
  local bw=52
  bar(x0,y0,bw,6,Player.health,100,8)
  bar(x0,y0+8,bw,6,Player.hunger,100,11)
  print("HP", x0+bw+4, y0-1, UI.dim)
  print("HU", x0+bw+4, y0+7, UI.dim)

  -- top right: 4 quick items
  local rx=140
  local ry=4
  icon_ore(rx,ry+3,ORE.iron.col);     print(Player.inv.iron, rx+7, ry+1, UI.text)
  icon_crystal(rx+40,ry+3,ORE.crystal.col); print(Player.inv.crystal, rx+47, ry+1, UI.text)
  icon_food(rx+86,ry+3);             print(Player.inv.food, rx+93, ry+1, UI.text)
  icon_data(rx+112,ry+3);            print(Player.inv.data, rx+118, ry+1, UI.text)

  if not compact then
    print("CARGO "..inv_total().."/"..inv_max(), 150, 14, UI.dim)
    print("LV "..Player.level.."  XP "..Player.xp.."/"..Player.next_xp.."  SP:"..Player.sp, 4, 120, UI.dim)
  else
    print("LV"..Player.level.." SP"..Player.sp, 4, H-10, UI.dim)
  end

  draw_toast()
end

local function hint(text)
  local w=math.min(232, #text*6+10)
  local x=math.floor((W-w)/2)
  local y=H-16
  rect(x+1,y+1,w,12,UI.ink)
  rect(x,y,w,12,UI.panel2)
  rectb(x,y,w,12,UI.border)
  print(text, x+5, y+3, UI.text)
end

----------------------------
-- Procedural sprites
----------------------------
local function draw_ship(x,y,thrust)
  circ(x, y+7, 5, 0)
  tri(x, y-8, x-7, y+6, x+7, y+6, 15)
  tri(x, y-6, x-5, y+5, x+5, y+5, 12)
  circ(x, y-1, 3, 13)
  circ(x-1, y-2, 1, 15)
  tri(x-7,y+3, x-12,y+7, x-5,y+7, 12)
  tri(x+7,y+3, x+12,y+7, x+5,y+7, 12)
  if thrust then
    local f=(G.t%6)
    circ(x, y+7, 2+(math.floor(f/3)), 10)
    circ(x, y+8, 1, 9)
  end
end

local function draw_astronaut(x,y)
  local bob = math.sin(G.t/6)*0.5
  circ(x, y+7, 3, 0)
  rect(x-3, y+1+bob, 6, 7, 15)
  circ(x, y-2+bob, 4, 15)
  circ(x+1, y-2+bob, 2, 12)
  pix(x+1, y-3+bob, 15)
  rect(x-5, y+2+bob, 2, 6, 13)
  rect(x-3, y+8+bob, 2, 2, 15)
  rect(x+1, y+8+bob, 2, 2, 15)
end

local function draw_base(bx,by,pal)
  rect(bx-10,by+8,20,4,0)
  rect(bx-10,by-8,20,16,15)
  rect(bx-9,by-7,18,14,UI.panel2)
  rect(bx-2,by+2,4,6,pal.mid)
  rect(bx-1,by+3,2,4,pal.hi)
  rect(bx-7,by-4,4,3,pal.hi)
  rect(bx+3,by-4,4,3,pal.hi)
  line(bx+8,by-8,bx+8,by-16,12)
  circ(bx+8,by-16,2,11)
end

local function draw_entrance(x,y,pal)
  -- cave mouth (high contrast + beacon pulse so it's easy to spot)
  local blink = ((math.floor(G.t/10))%2)==0
  circ(x,y,10, blink and pal.hi or pal.mid)
  circ(x,y,9,0)
  circ(x,y,7,0)
  circ(x,y,6,pal.mid)
  circ(x,y,5,0)
  -- ladder lines
  line(x-2,y-2,x-2,y+5,15)
  line(x+2,y-2,x+2,y+5,15)
  line(x-2,y,x+2,y,15)
  line(x-2,y+3,x+2,y+3,15)
  -- tiny label when close enough
  if dist(Player.px-G.planet_camx, Player.py-G.planet_camy, x, y) < 44 then
    print("CAVE", x-10, y-18, 15)
  end
end

local function draw_relic(x,y)
  rect(x-3,y-8,6,10,14)
  rect(x-2,y-7,4,8,15)
  circ(x,y-10,3,14)
  pix(x-1,y-11,15)
end

local function draw_crate(x,y)
  rect(x-5,y-4,10,8,4)
  rectb(x-5,y-4,10,8,12)
  line(x-5,y,x+4,y,12)
  line(x,y-4,x,y+3,12)
end

local function draw_plant(x,y,pal)
  local sway=math.sin((G.t/30)+(x*0.03))*1
  line(x,y,x+sway,y-6,pal.deco)
  line(x+1,y,x+1+sway,y-5,pal.deco)
  circ(x+sway,y-6,1,pal.hi)
  pix(x+sway,y-5,pal.hi)
end

local function draw_vent(x,y)
  circ(x,y,4,0)
  circ(x,y,3,8)
  if (G.t%40)<20 then
    line(x,y-6,x,y-12,12)
    circ(x,y-12,2,12)
  end
end

----------------------------
-- Backgrounds
----------------------------
local function draw_space_bg(camx,camy)
  cls(0)
  local layers={
    {cell=34, dens=0.10, col=12, par=0.35},
    {cell=22, dens=0.08, col=13, par=0.55},
    {cell=14, dens=0.06, col=15, par=0.75},
  }

  for li=1,#layers do
    local L=layers[li]
    local cx0=math.floor((camx*L.par)/L.cell)-1
    local cy0=math.floor((camy*L.par)/L.cell)-1
    local cx1=cx0+math.ceil(W/L.cell)+3
    local cy1=cy0+math.ceil(H/L.cell)+3
    local offx = (camx*L.par)%L.cell
    local offy = (camy*L.par)%L.cell

    for cy=cy0,cy1 do
      for cx=cx0,cx1 do
        local r=ihash(cx,cy,1337+li*99)
        if r<L.dens then
          local ox=ihash(cx,cy,777+li*17)
          local oy=ihash(cx,cy,999+li*31)
          local x = cx*L.cell + ox*(L.cell-1) - offx
          local y = cy*L.cell + oy*(L.cell-1) - offy
          local tw = 0.6 + 0.4*math.sin((G.t/40)+(cx*0.7+cy*0.3+li))
          local col = (tw>0.78) and 15 or L.col
          pix(x,y,col)
          if li==3 and tw>0.86 then pix(x+1,y,col) end
        end
      end
    end
  end

  -- soft nebula blobs
  local nseed=4242
  for i=1,3 do
    local bx = ihash(i,0,nseed)*WORLD.w
    local by = ihash(0,i,nseed)*WORLD.h
    local x = (bx - camx*0.35) % (W+120) - 60
    local y = (by - camy*0.35) % (H+120) - 60
    circ(x,y,34,1)
    circ(x+10,y-8,22,2)
    circ(x-8,y+6,18,3)
  end
end

local function draw_planet_in_space(p,camx,camy)
  local t=PLANET_TYPES[p.typ]
  local pal=t.pal
  local x=p.x-camx
  local y=p.y-camy
  local r=p.r

  circ(x,y,r+3,pal.mid)
  circ(x,y,r+2,pal.bg)

  circ(x,y,r,pal.bg)
  circ(x-2,y-2,math.max(2,math.floor(r*0.75)),pal.mid)
  circ(x-4,y-4,math.max(2,math.floor(r*0.50)),pal.hi)

  circ(x+3,y+2,math.max(2,math.floor(r*0.78)),0)
  circ(x+1,y+1,math.max(2,math.floor(r*0.82)),pal.bg)

  if (p.id%2)==0 then
    local a=G.t/90
    local rx = x + math.cos(a)*r*0.35
    local ry = y + math.sin(a)*r*0.2
    circ(rx,ry,2,pal.hi)
  else
    for i=-r, r, 3 do
      local yy = y + (i*0.18)
      local ww = math.floor(math.sqrt(r*r - i*i))
      if ww>0 then line(x-ww,yy,x+ww,yy,pal.mid) end
    end
  end

  if p.discovered then
    print(p.name, x-12, y-r-12, UI.text)
  end
end

----------------------------
-- Transitions (simple wipe)
----------------------------
local function start_fade(apply_fn)
  G.fade={t=0,dur=14,phase="out",apply=apply_fn}
end

local function update_fade()
  if not G.fade then return end
  local f=G.fade
  f.t=f.t+1
  if f.phase=="out" and f.t>=f.dur then
    if f.apply then f.apply() end
    f.phase="in"; f.t=0
  elseif f.phase=="in" and f.t>=f.dur then
    G.fade=nil
  end
end

local function draw_fade()
  if not G.fade then return end
  local f=G.fade
  local a = f.t / f.dur
  if f.phase=="in" then a = 1 - a end
  local h = math.floor(H * a)
  rect(0,0,W,h,0)
end

----------------------------
-- Survival tick
----------------------------
local function survival_tick()
  local hr=hunger_rate()
  Player.hunger=clamp(Player.hunger-hr,0,100)
  if Player.hunger<=0 then
    Player.health=clamp(Player.health-0.06,0,100)
  else
    Player.health=clamp(Player.health+0.01,0,100)
  end

  if Player.health<=0 then
    Player.health=100
    Player.hunger=70
    Player.svx,Player.svy=0,0
    Player.pvx,Player.pvy=0,0

    if G.last_base and G.last_base.planet then
      local bp=G.last_base.planet
      G.active_planet=bp
      G.state="planet"
      Player.px=G.last_base.x
      Player.py=G.last_base.y
      toast("You passed out... returned to base.",220)
    else
      G.state="space"
      Player.sx=WORLD.w/2; Player.sy=WORLD.h/2
      toast("You passed out... drifting in space.",220)
    end
  end
end

----------------------------
-- Space state
----------------------------
local function update_space()
  local acc=0.08
  if btn(2) then Player.svx=Player.svx-acc end
  if btn(3) then Player.svx=Player.svx+acc end
  if btn(0) then Player.svy=Player.svy-acc end
  if btn(1) then Player.svy=Player.svy+acc end

  local spd=ship_speed()
  Player.svx=clamp(Player.svx,-spd,spd)
  Player.svy=clamp(Player.svy,-spd,spd)
  Player.svx=Player.svx*0.985
  Player.svy=Player.svy*0.985

  Player.sx=clamp(Player.sx+Player.svx,0,WORLD.w)
  Player.sy=clamp(Player.sy+Player.svy,0,WORLD.h)

  G.camx=clamp(Player.sx-W/2,0,WORLD.w-W)
  G.camy=clamp(Player.sy-H/2,0,WORLD.h-H)

  local nearest=nil
  local nd=1e9
  for i=1,#Planets do
    local p=Planets[i]
    local d=dist(Player.sx,Player.sy,p.x,p.y)
    if d<nd then nd=d; nearest=p end
    if d<140 then p.discovered=true end
  end

  if btnp(7) then G.state="skills" end

  -- land
  if nearest and nd < (nearest.r + 14) and btnp(5) then
    G.active_planet=nearest
    if not nearest.nodes then gen_planet_content(nearest) end
    nearest.landing={x=Player.sx,y=Player.sy}
    Player.px=math.floor(nearest.surface.w/2); Player.py=math.floor(nearest.surface.h/2)
    Player.pvx=0; Player.pvy=0
    G.planet_camx=0; G.planet_camy=0
    G.state="planet"
    toast("Landed on "..nearest.name.." ("..PLANET_TYPES[nearest.typ].name..")",220)
  end
end

local function draw_space()
  draw_space_bg(G.camx,G.camy)

  for i=1,#Planets do
    local p=Planets[i]
    local x=p.x-G.camx
    local y=p.y-G.camy
    if x>-80 and x<W+80 and y>-80 and y<H+80 then
      draw_planet_in_space(p,G.camx,G.camy)
    end
  end

  local thrust = (btn(0) or btn(1) or btn(2) or btn(3))
  draw_ship(Player.sx-G.camx, Player.sy-G.camy, thrust)

  draw_hud(true)

  for i=1,#Planets do
    local p=Planets[i]
    if dist(Player.sx,Player.sy,p.x,p.y) < (p.r+14) then
      hint("X: Land on "..p.name.."   V: Skills")
      break
    end
  end
end

----------------------------
-- Planet helpers
----------------------------
local function node_near(p,x,y,r)
  local best=nil; local bd=1e9
  for i=1,#p.nodes do
    local n=p.nodes[i]
    if n.alive then
      local d=dist(x,y,n.x,n.y)
      if d<r and d<bd then bd=d; best=n end
    end
  end
  return best
end

local function cave_entrance_near(p,x,y,r)
  if not p.caves then return nil end
  local best=nil; local bd=1e9
  for i=1,#p.caves do
    local e=p.caves[i]
    local d=dist(x,y,e.ex,e.ey)
    if d<r and d<bd then bd=d; best=e end
  end
  return best
end


----------------------------
-- Scanner + minimap
----------------------------
local MMW,MMH = 70,48
local MMX,MMY = W-MMW-4, 22

local function scan_range_surface()
  return 520 + Player.upgrades.suit*40 + Player.skills.piloting*12
end

local function scan_range_cave()
  -- in cells (tiles)
  return 11 + Player.upgrades.suit*2 + Player.skills.mining
end

local function scan_pulse(mode)
  G.scan_mode=mode
  G.scan_t=260
  if mode=="planet" then
    local p=G.active_planet
    if p then
      local r=scan_range_surface()
      for i=1,#p.nodes do
        local n=p.nodes[i]
        if n.alive and not n.seen then
          if dist(Player.px,Player.py,n.x,n.y) < r then n.seen=true end
        end
      end
    end
  end
  toast("Scanner ping!",45)
end

local function mm_build_planet(p)
  if p.mm then return end
  local iw = MMW-4
  local ih = MMH-4
  local mm = {w=iw, h=ih, pix={}}
  for y=0,ih-1 do
    local wy = math.floor(y * p.surface.h / ih)
    local ty = math.floor(wy/8)
    for x=0,iw-1 do
      local wx = math.floor(x * p.surface.w / iw)
      local tx = math.floor(wx/8)
      mm.pix[y*iw + x + 1] = surface_col(p,tx,ty)
    end
  end
  p.mm=mm
end

local function mm_map(p,wx,wy)
  local mm=p.mm
  local x = MMX+2 + math.floor(wx * mm.w / p.surface.w)
  local y = MMY+2 + math.floor(wy * mm.h / p.surface.h)
  return x,y
end

local function draw_arrow(x,y,dx,dy,col)
  -- small triangle arrow, points along dx/dy
  local ang = math.atan(dy,dx)
  local ux,uy = math.cos(ang), math.sin(ang)
  local px = x + ux*5
  local py = y + uy*5
  local lx = x + (-uy)*3
  local ly = y + (ux)*3
  local rx = x + (uy)*3
  local ry = y + (-ux)*3
  tri(px,py,lx,ly,rx,ry,col)
end

local function draw_edge_arrow_to(wx,wy,camx,camy,col)
  -- arrow on screen edge pointing towards world point
  local sx = wx - camx
  local sy = wy - camy
  if sx>8 and sx<W-8 and sy>16 and sy<H-10 then return end
  local dx = wx - Player.px
  local dy = wy - Player.py
  local cx,cy = W/2, H/2
  local ang = math.atan(dy,dx)
  local ux,uy = math.cos(ang), math.sin(ang)
  local r = math.min(W/2-10, H/2-18)
  local ax = cx + ux*r
  local ay = cy + uy*r
  draw_arrow(ax,ay,dx,dy,col)
end

local function draw_planet_minimap(p)
  mm_build_planet(p)
  panel(MMX,MMY,MMW,MMH)
  local mm=p.mm

  -- background pixels
  for y=0,mm.h-1 do
    local py = MMY+2 + y
    local row = y*mm.w
    for x=0,mm.w-1 do
      pix(MMX+2 + x, py, mm.pix[row+x+1])
    end
  end

  -- scanner range ring (if active)
  if G.scan_t and G.scan_t>0 and G.scan_mode=="planet" then
    local px,py = mm_map(p,Player.px,Player.py)
    local rr = scan_range_surface() * mm.w / p.surface.w
    circ(px,py,math.floor(rr), UI.dim)
  end

  -- caves
  if p.caves then
    for i=1,#p.caves do
      local e=p.caves[i]
      local x,y = mm_map(p,e.ex,e.ey)
      pix(x,y,UI.ok); pix(x+1,y,0)
    end
  end

  -- base
  if p.base then
    local x,y = mm_map(p,p.base.x,p.base.y)
    rect(x-1,y-1,3,3,12)
    rectb(x-1,y-1,3,3,15)
  end

  -- discovered interactables
  for i=1,#p.nodes do
    local n=p.nodes[i]
    if n.alive and n.seen then
      local x,y = mm_map(p,n.x,n.y)
      local col=UI.text
      if n.kind=="relic" then col=14
      elseif n.kind=="crate" then col=4
      elseif n.kind=="haz" then col=8
      elseif n.kind=="food" then col=11 end
      pix(x,y,col)
    end
  end

  -- player
  local px,py = mm_map(p,Player.px,Player.py)
  rect(px-1,py-1,3,3,15)
end

local function draw_cave_minimap(p,c)
  panel(MMX,MMY,MMW,MMH)
  local iw,ih = MMW-4, MMH-4
  local x0,y0 = MMX+2, MMY+2

  for y=0,ih-1 do
    local cy = math.floor(y * c.h / ih)
    local py = y0 + y
    for x=0,iw-1 do
      local cx = math.floor(x * c.w / iw)
      local v = cave_get_cell(p,c,cx,cy)
      local col
      if v==0 then col=0
      elseif v>0 then col=1
      else
        local ok=ORE_KEYS[-v]
        col = ORE[ok].col
      end
      pix(x0+x,py,col)
    end
  end

  -- exit marker
  local ex = (c.exit and c.exit.x*8+4) or c.spawn.x
  local ey = (c.exit and c.exit.y*8+4) or c.spawn.y
  local mx = x0 + math.floor((ex/8) * iw / c.w)
  local my = y0 + math.floor((ey/8) * ih / c.h)
  pix(mx,my,12)

  -- player
  local px = x0 + math.floor((Player.px/8) * iw / c.w)
  local py = y0 + math.floor((Player.py/8) * ih / c.h)
  rect(px-1,py-1,3,3,15)

  -- scanner ring
  if G.scan_t and G.scan_t>0 and G.scan_mode=="cave" then
    local rr = scan_range_cave() * iw / c.w
    circ(px,py,math.floor(rr), UI.dim)
  end
end

----------------------------
-- Planet state (surface)
----------------------------
local function update_planet()
  local p=G.active_planet
  if not p then G.state="space" return end

  local spd=walk_speed()
  local ax,ay=0,0
  if btn(2) then ax=ax-1 end
  if btn(3) then ax=ax+1 end
  if btn(0) then ay=ay-1 end
  if btn(1) then ay=ay+1 end
  if ax~=0 and ay~=0 then ax=ax*0.7; ay=ay*0.7 end

  Player.pvx=lerp(Player.pvx, ax*spd, 0.35)
  Player.pvy=lerp(Player.pvy, ay*spd, 0.35)
  Player.px=clamp(Player.px+Player.pvx, 8, p.surface.w-8)
  Player.py=clamp(Player.py+Player.pvy, 8, p.surface.h-8)

  G.planet_camx=clamp(Player.px-W/2,0,p.surface.w-W)
  G.planet_camy=clamp(Player.py-H/2,0,p.surface.h-H)

  if btnp(7) then G.state="skills" end

  -- hazards tick (proximity damage)
  local nearHaz=nil
  for i=1,#p.nodes do
    local n=p.nodes[i]
    if n.alive and n.kind=="haz" then
      local d=dist(Player.px,Player.py,n.x,n.y)
      if d<14 then nearHaz=n break end
    end
  end
  if nearHaz and (G.t%15)==0 then
    Player.health=clamp(Player.health-1.2,0,100)
    toast("Hazard! Keep distance.",60)
  end

  -- auto-discover nearby interactables for minimap
  for i=1,#p.nodes do
    local n=p.nodes[i]
    if n.alive and not n.seen then
      if dist(Player.px,Player.py,n.x,n.y) < 60 then n.seen=true end
    end
  end

  -- interact (tap Z)
  if btnp(4) then
    local near=node_near(p,Player.px,Player.py,14)
    local ent=cave_entrance_near(p,Player.px,Player.py,16)

    if ent then
      -- enter cave
      G.surface_return={x=Player.px,y=Player.py}
      G.active_cave=ent
      start_fade(function()
        G.state="cave"
        -- compute spawn (force-carved entry pocket) on first entry
        if not ent.spawn then
          local cx = math.floor(ent.w/2)
          local cy = 6
          ent.spawn={x=cx*8+4,y=cy*8+4}
          ent.exit={x=cx,y=cy}
          for oy=-2,2 do for ox=-2,2 do
            ent.cells[(cy+oy)*ent.w + (cx+ox)] = 0
          end end
        end
        Player.px=ent.spawn.x; Player.py=ent.spawn.y
        Player.pvx=0; Player.pvy=0
        G.cave_camx=clamp(Player.px-W/2,0,ent.w*8-W)
        G.cave_camy=clamp(Player.py-H/2,0,ent.h*8-H)
        toast("Entered cave.",120)
      end)
      return
    end

    if near then
      if near.kind=="food" then
        if inv_total()>=inv_max() then
          toast("Cargo full.",70)
        else
          near.alive=false
          Player.inv.food=Player.inv.food+1
          add_xp(3)
          toast("+1 FOOD",90)
        end
      elseif near.kind=="relic" then
        near.alive=false
        local gain = 1 + math.floor(ihash(G.t, near.x, p.seed)*2)
        Player.inv.data = Player.inv.data + gain
        add_xp(10 + gain*2)
        toast("Found relic +"..gain.." DATA",140)
      elseif near.kind=="crate" then
        near.alive=false
        local f = 1 + math.floor(ihash(near.y, G.t, p.seed)*2)
        Player.inv.food = Player.inv.food + f
        -- tiny bonus: a little iron so you can get started even with shallow caves
        local ir = 1 + math.floor(ihash(near.x, near.y, p.seed)*1)
        Player.inv.iron = Player.inv.iron + ir
        add_xp(6)
        toast("Crate +"..f.." FOOD +"..ir.." IRON",160)
      end
    end
  end

  -- scanner + base (C): tap = scanner ping, hold = build base
  if btn(6) then
    if G.c_hold==0 then
      G.c_hold=1; G.c_hold_used=false
    else
      G.c_hold=G.c_hold+1
    end

    if G.c_hold==22 and not G.c_hold_used then
      G.c_hold_used=true
      if p.base then
        toast("Base already built here.",120)
      else
        if has_cost(COST.base) then
          pay_cost(COST.base)
          p.base={x=Player.px,y=Player.py}
          G.last_base={planet=p,x=Player.px,y=Player.py}
          toast("Base built! (X to open)",180)
        else
          toast("Need "..COST.base.iron.." IRON + "..COST.base.crystal.." CRYSTAL",190)
        end
      end
    end
  elseif G.c_hold>0 then
    if (not G.c_hold_used) and G.c_hold<22 then
      scan_pulse("planet")
    end
    G.c_hold=0; G.c_hold_used=false
  end

  -- open base or takeoff
  local atBase = p.base and dist(Player.px,Player.py,p.base.x,p.base.y) < 14
  if btnp(5) then
    if atBase then
      BaseMenu.idx=1
      G.state="base"
    else
      -- takeoff
      if p.landing then
        Player.sx=p.landing.x; Player.sy=p.landing.y
      end
      Player.svx,Player.svy=0,0
      G.state="space"
      toast("Takeoff.",120)
    end
  end
end

local function draw_planet()
  local p=G.active_planet
  local t=PLANET_TYPES[p.typ]
  local pal=t.pal

  cls(pal.bg)

  -- tile draw (procedural)
  local tx0=math.floor(G.planet_camx/8)
  local ty0=math.floor(G.planet_camy/8)
  local tx1=tx0+math.ceil(W/8)+1
  local ty1=ty0+math.ceil(H/8)+1

  for ty=ty0,ty1 do
    for tx=tx0,tx1 do
      local c=surface_col(p,tx,ty)
      rect(tx*8-G.planet_camx, ty*8-G.planet_camy, 8, 8, c)

      -- procedural micro-decor (stable)
      local r = ihash(tx,ty,p.seed)
      if r>0.993 then
        local x = tx*8 - G.planet_camx + math.floor(ihash(tx,ty,p.seed*7+13)*6)+1
        local y = ty*8 - G.planet_camy + math.floor(ihash(tx,ty,p.seed*19+101)*6)+1
        circ(x,y,2,pal.deco)
        pix(x-1,y-1,pal.hi)
      elseif r<0.008 and p.typ==3 then
        -- jungle vines
        local x = tx*8 - G.planet_camx + 4
        local y = ty*8 - G.planet_camy + 4
        line(x,y,x,y-5,pal.deco)
      end
    end
  end

  -- cave entrances
  if p.caves then
    for i=1,#p.caves do
      local e=p.caves[i]
      local x=e.ex-G.planet_camx
      local y=e.ey-G.planet_camy
      if x>-20 and x<W+20 and y>-20 and y<H+20 then
        draw_entrance(x,y,pal)
      end
    end
  end

  -- interactables
  for i=1,#p.nodes do
    local n=p.nodes[i]
    if n.alive then
      local x=n.x-G.planet_camx
      local y=n.y-G.planet_camy
      if x>-24 and x<W+24 and y>-24 and y<H+24 then
        if n.kind=="food" then
          draw_plant(x,y,pal)
        elseif n.kind=="relic" then
          draw_relic(x,y)
        elseif n.kind=="crate" then
          draw_crate(x,y)
        elseif n.kind=="haz" then
          draw_vent(x,y)
        end
      end
    end
  end

  -- base
  if p.base then
    local bx=p.base.x-G.planet_camx
    local by=p.base.y-G.planet_camy
    draw_base(bx,by,pal)
    print("BASE", bx-10, by-20, UI.text)
  end

  draw_particles(G.planet_camx,G.planet_camy)
  draw_astronaut(Player.px-G.planet_camx, Player.py-G.planet_camy)
  draw_hud(true)
  draw_planet_minimap(p)

  -- always guide the player to the nearest cave entrance (big planets need navigation)
  if p.caves then
    local best=nil; local bd=1e9
    for i=1,#p.caves do
      local e=p.caves[i]
      local d=dist(Player.px,Player.py,e.ex,e.ey)
      if d<bd then bd=d; best=e end
    end
    if best then
      draw_edge_arrow_to(best.ex,best.ey,G.planet_camx,G.planet_camy, UI.ok)
      if (G.scan_t and G.scan_t>0 and G.scan_mode=="planet") and bd < scan_range_surface() then
        local sx=best.ex-G.planet_camx
        local sy=best.ey-G.planet_camy
        if sx>-24 and sx<W+24 and sy>-24 and sy<H+24 then
          circ(sx,sy, 12 + (G.t%8), UI.ok)
        end
      end
    end
  end

  -- scanner overlay: highlight discovered POIs in range
  if (G.scan_t and G.scan_t>0 and G.scan_mode=="planet") then
    local r=scan_range_surface()
    for i=1,#p.nodes do
      local n=p.nodes[i]
      if n.alive and n.seen and dist(Player.px,Player.py,n.x,n.y) < r then
        local sx=n.x-G.planet_camx
        local sy=n.y-G.planet_camy
        if sx>-28 and sx<W+28 and sy>-28 and sy<H+28 then
          local col=15
          if n.kind=="relic" then col=14
          elseif n.kind=="crate" then col=4
          elseif n.kind=="haz" then col=8
          elseif n.kind=="food" then col=11 end
          circ(sx,sy, 9 + (G.t%6), col)
        end
      end
    end
  end


  -- contextual hint
  local near=node_near(p,Player.px,Player.py,14)
  local ent=cave_entrance_near(p,Player.px,Player.py,16)
  local atBase = p.base and dist(Player.px,Player.py,p.base.x,p.base.y) < 14

  if atBase then
    hint("X: Open Base   Tap C: Scan   V: Skills")
  elseif ent then
    hint("Z: Enter Cave   Tap C: Scan   X: Takeoff")
  elseif near then
    if near.kind=="food" then hint("Z: Harvest FOOD   Tap C: Scan   X: Takeoff")
    elseif near.kind=="relic" then hint("Z: Collect RELIC   Tap C: Scan   X: Takeoff")
    elseif near.kind=="crate" then hint("Z: Open CRATE   Tap C: Scan   X: Takeoff")
    else hint("Move away from hazard!") end
  else
    hint("Find a cave to mine ores. Tap C: Scan  Hold C: Base")
  end
end

----------------------------
-- Caves: procedural solids + ore veins + persistent mining
----------------------------
local function ckey(c,x,y) return y*c.w + x end

local function cave_raw(c,x,y)
  -- cheap blob noise (uses hashed coarse grids)
  local a = ihash(math.floor(x/2), math.floor(y/2), c.seed)
  local b = ihash(math.floor(x/7), math.floor(y/7), (c.seed*7+13)%2147483647)
  return a*0.65 + b*0.35
end

local function cave_is_wall_base(c,x,y)
  if x<=1 or y<=1 or x>=c.w-2 or y>=c.h-2 then return true end
  -- smooth-ish: decide by neighborhood "open" count
  local open=0
  local depth = y / c.h
  local th = 0.52 + depth*0.10
  for oy=-1,1 do
    for ox=-1,1 do
      if cave_raw(c,x+ox,y+oy) > th then open=open+1 end
    end
  end
  -- more open -> floor
  return open < 5
end

local function cave_ore_index_base(c,x,y,p_typ)
  -- returns 0 none or 1..#ORE_KEYS
  -- ore appears only in walls, in blob clusters
  local depth = y / c.h
  local blob = ihash(math.floor(x/4), math.floor(y/4), (c.seed*17+99)%2147483647)
  if blob < 0.72 then return 0 end

  local r = ihash(x,y,(c.seed*29+7)%2147483647)
  local skew = (p_typ==4) and 0.03 or 0 -- volcanic a bit richer

  -- deeper => rarer ores more likely
  if depth>0.68 and r>0.93-skew then return 6 end -- crystal
  if depth>0.52 and r>0.90-skew then return 5 end -- titanium
  if depth>0.36 and r>0.86-skew then return 4 end -- gold
  if depth>0.22 and r>0.82-skew then return 3 end -- silver
  if depth>0.10 and r>0.76-skew then return 2 end -- copper
  if r>0.62-skew then return 1 end -- iron
  return 0
end

local function cave_compute_cell(c,x,y,p_typ)
  -- 0 floor, 1 wall, -k ore wall
  if x<0 or y<0 or x>=c.w or y>=c.h then return 1 end
  if cave_is_wall_base(c,x,y) then
    local oi=cave_ore_index_base(c,x,y,p_typ)
    if oi>0 then return -oi else return 1 end
  end
  return 0
end

function cave_get_cell(p,c,x,y)
  local k=ckey(c,x,y)
  local v=c.cells[k]
  if v==nil then
    return cave_compute_cell(c,x,y,p.typ)
  end
  return v
end

local function cave_materialize(p,c,x,y)
  local k=ckey(c,x,y)
  if c.cells[k]==nil then
    c.cells[k]=cave_compute_cell(c,x,y,p.typ)
  end
  return c.cells[k]
end

local function cave_cell_hp_base(c,cellVal,y)
  local depth = y / c.h
  local hp = 18 + depth*10
  if cellVal<0 then hp = hp + 10 end -- ore rock a bit tougher
  return hp
end

local function cave_find_valid_spawn(p,c)
  -- Find a nearby floor close to top-middle; then carve a tiny entry pocket.
  local cx = math.floor(c.w/2)
  local cy = 6
  for y=cy, math.min(c.h-8, cy+40) do
    for dx=-12,12 do
      local x=cx+dx
      if cave_get_cell(p,c,x,y)==0 then
        c.spawn={x=x*8+4,y=y*8+4}
        c.exit={x=x,y=y}
        -- ensure small pocket around spawn
        for oy=-1,1 do for ox=-1,1 do
          local k=ckey(c,x+ox,y+oy)
          c.cells[k]=0
        end end
        return
      end
    end
  end
  -- fallback: brute carve at center
  c.spawn={x=cx*8+4,y=cy*8+4}
  c.exit={x=cx,y=cy}
  for oy=-2,2 do for ox=-2,2 do
    local k=ckey(c,cx+ox,cy+oy)
    c.cells[k]=0
  end end
end

local function cave_solid_at(p,c,px,py)
  local cx = math.floor(px/8)
  local cy = math.floor(py/8)
  return cave_get_cell(p,c,cx,cy) ~= 0
end

local function cave_solid_footprint(p,c,px,py)
  local r=3
  if cave_solid_at(p,c,px-r,py-r) then return true end
  if cave_solid_at(p,c,px+r,py-r) then return true end
  if cave_solid_at(p,c,px-r,py+r) then return true end
  if cave_solid_at(p,c,px+r,py+r) then return true end
  return false
end

local function cave_target_cell(p,c,px,py)
  local cx=math.floor(px/8)
  local cy=math.floor(py/8)
  local best=nil
  local bestOre=false
  local dirs={{1,0},{-1,0},{0,1},{0,-1},{1,1},{-1,1},{1,-1},{-1,-1}}
  for i=1,#dirs do
    local dx,dy=dirs[i][1],dirs[i][2]
    local tx=cx+dx
    local ty=cy+dy
    local v=cave_get_cell(p,c,tx,ty)
    if v~=0 then
      local isOre = (v<0) or (cave_ore_index_base(c,tx,ty,p.typ)>0)
      if (not best) or (isOre and not bestOre) then
        best={x=tx,y=ty}; bestOre=isOre
        if bestOre then break end
      end
    end
  end
  return best
end

----------------------------
-- Cave state
----------------------------
local function update_cave()
  local p=G.active_planet
  local c=G.active_cave
  if not (p and c) then G.state="planet"; return end
  if not c.spawn then cave_find_valid_spawn(p,c) end

  -- movement with collision
  local spd=walk_speed()*0.90
  local ax,ay=0,0
  if btn(2) then ax=ax-1 end
  if btn(3) then ax=ax+1 end
  if btn(0) then ay=ay-1 end
  if btn(1) then ay=ay+1 end
  if ax~=0 and ay~=0 then ax=ax*0.7; ay=ay*0.7 end

  local nx = Player.px + lerp(Player.pvx, ax*spd, 0.35)
  local ny = Player.py + lerp(Player.pvy, ay*spd, 0.35)
  local ox,oy=Player.px,Player.py

  Player.pvx=lerp(Player.pvx, ax*spd, 0.35)
  Player.pvy=lerp(Player.pvy, ay*spd, 0.35)

  Player.px=clamp(nx, 8, c.w*8-8)
  if cave_solid_footprint(p,c,Player.px,Player.py) then Player.px=ox; Player.pvx=0 end
  Player.py=clamp(ny, 8, c.h*8-8)
  if cave_solid_footprint(p,c,Player.px,Player.py) then Player.py=oy; Player.pvy=0 end

  G.cave_camx=clamp(Player.px-W/2,0,c.w*8-W)
  G.cave_camy=clamp(Player.py-H/2,0,c.h*8-H)

  if btnp(7) then G.state="skills" end

  -- scanner ping (tap C)
  if btnp(6) then scan_pulse("cave") end

  -- mine (hold Z)
  if btn(4) then
    if inv_total()>=inv_max() then
      if (G.t%20)==0 then toast("Cargo full.",70) end
    else
      local tgt=cave_target_cell(p,c,Player.px,Player.py)
      if tgt then
        local tx,ty=tgt.x,tgt.y
        local k=ckey(c,tx,ty)
        local cellVal = cave_materialize(p,c,tx,ty)
        local hp = c.hp[k]
        if hp==nil then
          hp=cave_cell_hp_base(c,cellVal,ty)
          c.hp[k]=hp
        end

        local mp=mining_power()
        hp = hp - mp*0.55
        c.hp[k]=hp

        -- spark particles
        local col=12
        local oreIndex = (cellVal<0) and (-cellVal) or 0
        if oreIndex>0 then col = ORE[ORE_KEYS[oreIndex]].col end
        if (G.t%2)==0 then
          add_particle(tx*8+4,ty*8+4,(ihash(G.t,1,c.seed)-0.5)*0.8,(ihash(G.t,2,c.seed)-0.9)*0.8,12,col)
        end

        if hp<=0 then
          c.hp[k]=nil
          c.cells[k]=0 -- carved
          -- reward if ore
          if oreIndex==0 then oreIndex=cave_ore_index_base(c,tx,ty,p.typ) end
          if oreIndex>0 then
            local key=ORE_KEYS[oreIndex]
            Player.inv[key]=(Player.inv[key] or 0)+1
            add_xp(8 + oreIndex*2)
            toast("+"..ORE[key].name,80)
            for j=1,8 do
              add_particle(tx*8+4,ty*8+4,(ihash(j,G.t,c.seed)-0.5)*1.4,(ihash(G.t,j,c.seed)-0.8)*1.6,16,ORE[key].col)
            end
          else
            add_xp(2)
            if (G.t%20)==0 then toast("Dug through rock.",60) end
          end
        end
      end
    end
  end

  -- exit cave
  if btnp(5) then
    local ex=c.exit and (c.exit.x*8+4) or c.spawn.x
    local ey=c.exit and (c.exit.y*8+4) or c.spawn.y
    if dist(Player.px,Player.py,ex,ey) < 14 then
      start_fade(function()
        G.state="planet"
        if G.surface_return then
          Player.px=G.surface_return.x; Player.py=G.surface_return.y
        end
        Player.pvx=0; Player.pvy=0
        G.active_cave=nil
        toast("Back to surface.",120)
      end)
      return
    else
      toast("Find the exit ladder.",90)
    end
  end
end

local function draw_cave()
  local p=G.active_planet
  local c=G.active_cave
  if not (p and c) then cls(0); return end
  if not c.spawn then cave_find_valid_spawn(p,c) end

  cls(0)

  -- cave rock tint influenced by planet palette
  local pal=PLANET_TYPES[p.typ].pal
  local wallBright = (p.typ==2) and 13 or 5
  local wallMid    = (p.typ==2) and 12 or 1
  local wallDark   = 0
  local floorBright= (p.typ==4) and 0 or 1
  local floorMid   = 0

  local cx0=math.floor(G.cave_camx/8)
  local cy0=math.floor(G.cave_camy/8)
  local cx1=cx0+math.ceil(W/8)+1
  local cy1=cy0+math.ceil(H/8)+1

  local pcx=Player.px/8
  local pcy=Player.py/8
  local rad=7.2

  for cy=cy0,cy1 do
    for cx=cx0,cx1 do
      local v=cave_get_cell(p,c,cx,cy)
      local px=cx*8-G.cave_camx
      local py=cy*8-G.cave_camy

      local d = dist(pcx,pcy,cx+0.5,cy+0.5)
      local band
      if d<3.2 then band=3
      elseif d<5.0 then band=2
      elseif d<rad then band=1
      else band=0 end

      -- scanner reveals ore veins beyond headlamp for a moment
      if (G.scan_t and G.scan_t>0 and G.scan_mode=="cave") then
        if v<0 and d < (rad + scan_range_cave()) then
          if band<1 then band=1 end
        end
      end

      if v==0 then
        local col = (band>=2) and floorBright or floorMid
        rect(px,py,8,8,col)
        -- floor speckle
        if band>0 and ihash(cx,cy,c.seed)>0.92 then pix(px+2,py+5,wallMid) end
      else
        -- wall base
        local col = (band>=3) and wallBright or ((band>=1) and wallMid or wallDark)
        rect(px,py,8,8,col)
        -- outline / chunk
        if band>0 then
          line(px,py,px+7,py,wallDark)
          line(px,py,px,py+7,wallDark)
        end

        -- ore flecks embedded in wall
        local oreIndex = (v<0) and (-v) or cave_ore_index_base(c,cx,cy,p.typ)
        if band>0 and oreIndex>0 then
          local ok=ORE_KEYS[oreIndex]
          local oc=ORE[ok].col
          for i=0,3 do
            local rx = px + math.floor(ihash(cx+i,cy-i,c.seed*3+11)*7)
            local ry = py + math.floor(ihash(cx-i,cy+i,c.seed*5+29)*7)
            pix(rx,ry,oc)
          end
          -- subtle glow for crystals
          if ok=="crystal" and band>=2 then
            pix(px+4,py+4,15)
          end
        end

        -- mining cracks if currently being mined
        local k=ckey(c,cx,cy)
        if band>0 and c.hp[k] then
          line(px+1,py+6,px+6,py+2,15)
          line(px+2,py+7,px+7,py+3,wallDark)
        end
      end

      -- heavy darkness outside light radius
      if band==0 then
        rect(px,py,8,8,0)
      end
    end
  end

  -- exit marker at spawn/ladder
  local ex = (c.exit and c.exit.x*8+4) or c.spawn.x
  local ey = (c.exit and c.exit.y*8+4) or c.spawn.y
  local lx=ex-G.cave_camx
  local ly=ey-G.cave_camy
  if lx>-10 and lx<W+10 and ly>-10 and ly<H+10 then
    rect(lx-3,ly-6,6,12,12)
    line(lx-2,ly-5,lx-2,ly+5,15)
    line(lx+2,ly-5,lx+2,ly+5,15)
    line(lx-2,ly-2,lx+2,ly-2,15)
    line(lx-2,ly+1,lx+2,ly+1,15)
  end

  draw_particles(G.cave_camx,G.cave_camy)
  draw_astronaut(Player.px-G.cave_camx, Player.py-G.cave_camy)
  draw_hud(true)
  draw_cave_minimap(p,c)

  -- contextual hint
  local dExit = dist(Player.px,Player.py,ex,ey)
  if dExit<14 then
    hint("X: Exit Cave   Hold Z: Mine   Tap C: Scan")
  else
    hint("Hold Z: Mine ore veins in walls  |  Tap C: Scan  |  Exit (X)")
  end
end

----------------------------
-- Base menu state (slightly expanded inventory view)
----------------------------
local function update_base()
  if btnp(1) then BaseMenu.idx=clamp(BaseMenu.idx+1,1,#BaseMenu.items) end
  if btnp(0) then BaseMenu.idx=clamp(BaseMenu.idx-1,1,#BaseMenu.items) end

  if btnp(4) then
    local it=BaseMenu.items[BaseMenu.idx]
    if it.can() then it.do_it() else toast("Missing resources.",110) end
  end

  if btnp(7) then G.state="skills" end
  if btnp(5) then G.state="planet" end
end

local function draw_base_menu()
  cls(0)
  panel(10,10,220,116)
  print("BASE", 18, 14, UI.text)

  panel(14,28,96,90)
  print("STATUS", 18, 32, UI.dim)
  print("HP  "..math.floor(Player.health), 18, 44, UI.text)
  print("HUN "..math.floor(Player.hunger), 18, 54, UI.text)
  print("CARGO "..inv_total().."/"..inv_max(), 18, 64, UI.dim)
  print("LV "..Player.level.."  SP "..Player.sp, 18, 76, UI.dim)

  print("UPGR", 18, 90, UI.dim)
  print("Eng "..Player.upgrades.engine, 18, 100, UI.text)
  print("Drl "..Player.upgrades.drill, 58, 100, UI.text)
  print("Crg "..Player.upgrades.cargo, 18, 110, UI.text)
  print("Suit "..Player.upgrades.suit, 58, 110, UI.text)

  -- quick ore inventory preview
  panel(14,120,96,16)
  print("IRN "..Player.inv.iron.." CUP "..Player.inv.copper.." SLV "..Player.inv.silver, 18, 124, UI.text)

  panel(114,28,112,108)
  print("ACTIONS", 118, 32, UI.dim)

  for i=1,#BaseMenu.items do
    local it=BaseMenu.items[i]
    local y=44+(i-1)*14
    local sel=(i==BaseMenu.idx)
    if sel then rect(118,y-1,104,12,UI.panel2) end
    local col = it.can() and UI.text or UI.faint
    print(it.name, 122, y, col)
  end

  local it=BaseMenu.items[BaseMenu.idx]
  panel(114,120,112,16)
  print(it.cost, 118, 124, UI.text)

  print("Z: Select   X: Back   V: Skills", 58, 14, UI.dim)
  draw_hud(false)
end

----------------------------
-- Skills menu state (unchanged)
----------------------------
local function update_skills()
  if btnp(2) then skill_move(-1,0) end
  if btnp(3) then skill_move( 1,0) end
  if btnp(0) then skill_move(0,-1) end
  if btnp(1) then skill_move(0, 1) end

  if btnp(4) then
    local node=SkillTree.nodes[SkillTree.cur]
    if can_buy(node) then
      SkillTree.owned[node.id]=true
      Player.sp=Player.sp-1
      apply_skill(node)
      toast("Learned "..node.name,160)
    else
      toast("Locked / no points.",110)
    end
  end

  if btnp(5) then
    if G.active_cave then
      G.state="cave"
    elseif G.active_planet then
      local p=G.active_planet
      local atBase = p.base and dist(Player.px,Player.py,p.base.x,p.base.y)<14
      G.state = atBase and "base" or "planet"
    else
      G.state="space"
    end
  end
end

local function draw_skills()
  cls(0)
  panel(10,10,220,116)
  print("SKILLS", 18, 14, UI.text)
  print("SP:"..Player.sp.."  Z: Learn  X: Back", 140, 14, UI.dim)

  panel(14,28,150,94)

  for i=1,#SkillTree.nodes do
    local n=SkillTree.nodes[i]
    local x=18+n.x
    local y=32+n.y
    for j=1,#n.req do
      local rid=n.req[j]
      for k=1,#SkillTree.nodes do
        if SkillTree.nodes[k].id==rid then
          local r=SkillTree.nodes[k]
          local rx=18+r.x
          local ry=32+r.y
          local col = has_skill(rid) and 11 or UI.faint
          line(rx,ry,x,y,col)
        end
      end
    end
  end

  for i=1,#SkillTree.nodes do
    local n=SkillTree.nodes[i]
    local x=18+n.x
    local y=32+n.y
    local owned=has_skill(n.id)
    local can=can_buy(n)
    local sel=(i==SkillTree.cur)

    local c = owned and 11 or (can and 15 or UI.faint)
    circ(x,y,6,UI.ink)
    circ(x,y,5,c)
    circ(x-2,y-2,2,15)
    if sel then
      circ(x,y,7,12)
      circ(x,y,8,0)
    end
  end

  panel(168,28,58,94)
  local n=SkillTree.nodes[SkillTree.cur]
  local owned=has_skill(n.id)
  local can=can_buy(n)

  print(n.name, 172, 32, UI.text)
  print(n.desc, 172, 44, UI.dim)

  local status = owned and "OWNED" or (can and "LEARN" or "LOCK")
  local scol = owned and 11 or (can and 15 or UI.faint)
  rect(172,62,50,10,UI.panel2)
  rectb(172,62,50,10,UI.border)
  print(status, 182, 64, scol)

  print("Ship", 172, 78, UI.dim)
  print(string.format("%.2f", ship_speed()), 172, 88, UI.text)
  print("Mine", 172, 98, UI.dim)
  print(string.format("%.1f", mining_power()), 172, 108, UI.text)

  draw_hud(false)
end

----------------------------
-- Init
----------------------------
local function init()
  gen_planets(1337)
  toast("Explore planets. Enter caves to mine ores. X land/takeoff, Z interact, C base, V skills", 260)
end
init()

----------------------------
-- Main loop
----------------------------
function TIC()
  G.t=G.t+1
  if G.toast.t>0 then G.toast.t=G.toast.t-1 end
  if G.scan_t and G.scan_t>0 then G.scan_t=G.scan_t-1 end

  if (G.t%2)==0 then survival_tick() end
  update_particles()
  update_fade()

  if G.state=="space" then
    update_space(); draw_space()
  elseif G.state=="planet" then
    update_planet(); draw_planet()
  elseif G.state=="cave" then
    update_cave(); draw_cave()
  elseif G.state=="base" then
    update_base(); draw_base_menu()
  elseif G.state=="skills" then
    update_skills(); draw_skills()
  else
    G.state="space"
  end

  draw_fade()
end
