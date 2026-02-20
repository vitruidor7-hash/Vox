-- LÖVE2D port wrapper for a TIC-80 Lua cart (no sprites/maps/sfx).
-- Run this folder with LÖVE.
--
-- Controls (mapped to TIC-80 btn indices):
--   0 up    : Up / W
--   1 down  : Down / S
--   2 left  : Left / A
--   3 right : Right / D
--   4 A     : Z
--   5 B     : X
--   6 X     : C
--   7 Y     : V
--
-- Esc quits.

local VW, VH = 240, 136
local STEP = 1/60


local userScale = 6  -- default integer zoom (240x136 * 6 = 1440x816)
local fullscreen = false
-- Keep a reference to normal console print
local sys_print = _G.print

-- Remastered palette (cleaner, higher-contrast pixel-art tones)
local PAL = {
  [0]={0x07,0x0B,0x14}, [1]={0x16,0x1A,0x2C}, [2]={0x2A,0x1F,0x3A}, [3]={0x53,0x2B,0x34},
  [4]={0x8A,0x4A,0x2F}, [5]={0xB9,0x7E,0x39}, [6]={0xD5,0xB5,0x66}, [7]={0x79,0xB4,0x57},
  [8]={0x3E,0x8F,0x73}, [9]={0x2C,0x79,0x98}, [10]={0x4B,0x8F,0xD9}, [11]={0x74,0xD6,0xE8},
  [12]={0xC7,0xD7,0xF2}, [13]={0x9A,0xA3,0xC0}, [14]={0x6C,0x74,0x96}, [15]={0xF2,0xF7,0xFF},
}

local function set_pal_color(idx)
  local c = PAL[idx or 0] or PAL[0]
  love.graphics.setColor(c[1]/255, c[2]/255, c[3]/255, 1)
end

-- Display list for TIC-like immediate drawing
local DL = {}
local clear_col = 0

-- TIC-80 API subset ----------------------------------------------------------
function cls(c)
  clear_col = c or 0
  DL = {}
end

