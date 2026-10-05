--------------------------------------------------------------------------------------------------------------------------
-- tools lib v0.1 (c) tinman
--------------------------------------------------------------------------------------------------------------------------

local unpack, table_concat, byte, char, string_rep, sub, gsub, gmatch, string_format, floor, ceil, math_min, math_max, tonumber, type =
   table.unpack or unpack, table.concat, string.byte, string.char, string.rep, string.sub, string.gsub, string.gmatch, 
   string.format, math.floor, math.ceil, math.min, math.max, tonumber, type

--------------------------------------------------------------------------------------------------------------------------
-- md5
--------------------------------------------------------------------------------------------------------------------------
md5lib = {
  _VERSION     = "md5.lua 1.1.0",
  _DESCRIPTION = "MD5 computation in Lua (5.1-3, LuaJIT)",
  _URL         = "https://github.com/kikito/md5.lua",
  _LICENSE     = [[
    MIT LICENSE
    Copyright (c) 2013 Enrique García Cota + Adam Baldwin + hanzao + Equi 4 Software
    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the
    "Software"), to deal in the Software without restriction, including
    without limitation the rights to use, copy, modify, merge, publish,
    distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to
    the following conditions:
    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
    SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
  ]]
}

local bit_or, bit_and, bit_not, bit_xor, bit_rshift, bit_lshift
 
to_bits = bit32.tobit
bit_not = bit32.bnot
bit_or = bit32.bor
bit_and = bit32.band
bit_xor = bit32.bxor
bit_rshift = bit32.rshift
bit_lshift = bit32.lshift

-- convert little-endian 32-bit int to a 4-char string
local function lei2str(i)
  local f=function (s) return char( bit_and( bit_rshift(i, s), 255)) end
  return f(0)..f(8)..f(16)..f(24)
end

-- convert raw string to big-endian int
local function str2bei(s)
  local v=0
  for i=1, #s do
    v = v * 256 + byte(s, i)
  end
  return v
end

-- convert raw string to little-endian int
local function str2lei(s)
  local v=0
  for i = #s,1,-1 do
    v = v*256 + byte(s, i)
  end
  return v
end

-- cut up a string in little-endian ints of given size
local function cut_le_str(s,...)
  local o, r = 1, {}
  local args = {...}
  for i=1, #args do
    table.insert(r, str2lei(sub(s, o, o + args[i] - 1)))
    o = o + args[i]
  end
  return r
end

local swap = function (w) return str2bei(lei2str(w)) end

-- An MD5 mplementation in Lua, requires bitlib (hacked to use LuaBit from above, ugh)
-- 10/02/2001 jcw@equi4.com

local CONSTS = {
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
  0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
  0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
  0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
}

local f=function (x,y,z) return bit_or(bit_and(x,y),bit_and(-x-1,z)) end
local g=function (x,y,z) return bit_or(bit_and(x,z),bit_and(y,-z-1)) end
local h=function (x,y,z) return bit_xor(x,bit_xor(y,z)) end
local i=function (x,y,z) return bit_xor(y,bit_or(x,-z-1)) end
local z=function (ff,a,b,c,d,x,s,ac)
  a=bit_and(a+ff(b,c,d)+x+ac,0xFFFFFFFF)
  -- be *very* careful that left shift does not cause rounding!
  return bit_or(bit_lshift(bit_and(a,bit_rshift(0xFFFFFFFF,s)),s),bit_rshift(a,32-s))+b
end

