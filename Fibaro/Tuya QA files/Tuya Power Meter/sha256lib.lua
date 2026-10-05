-- sha256lib.lua: Pure Lua 5.3 SHA-256 and HMAC-SHA256
-- Exposes: sha256lib.sha256(data)  → 32-byte binary string
--          sha256lib.hmac(key, msg) → 32-byte binary string

sha256lib = {}

do
    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    local function u32(n)  return n & 0xFFFFFFFF end
    local function rr(n,b) return u32((n >> b) | (n << (32 - b))) end
    local function bsr(n,b) return u32(n >> b) end

    local function ch(x,y,z)  return (x & y) ~ (~x & z) end
    local function maj(x,y,z) return (x & y) ~ (x & z) ~ (y & z) end
    local function Sig0(x) return rr(x,2)  ~ rr(x,13) ~ rr(x,22) end
    local function Sig1(x) return rr(x,6)  ~ rr(x,11) ~ rr(x,25) end
    local function sig0(x) return rr(x,7)  ~ rr(x,18) ~ bsr(x,3)  end
    local function sig1(x) return rr(x,17) ~ rr(x,19) ~ bsr(x,10) end

    local function processChunk(W, H, chunk)
        -- prepare message schedule
        for i = 1,16 do
            W[i] = string.unpack(">I4", chunk, (i-1)*4 + 1)
        end
        for i = 17,64 do
            W[i] = u32(sig1(W[i-2]) + W[i-7] + sig0(W[i-15]) + W[i-16])
        end
        -- working vars
        local a,b,c,d,e,f,g,h =
            H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
        for i = 1,64 do
            local t1 = u32(h + Sig1(e) + ch(e,f,g) + K[i] + W[i])
            local t2 = u32(Sig0(a) + maj(a,b,c))
            h = g; g = f; f = e; e = u32(d + t1)
            d = c; c = b; b = a; a = u32(t1 + t2)
        end
        H[1] = u32(H[1]+a); H[2] = u32(H[2]+b)
        H[3] = u32(H[3]+c); H[4] = u32(H[4]+d)
        H[5] = u32(H[5]+e); H[6] = u32(H[6]+f)
        H[7] = u32(H[7]+g); H[8] = u32(H[8]+h)
    end

    function sha256lib.sha256(data)
        -- initial hash values
        local H = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        }
        local W = {}
        local bitlen = #data * 8
        -- padding: append 0x80, zeros, then 64-bit big-endian length
        data = data .. "\x80"
        while (#data % 64) ~= 56 do data = data .. "\x00" end
        -- length as 64-bit big-endian (we only support up to 2^32 bits)
        data = data .. string.pack(">I4I4", 0, bitlen)

        for i = 1, #data, 64 do
            processChunk(W, H, string.sub(data, i, i+63))
        end

        return string.pack(">I4I4I4I4I4I4I4I4",
            H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8])
    end

    function sha256lib.hmac(key, msg)
        local BLOCK = 64
        -- if key longer than block, hash it
        if #key > BLOCK then key = sha256lib.sha256(key) end
        -- pad to block size
        key = key .. string.rep("\x00", BLOCK - #key)
        -- inner and outer pads
        local ipad, opad = {}, {}
        for i = 1, BLOCK do
            local b = string.byte(key, i)
            ipad[i] = string.char(b ~ 0x36)
            opad[i] = string.char(b ~ 0x5C)
        end
        local ipad_str = table.concat(ipad)
        local opad_str = table.concat(opad)
        return sha256lib.sha256(opad_str .. sha256lib.sha256(ipad_str .. msg))
    end
end