function pix(x,y,c)
  DL[#DL+1] = {"pix", x, y, c or 15}
end

function line(x1,y1,x2,y2,c)
  DL[#DL+1] = {"line", x1, y1, x2, y2, c or 15}
end

function rect(x,y,w,h,c)
  DL[#DL+1] = {"rect", x, y, w, h, c or 15}
end

function rectb(x,y,w,h,c)
  DL[#DL+1] = {"rectb", x, y, w, h, c or 15}
end

function circ(x,y,r,c)
  DL[#DL+1] = {"circ", x, y, r, c or 15}
end

function tri(x1,y1,x2,y2,x3,y3,c)
  DL[#DL+1] = {"tri", x1, y1, x2, y2, x3, y3, c or 15}
end

-- TIC's print() draws text; fall back to console print if called without x,y.
function print(s,x,y,c)
  if type(x)=="number" and type(y)=="number" then
    DL[#DL+1] = {"text", tostring(s or ""), x, y, c or 15}
  else
    return sys_print(s,x,y,c)
  end
end

-- Input (TIC-80 btn indices: 0U 1D 2L 3R 4A 5B 6X 7Y)
local btnState = {[0]=false,[1]=false,[2]=false,[3]=false,[4]=false,[5]=false,[6]=false,[7]=false}
function btn(i) return btnState[i] == true end

local function update_buttons()
  btnState[0] = love.keyboard.isDown("up","w")
  btnState[1] = love.keyboard.isDown("down","s")
  btnState[2] = love.keyboard.isDown("left","a")
  btnState[3] = love.keyboard.isDown("right","d")
  btnState[4] = love.keyboard.isDown("z")
  btnState[5] = love.keyboard.isDown("x")
  btnState[6] = love.keyboard.isDown("c")
  btnState[7] = love.keyboard.isDown("v")
end

-- Rendering ------------------------------------------------------------------
local canvas
local font

local function apply_window_mode()
  -- NOTE: Even if conf.lua sets highdpi=true, calling setMode() again without it
  -- can disable it, causing the OS to upscale the game and make it blurry.
  love.window.setMode(
    VW*userScale, VH*userScale,
    {
      resizable=true,
      vsync=1,
      minwidth=VW*2,
      minheight=VH*2,
      highdpi=true,
      msaa=0,
    }
  )
end

local function render_display_list()
  love.graphics.setCanvas(canvas)
  set_pal_color(clear_col)
  love.graphics.clear()

  love.graphics.setLineStyle("rough")
  love.graphics.setLineJoin("miter")

  local cur = -1
  for i=1,#DL do
    local cmd = DL[i]
    local t = cmd[1]
    local col = cmd[#cmd]
    if col ~= cur then
      cur = col
      set_pal_color(col)
    end

    if t=="pix" then
      love.graphics.points(cmd[2], cmd[3])
    elseif t=="line" then
      love.graphics.line(cmd[2], cmd[3], cmd[4], cmd[5])
    elseif t=="rect" then
      love.graphics.rectangle("fill", cmd[2], cmd[3], cmd[4], cmd[5])
    elseif t=="rectb" then
      love.graphics.rectangle("line", cmd[2], cmd[3], cmd[4], cmd[5])
    elseif t=="circ" then
      love.graphics.circle("fill", cmd[2], cmd[3], cmd[4])
    elseif t=="tri" then
      love.graphics.polygon("fill", cmd[2], cmd[3], cmd[4], cmd[5], cmd[6], cmd[7])
    elseif t=="text" then
      love.graphics.print(cmd[2], cmd[3], cmd[4])
    end
  end

  love.graphics.setCanvas()
end

local function draw_scaled_canvas()
  local ww, wh = love.graphics.getDimensions()
  local scale = userScale
  -- Clamp scale so the whole canvas still fits
  local maxScale = math.floor(math.min(ww / VW, wh / VH))
  if maxScale < 1 then maxScale = 1 end
  if scale > maxScale then scale = maxScale end
  if scale < 1 then scale = 1 end

  local ox = math.floor((ww - VW*scale) / 2)
  local oy = math.floor((wh - VH*scale) / 2)

  love.graphics.setColor(0,0,0,1)
  love.graphics.rectangle("fill", 0, 0, ww, wh)

  love.graphics.setColor(1,1,1,1)
  love.graphics.draw(canvas, ox, oy, 0, scale, scale)
end

-- Game -----------------------------------------------------------------------
local acc = 0

function love.load()
  -- Big default window so the 240x136 game is readable.
  -- You can change zoom at runtime with +/- (or press 0 to reset).
  apply_window_mode()
  love.graphics.setDefaultFilter("nearest","nearest")
  -- Make sure primitive drawing isn't anti-aliased.
  if love.graphics.setPointStyle then love.graphics.setPointStyle("rough") end
  if love.graphics.setPointSize then love.graphics.setPointSize(1) end
  canvas = love.graphics.newCanvas(VW, VH)
  canvas:setFilter("nearest","nearest")

  font = love.graphics.newFont(8)
  font:setFilter("nearest","nearest")
  love.graphics.setFont(font)

  require("game") -- defines global TIC()

  update_buttons()
  if type(_G.TIC) == "function" then _G.TIC() end
end

function love.update(dt)
  if love.keyboard.isDown("escape") then
    love.event.quit()
    return
  end

  acc = acc + dt
  local steps = 0
  while acc >= STEP and steps < 6 do
    update_buttons()
    if type(_G.TIC) == "function" then _G.TIC() end
    acc = acc - STEP
    steps = steps + 1
  end
end

function love.draw()
  render_display_list()
  draw_scaled_canvas()
end


function love.keypressed(k)
  if k == "f" then
    fullscreen = not fullscreen
    love.window.setFullscreen(fullscreen)
    -- When returning from fullscreen, re-apply our mode options (esp. highdpi)
    if not fullscreen then apply_window_mode() end
  elseif k == "=" or k == "+" or k == "kp+" then
    userScale = userScale + 1
    apply_window_mode()
  elseif k == "-" or k == "kp-" then
    userScale = math.max(1, userScale - 1)
    apply_window_mode()
  elseif k == "0" then
    userScale = 6
    apply_window_mode()
  end
end