local function transform(A,B,C,D,X)
  local a,b,c,d=A,B,C,D
  local t=CONSTS

  a=z(f,a,b,c,d,X[ 0], 7,t[ 1])
  d=z(f,d,a,b,c,X[ 1],12,t[ 2])
  c=z(f,c,d,a,b,X[ 2],17,t[ 3])
  b=z(f,b,c,d,a,X[ 3],22,t[ 4])
  a=z(f,a,b,c,d,X[ 4], 7,t[ 5])
  d=z(f,d,a,b,c,X[ 5],12,t[ 6])
  c=z(f,c,d,a,b,X[ 6],17,t[ 7])
  b=z(f,b,c,d,a,X[ 7],22,t[ 8])
  a=z(f,a,b,c,d,X[ 8], 7,t[ 9])
  d=z(f,d,a,b,c,X[ 9],12,t[10])
  c=z(f,c,d,a,b,X[10],17,t[11])
  b=z(f,b,c,d,a,X[11],22,t[12])
  a=z(f,a,b,c,d,X[12], 7,t[13])
  d=z(f,d,a,b,c,X[13],12,t[14])
  c=z(f,c,d,a,b,X[14],17,t[15])
  b=z(f,b,c,d,a,X[15],22,t[16])

  a=z(g,a,b,c,d,X[ 1], 5,t[17])
  d=z(g,d,a,b,c,X[ 6], 9,t[18])
  c=z(g,c,d,a,b,X[11],14,t[19])
  b=z(g,b,c,d,a,X[ 0],20,t[20])
  a=z(g,a,b,c,d,X[ 5], 5,t[21])
  d=z(g,d,a,b,c,X[10], 9,t[22])
  c=z(g,c,d,a,b,X[15],14,t[23])
  b=z(g,b,c,d,a,X[ 4],20,t[24])
  a=z(g,a,b,c,d,X[ 9], 5,t[25])
  d=z(g,d,a,b,c,X[14], 9,t[26])
  c=z(g,c,d,a,b,X[ 3],14,t[27])
  b=z(g,b,c,d,a,X[ 8],20,t[28])
  a=z(g,a,b,c,d,X[13], 5,t[29])
  d=z(g,d,a,b,c,X[ 2], 9,t[30])
  c=z(g,c,d,a,b,X[ 7],14,t[31])
  b=z(g,b,c,d,a,X[12],20,t[32])

  a=z(h,a,b,c,d,X[ 5], 4,t[33])
  d=z(h,d,a,b,c,X[ 8],11,t[34])
  c=z(h,c,d,a,b,X[11],16,t[35])
  b=z(h,b,c,d,a,X[14],23,t[36])
  a=z(h,a,b,c,d,X[ 1], 4,t[37])
  d=z(h,d,a,b,c,X[ 4],11,t[38])
  c=z(h,c,d,a,b,X[ 7],16,t[39])
  b=z(h,b,c,d,a,X[10],23,t[40])
  a=z(h,a,b,c,d,X[13], 4,t[41])
  d=z(h,d,a,b,c,X[ 0],11,t[42])
  c=z(h,c,d,a,b,X[ 3],16,t[43])
  b=z(h,b,c,d,a,X[ 6],23,t[44])
  a=z(h,a,b,c,d,X[ 9], 4,t[45])
  d=z(h,d,a,b,c,X[12],11,t[46])
  c=z(h,c,d,a,b,X[15],16,t[47])
  b=z(h,b,c,d,a,X[ 2],23,t[48])

  a=z(i,a,b,c,d,X[ 0], 6,t[49])
  d=z(i,d,a,b,c,X[ 7],10,t[50])
  c=z(i,c,d,a,b,X[14],15,t[51])
  b=z(i,b,c,d,a,X[ 5],21,t[52])
  a=z(i,a,b,c,d,X[12], 6,t[53])
  d=z(i,d,a,b,c,X[ 3],10,t[54])
  c=z(i,c,d,a,b,X[10],15,t[55])
  b=z(i,b,c,d,a,X[ 1],21,t[56])
  a=z(i,a,b,c,d,X[ 8], 6,t[57])
  d=z(i,d,a,b,c,X[15],10,t[58])
  c=z(i,c,d,a,b,X[ 6],15,t[59])
  b=z(i,b,c,d,a,X[13],21,t[60])
  a=z(i,a,b,c,d,X[ 4], 6,t[61])
  d=z(i,d,a,b,c,X[11],10,t[62])
  c=z(i,c,d,a,b,X[ 2],15,t[63])
  b=z(i,b,c,d,a,X[ 9],21,t[64])

  return bit_and(A+a,0xFFFFFFFF),bit_and(B+b,0xFFFFFFFF),
         bit_and(C+c,0xFFFFFFFF),bit_and(D+d,0xFFFFFFFF)
