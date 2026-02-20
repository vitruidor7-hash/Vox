function love.conf(t)
  t.window.title = "Space Explorer RPG (TIC-80 -> LÖVE2D)"
  t.window.width = 1440
  t.window.height = 816
  t.window.resizable = true
  t.window.vsync = 1
  -- IMPORTANT for crisp pixel-art on high-DPI displays:
  -- keep highdpi enabled (otherwise the OS may upscale the backbuffer and blur it).
  t.window.highdpi = true
  t.window.msaa = 0
end