end

local function md5_update(self, s)
  self.pos = self.pos + #s
  s = self.buf .. s
  for ii = 1, #s - 63, 64 do
    local X = cut_le_str(sub(s,ii,ii+63),4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4)
    assert(#X == 16)
    X[0] = table.remove(X,1) -- zero based!
    self.a,self.b,self.c,self.d = transform(self.a,self.b,self.c,self.d,X)
  end
  self.buf = sub(s, math.floor(#s/64)*64 + 1, #s)
  return self
end

local function md5_finish(self)
  local msgLen = self.pos
  local padLen = 56 - msgLen % 64

  if msgLen % 64 > 56 then padLen = padLen + 64 end

  if padLen == 0 then padLen = 64 end

  local s = char(128) .. string_rep(char(0),padLen-1) .. lei2str(bit_and(8*msgLen, 0xFFFFFFFF)) .. lei2str(math.floor(msgLen/0x20000000))
  md5_update(self, s)

  assert(self.pos % 64 == 0)
  return lei2str(self.a) .. lei2str(self.b) .. lei2str(self.c) .. lei2str(self.d)
end

local function md5lib_new()
  return { a = CONSTS[65], b = CONSTS[66], c = CONSTS[67], d = CONSTS[68],
           pos = 0,
           buf = '',
           update = md5_update,
           finish = md5_finish }
end

local function md5lib_tohex(s)
  return string_format("%08x%08x%08x%08x", str2bei(sub(s, 1, 4)), str2bei(sub(s, 5, 8)), str2bei(sub(s, 9, 12)), str2bei(sub(s, 13, 16)))
end

local function md5lib_sum(s)
  return md5lib_new():update(s):finish()
end

local function md5lib_sumhexa(s)
  return md5lib_tohex(md5lib_sum(s))
end

--------------------------------------------------------------------------------------------------------------------------
-- hex bin base64 tools
--------------------------------------------------------------------------------------------------------------------------
 
local hex2bin, bin2base64, base642bin, base642hex
do
   function hex2bin(hex_string)
      return (gsub(hex_string, "%x%x",
         function (hh)
            return char(tonumber(hh, 16))
         end
      ))
   end

   local base64_symbols = {
      ['+'] = 62, ['-'] = 62,  [62] = '+',
      ['/'] = 63, ['_'] = 63,  [63] = '/',
      ['='] = -1, ['.'] = -1,  [-1] = '='
   }
   local symbol_index = 0
   for j, pair in ipairs{'AZ', 'az', '09'} do
      for ascii = byte(pair), byte(pair, 2) do
         local ch = char(ascii)
         base64_symbols[ch] = symbol_index
         base64_symbols[symbol_index] = ch
         symbol_index = symbol_index + 1
      end
   end

   function bin2base64(binary_string)
      if binary_string == nil then return "" else
        local result = {}
        for pos = 1, #binary_string, 3 do
            local c1, c2, c3, c4 = byte(sub(binary_string, pos, pos + 2)..'\0', 1, -1)
            result[#result + 1] =
                base64_symbols[floor(c1 / 4)]
                ..base64_symbols[c1 % 4 * 16 + floor(c2 / 16)]
                ..base64_symbols[c3 and c2 % 16 * 4 + floor(c3 / 64) or -1]
                ..base64_symbols[c4 and c3 % 64 or -1]
        end
        return table_concat(result)
      end
   end

   function base642bin(base64_string)
      if base64_string == nil then return "" else
        local result, chars_qty = {}, 3
        for pos, ch in gmatch(gsub(base64_string, '%s+', ''), '()(.)') do
            local code = base64_symbols[ch]
            if code < 0 then
                chars_qty = chars_qty - 1
                code = 0
            end
            local idx = pos % 4
            if idx > 0 then
                result[-idx] = code
            else
                local c1 = result[-1] * 4 + floor(result[-2] / 16)
                local c2 = (result[-2] % 16) * 16 + floor(result[-3] / 4)
                local c3 = (result[-3] % 4) * 64 + code
                result[#result + 1] = sub(char(c1, c2, c3), 1, chars_qty)
            end
        end
        return table_concat(result)
      end
   end
   function base642hex(base64_string)
      local data = base642bin(base64_string)
      local hextbl = {}
      for d in data:gmatch(".") do
        table.insert(hextbl, string.format("%02x", d:byte()))
      end
      return table.concat(hextbl, "")
   end
end

--------------------------------------------------------------------------------------------------------------------------
-- replacement for json encode, with sort order
-- thanks to Jan Gabrielsson for that code
--------------------------------------------------------------------------------------------------------------------------
--[[
local payloadMKeys = {key1 = 1, key2 = 2, key3 = 3, key4 = 4, key5 = 5, key6 = 6, key7 = 7, key8 = 8, key9 = 9} -- Priority order of fields
local payloadMax   = 9
]]--

payloadMKeys = {}

local function keyCompare(a, b)
    local av, bv = payloadKeys[a], payloadKeys[b]
    if av == nil then
        payloadMax = payloadMax + 1
        payloadKeys[a] = payloadMax
        av = payloadMax
    end
    if bv == nil then
        payloadMax = payloadMax + 1
        payloadKeys[b] = payloadMax
        bv = payloadMax
    end
    return av < bv
end

local function prettyJson(e) -- our own json encode, as we don't have 'pure' json structs, and sorts keys in order
    local res, seen = {}, {}
    local function pretty(e)
        local t = type(e)
        if t == "string" then
            res[#res + 1] = '"'
            res[#res + 1] = e
            res[#res + 1] = '"'
        elseif t == "number" then
            res[#res + 1] = e
        elseif t == "boolean" or t == "function" or t == "thread" then
            res[#res + 1] = tostring(e)
        elseif t == "table" then
            if next(e) == nil then
                res[#res + 1] = "{}"
            elseif seen[e] then
                res[#res + 1] = "..rec.."
            elseif e[1] or #e > 0 then
                seen[e] = true
                res[#res + 1] = "["
                pretty(e[1])
                for i = 2, #e do
                    res[#res + 1] = ","
                    pretty(e[i])
                end
                res[#res + 1] = "]"
            else
                seen[e] = true
                if e._var_ then
                    res[#res + 1] = format('"%s"', e._str)
                    return
                end
                local k = {}
                for key, _ in pairs(e) do
                    k[#k + 1] = key
                end
                table.sort(k, keyCompare)
                if #k == 0 then
                    res[#res + 1] = "[]"
                    return
                end
                res[#res + 1] = "{"
                res[#res + 1] = '"'
                res[#res + 1] = k[1]
                res[#res + 1] = '":'
                t = k[1]
                pretty(e[t])
                for i = 2, #k do
                    res[#res + 1] = ',"'
                    res[#res + 1] = k[i]
                    res[#res + 1] = '":'
                    t = k[i]
                    pretty(e[t])
                end
                res[#res + 1] = "}"
            end
        elseif e == nil then
            res[#res + 1] = "null"
        else
            error("bad json expr:" .. tostring(e))
        end
    end
    pretty(e)
    return table.concat(res)
end

local function try(f, catch_f)
    local status, exception = pcall(f)
    if not status then
        catch_f(exception)
    end
end

local function round(x)
    return math.floor(x + 0.5)
end

local function rgb_to_hsv(r, g, b)
    local K = 0
    if g < b then
        g, b = b, g
        K = -1
    end
    if r < g then
        r, g = g, r
        K = -2 / 6 - K
    end
    local chroma = r - math.min(g, b)
    local h = math.abs(K + (g - b) / (6 * chroma + 1e-20))
    local s = chroma / (r + 1e-20)
    local v = r / 255
    return h * 360, s, v
end

local function hsv_to_rgb(h, s, v)
    if s == 0 then --gray
        return v, v, v
    end
    local H = h / 60
    local i = math.floor(H) --which 1/6 part of hue circle
    local f = H - i
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))
    if i == 0 then
        return v, t, p
    elseif i == 1 then
        return q, v, p
    elseif i == 2 then
        return p, v, t
    elseif i == 3 then
        return p, q, v
    elseif i == 4 then
        return t, p, v
    else
        return v, p, q
    end
end

--rgb is in (0..1, 0..1, 0..1); hsl is (0..360, 0..1, 0..1)
local function rgb_to_hsl(r, g, b)
    local min = math.min(r, g, b)
    local max = math.max(r, g, b)
    local delta = max - min

    local h, s, l = 0, 0, (min + max) / 2

    if l > 0 and l < 0.5 then s = delta / (max + min) end
    if l >= 0.5 and l < 1 then s = delta / (2 - max - min) end

    if delta > 0 then
        if max == r and max ~= g then h = h + (g-b) / delta end
        if max == g and max ~= b then h = h + 2 + (b-r) / delta end
        if max == b and max ~= r then h = h + 4 + (r-g) / delta end
        h = h / 6
    end

    if h < 0 then h = h + 1 end
    if h > 1 then h = h - 1 end

    return h * 360, s, l
end

local function tuyaHSVtoRGB(h, s, v)
    r,g,b = hsv_to_rgb(h, s/1000, v/1000)
    return round(r*255), round(g*255), round(b*255)
end

local function tuyaRGBtoHSV(r, g, b)
    h,s,v = rgb_to_hsv(r, g, b)
    return round(h), round(s*1000), round(v*1000)
end

local function randfactor()
    function randomFloat(lower, greater)
        return lower + math.random()  * (greater - lower);
    end
    -- just a random float between 99.99xxxxx and 100
    return (randomFloat(99,100))
end

local function pwrRandom(maxpower,position,lastval)
    -- this is ugly hack, as Fibaro in fw 5.80.9 does write energy reports only if power has been changes
    -- while this "might be" not an issue for z-wave devices, for QuickApps with static value we need to randomize a bit 
    -- on the other hand randomizing menas "change each every 10s", which does flood Fibaro logs
    -- so let's randmoize, compare to last value, and write only rounded diff between last and current is higher than 0
    -- random is 99.00 to 100, the way above decrease the probability a bit more to hit the lastval
    local currval = tonumber(string.format("%.4f",maxpower * position * tools.randfactor() / 10000))
    local calsf1 = (currval*100*100) / (maxpower * position)
    local calsf2 = (lastval*100*100) / (maxpower * position)
    local rf = tools.round(math.abs(calsf1-calsf2))
    if rf > 0 then return currval end
    return lastval
end

--------------------------------------------------------------------------------------------------------------------------
--
--------------------------------------------------------------------------------------------------------------------------

tools = {
   _VERSION     = "0.1",
   _DESCRIPTION = "just some tools for HC3/Yubii/HC3L",
   _AUTHOR      = "tinman",
   _URL         = "https://",
   _LICENSE     = "if not separate specified (c) tinman",
   randfactor   = randfactor,
   pwrRandom    = pwrRandom,
   md5          = md5lib_sumhexa,        -- MD5
   hex2bin      = hex2bin,    -- converts hexadecimal representation to binary string
   base642bin   = base642bin, -- converts base64 representation to binary string
   base642hex   = base642hex, -- converts base64 representation to hexadecimal string
   bin2base64   = bin2base64, -- converts binary string to base64 representation
   prettyJson   = prettyJson, -- ordered json encode (c) Jan Gabrielsson
   payloadKeys  = payloadKeys, -- for above
   payloadMax   = payloadMax,  -- for above
   try          = try,
   round        = round,
   tuyaHSVtoRGB = tuyaHSVtoRGB,
   tuyaRGBtoHSV = tuyaRGBtoHSV,
   hsv_to_rgb   = hsv_to_rgb,
   rgb_to_hsv   = rgb_to_hsv,
   rgb_to_hsl   = rgb_to_hsl,
}

--------------------------------------------------------------------------------------------------------------------------
-- LUA Struct
-- actually string.pack, string.unpack and string.packsize are already implemented in LUA 5.3
-- but i prefer to use this one for compatibility with other stuff
--------------------------------------------------------------------------------------------------------------------------

local unpack = table.unpack

local function structPack(format, ...)
  local stream = {}
  local vars = {...}
  local endianness = true

  for i = 1, format:len() do
    local opt = format:sub(i, i)

    if opt == '<' then
      endianness = true
    elseif opt == '>' then
      endianness = false
    elseif opt:find('[bBhHiIlL]') then
      local n = opt:find('[hH]') and 2 or opt:find('[iI]') and 4 or opt:find('[lL]') and 8 or 1
      local val = tonumber(table.remove(vars, 1))

      local bytes = {}
      for j = 1, n do
        table.insert(bytes, string.char(val % (2 ^ 8)))
        val = math.floor(val / (2 ^ 8))
      end
        
      if not endianness then
        table.insert(stream, string.reverse(table.concat(bytes)))
      else
        table.insert(stream, table.concat(bytes))
      end
    elseif opt:find('[fd]') then
      local val = tonumber(table.remove(vars, 1))
      local sign = 0

      if val < 0 then
        sign = 1
        val = -val
      end

      local mantissa, exponent = math.frexp(val)
      if val == 0 then
        mantissa = 0
        exponent = 0
      else
        mantissa = (mantissa * 2 - 1) * math.ldexp(0.5, (opt == 'd') and 53 or 24)
        exponent = exponent + ((opt == 'd') and 1022 or 126)
      end

      local bytes = {}
      if opt == 'd' then
        val = mantissa
        for i = 1, 6 do
          table.insert(bytes, string.char(math.floor(val) % (2 ^ 8)))
          val = math.floor(val / (2 ^ 8))
        end
      else
        table.insert(bytes, string.char(math.floor(mantissa) % (2 ^ 8)))
        val = math.floor(mantissa / (2 ^ 8))
        table.insert(bytes, string.char(math.floor(val) % (2 ^ 8)))
        val = math.floor(val / (2 ^ 8))
      end

      table.insert(bytes, string.char(math.floor(exponent * ((opt == 'd') and 16 or 128) + val) % (2 ^ 8)))
      val = math.floor((exponent * ((opt == 'd') and 16 or 128) + val) / (2 ^ 8))
      table.insert(bytes, string.char(math.floor(sign * 128 + val) % (2 ^ 8)))
      val = math.floor((sign * 128 + val) / (2 ^ 8))

      if not endianness then
        table.insert(stream, string.reverse(table.concat(bytes)))
      else
        table.insert(stream, table.concat(bytes))
      end
    elseif opt == 's' then
      table.insert(stream, tostring(table.remove(vars, 1)))
      table.insert(stream, string.char(0))
    elseif opt == 'c' then
      local n = format:sub(i + 1):match('%d+')
      local str = tostring(table.remove(vars, 1))
      local len = tonumber(n)
      if len <= 0 then
        len = str:len()
      end
      if len - str:len() > 0 then
        str = str .. string.rep(' ', len - str:len())
      end
      table.insert(stream, str:sub(1, len))
      i = i + n:len()
    end
  end

  return table.concat(stream)
end

local function structUnpack(format, stream, pos)
  local vars = {}
  local iterator = pos or 1
  local endianness = true

  for i = 1, format:len() do
    local opt = format:sub(i, i)

    if opt == '<' then
      endianness = true
    elseif opt == '>' then
      endianness = false
    elseif opt:find('[bBhHiIlL]') then
      local n = opt:find('[hH]') and 2 or opt:find('[iI]') and 4 or opt:find('[lL]') and 8 or 1
      local signed = opt:lower() == opt

      local val = 0
      for j = 1, n do
        local byte = string.byte(stream:sub(iterator, iterator))
        if endianness then
          val = val + byte * (2 ^ ((j - 1) * 8))
        else
          val = val + byte * (2 ^ ((n - j) * 8))
        end
        iterator = iterator + 1
      end

      if signed and val >= 2 ^ (n * 8 - 1) then
        val = val - 2 ^ (n * 8)
      end

      table.insert(vars, math.floor(val))
    elseif opt:find('[fd]') then
      local n = (opt == 'd') and 8 or 4
      local x = stream:sub(iterator, iterator + n - 1)
      iterator = iterator + n

      if not endianness then
        x = string.reverse(x)
      end

      local sign = 1
      local mantissa = string.byte(x, (opt == 'd') and 7 or 3) % ((opt == 'd') and 16 or 128)
      for i = n - 2, 1, -1 do
        mantissa = mantissa * (2 ^ 8) + string.byte(x, i)
      end

      if string.byte(x, n) > 127 then
        sign = -1
      end

      local exponent = (string.byte(x, n) % 128) * ((opt == 'd') and 16 or 2) + math.floor(string.byte(x, n - 1) / ((opt == 'd') and 16 or 128))
      if exponent == 0 then
        table.insert(vars, 0.0)
      else
        mantissa = (math.ldexp(mantissa, (opt == 'd') and -52 or -23) + 1) * sign
        table.insert(vars, math.ldexp(mantissa, exponent - ((opt == 'd') and 1023 or 127)))
      end
    elseif opt == 's' then
      local bytes = {}
      for j = iterator, stream:len() do
        if stream:sub(j,j) == string.char(0) or  stream:sub(j) == '' then
          break
        end

        table.insert(bytes, stream:sub(j, j))
      end

      local str = table.concat(bytes)
      iterator = iterator + str:len() + 1
      table.insert(vars, str)
    elseif opt == 'c' then
      local n = format:sub(i + 1):match('%d+')
      local len = tonumber(n)
      if len <= 0 then
        len = table.remove(vars)
      end

      table.insert(vars, stream:sub(iterator, iterator + len - 1))
      iterator = iterator + len
      i = i + n:len()
    end
  end

  return unpack(vars)
end

struct = {
    _URL        = "https://github.com/iryont/lua-struct",
    _LICENSE     = "see URL",
    pack        =  structPack,
    unpack      =  structUnpack,
}

--------------------------------------------------------------------------------------------------------------------------
-- BinaryBuffer inspired by LUVIT
-- position start at 0 ^^
--------------------------------------------------------------------------------------------------------------------------

BinaryBuffer = {
    _URL        = "https://github.com/luvit/luvit/blob/master/deps/buffer.lua",
    _LICENSE    = "see URL",
}

function BinaryBuffer:new()
    self.buffer = {}
    self.__index = self
    return self
end

function BinaryBuffer:alloc(size)
    local buffer = self.buffer
    for index = 1, size do
        buffer[index] = 0x00
    end
    return buffer
end
 
function BinaryBuffer:getData()
    local buflen = #self.buffer
    local option = ''
    for i = 1,buflen do
        option = option .. 'b'
    end
    return struct.pack('<'..option, table.unpack(self.buffer))
end

function BinaryBuffer:getHex()
    local data = self:getData()
    local hextbl = {}
    for d in data:gmatch(".") do
        table.insert(hextbl, string.format("%02x", d:byte()))
    end
    return table.concat(hextbl, "")
end

function BinaryBuffer:slice(start,stop)
    local data = self:getData()
    return data:sub(start,stop)
end

function BinaryBuffer:putData(buffer,position)
    local data = buffer
    if position == nil or position < 0 then position = 0 end -- no shift 
    for d in data:gmatch(".") do
        self:writeUInt8(d:byte(),position)
        position = position + 1
    end
end

local function complement8(value)
  return value < 0x80 and value or value - 0x100
end

function BinaryBuffer:readUInt8(offset)
  offset = offset + 1
  return self.buffer[offset]
end

function BinaryBuffer:readInt8(offset)
  offset = offset + 1
  return complement8(self.buffer[offset])
end

local function complement16(value)
  return value < 0x8000 and value or value - 0x10000
end

function BinaryBuffer:readUInt16LE(offset)
  offset = offset + 1
  return bit32.lshift(self.buffer[offset + 1], 8) +
                      self.buffer[offset]
end

function BinaryBuffer:readUInt16BE(offset)
  offset = offset + 1
  return bit32.lshift(self.buffer[offset], 8) +
                      self.buffer[offset + 1]
end

function BinaryBuffer:readInt16LE(offset)
  return complement16(self:readUInt16LE(offset))
end

function BinaryBuffer:readInt16BE(offset)
  return complement16(self:readUInt16BE(offset))
end

function BinaryBuffer:readUInt32LE(offset)
  offset = offset + 1
  return self.buffer[offset + 3] * 0x1000000 +
         bit32.lshift(self.buffer[offset + 2], 16) +
         bit32.lshift(self.buffer[offset + 1], 8) +
                      self.buffer[offset]
end
 
function BinaryBuffer:readUInt32BE(offset)
  offset = offset + 1
  return self.buffer[offset] * 0x1000000 +
          bit32.lshift(self.buffer[offset + 1], 16) +
          bit32.lshift(self.buffer[offset + 2], 8) +
                       self.buffer[offset + 3]
end
 
function BinaryBuffer:readInt32LE(offset)
  return bit32.tobit(self:readUInt32LE(offset))
end

function BinaryBuffer:readInt32BE(offset)
  return bit32.tobit(self:readUInt32BE(offset))
end

function BinaryBuffer:writeUInt8(value, offset)
  offset = offset + 1
  self.buffer[offset] = value
end

function BinaryBuffer:writeInt8(value, offset)
  return self:writeUInt8(value, offset)
end

function BinaryBuffer:writeUInt16LE(value, offset)
  offset = offset + 1
  self.buffer[offset] = bit32.rshift(value, 0)
  self.buffer[offset + 1] = bit32.rshift(value, 8)
end

function BinaryBuffer:writeUInt16BE(value, offset)
  offset = offset + 1
  self.buffer[offset] = bit32.rshift(value, 8)
  self.buffer[offset + 1] = bit32.rshift(value, 0)
end

function BinaryBuffer:writeInt16LE(value, offset)
  offset = offset + 1
  self.buffer[offset] = bit32.rshift(value, 0)
  self.buffer[offset + 1] = bit32.rshift(value, 8)
end

-- 32bit operation on HC3L / Yubii are not supported with bit32 LUA, so let's use string.unpack
function BinaryBuffer:writeUInt32LE(value, offset)
  offset = offset + 1
  local a,b,c,d = string.unpack("bbbb", string.pack("j", value))
  self.buffer[offset] = a & 0x000000FF
  self.buffer[offset + 1] = b & 0x000000FF
  self.buffer[offset + 2] = c & 0x000000FF
  self.buffer[offset + 3] = d & 0x000000FF
end

function BinaryBuffer:writeUInt32BE(value, offset)
  offset = offset + 1
  local a,b,c,d = string.unpack("bbbb", string.pack("j", value))
  self.buffer[offset] = d & 0x000000FF
  self.buffer[offset + 1] = c & 0x000000FF
  self.buffer[offset + 2] = b & 0x000000FF
  self.buffer[offset + 3] = a & 0x000000FF
end

function BinaryBuffer:writeInt32LE(value, offset)
  offset = offset + 1
  local a,b,c,d = string.unpack("bbbb", string.pack("j", value))
  self.buffer[offset] = a & 0x000000FF
  self.buffer[offset + 1] = b & 0x000000FF
  self.buffer[offset + 2] = c & 0x000000FF
  self.buffer[offset + 3] = d & 0x000000FF
end

function BinaryBuffer:writeInt32BE(value, offset)
  offset = offset + 1
  local a,b,c,d = string.unpack("bbbb", string.pack("j", value))
  self.buffer[offset] = d & 0x000000FF
  self.buffer[offset + 1] = c & 0x000000FF
  self.buffer[offset + 2] = b & 0x000000FF
  self.buffer[offset + 3] = a & 0x000000FF
end
