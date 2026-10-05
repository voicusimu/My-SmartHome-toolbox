-- gcmlib.lua: AES-128-GCM for Fibaro HC3 QuickApps
-- Uses aeslib (ECB mode) for raw AES block operations.
-- No external dependencies beyond aeslib.lua.
--
-- Public API:
--   gcmlib.encrypt(key, iv12, plaintext, aad) → ciphertext_with_tag (len = #plaintext + 16)
--   gcmlib.decrypt(key, iv12, ciphertext_with_tag, aad) → plaintext  or  nil on auth failure
--   gcmlib.gen_iv()        → 12-byte IV (unique per call)
--   gcmlib.random_bytes(n) → n pseudo-random bytes

gcmlib = {}

do
    -- ── Raw AES block encrypt (ECB, single 16-byte block) ─────────────────────
    local function aes_block(key16, block16)
        -- key16 and block16 are binary strings, each exactly 16 bytes
        local kt = { string.byte(key16, 1, 16) }
        -- ECB on a single 16-byte block (no padding needed — already aligned)
        return aeslib.encryptString(kt, block16, ciphermode.encryptECB)
    end

    -- ── GF(2^128) multiplication ───────────────────────────────────────────────
    -- GCM GHASH multiplication: Z = X * Y in GF(2^128) with reduction poly E1…00

    -- Convert 16-byte string → two 64-bit integers (hi, lo) as Lua integers
    local function str_to_hiLo(s)
        local hi = string.unpack(">I8", s, 1)
        local lo = string.unpack(">I8", s, 9)
        return hi, lo
    end

    local function hiLo_to_str(hi, lo)
        return string.pack(">I8I8", hi, lo)
    end

    -- GF(2^128) multiply X by Y; both are 16-byte binary strings; returns 16-byte result.
    local function gf128_mul(X, Y)
        -- X, Y: 16-byte binary strings
        local Xhi, Xlo = str_to_hiLo(X)
        local Vhi, Vlo = str_to_hiLo(Y)
        local Zhi, Zlo = 0, 0

        for i = 0, 127 do
            -- bit i of X (MSB = bit 0)
            local xbit
            if i < 64 then
                xbit = (Xhi >> (63 - i)) & 1
            else
                xbit = (Xlo >> (127 - i)) & 1
            end

            -- Z ^= V if x_bit = 1
            if xbit == 1 then
                Zhi = Zhi ~ Vhi
                Zlo = Zlo ~ Vlo
            end

            -- save LSB of Vlo before shift
            local lsb = Vlo & 1

            -- right-shift V (128-bit) by 1
            Vlo = (Vlo >> 1) | ((Vhi & 1) << 63)
            Vhi = Vhi >> 1

            -- if original LSB was 1, XOR V with R = E1 00…00
            if lsb == 1 then
                Vhi = Vhi ~ (0xE1 << 56)
            end
        end
        return hiLo_to_str(Zhi, Zlo)
    end

    -- ── GHASH ─────────────────────────────────────────────────────────────────
    -- H: 16-byte hash subkey (AES_K(0^16))
    -- data: arbitrary-length binary string (already padded to 16-byte multiple by caller)
    local function ghash_update(H, Y, data)
        for i = 1, #data, 16 do
            local block = string.sub(data, i, i + 15)
            -- XOR Y with block
            local Yhi, Ylo = str_to_hiLo(Y)
            local Bhi, Blo = str_to_hiLo(block)
            Y = hiLo_to_str(Yhi ~ Bhi, Ylo ~ Blo)
            Y = gf128_mul(Y, H)
        end
        return Y
    end

    local function pad16(s)
        local rem = #s % 16
        if rem == 0 then return s end
        return s .. string.rep("\x00", 16 - rem)
    end

    -- GHASH(H, A, C):  process AAD then ciphertext then length block
    local function ghash(H, aad, cipher)
        local Y = string.rep("\x00", 16)
        if #aad > 0 then
            Y = ghash_update(H, Y, pad16(aad))
        end
        if #cipher > 0 then
            Y = ghash_update(H, Y, pad16(cipher))
        end
        -- length block: len(A) || len(C) as two 64-bit big-endian values (in bits)
        local lenA = #aad   * 8
        local lenC = #cipher * 8
        local lenblock = string.pack(">I8I8", lenA, lenC)
        Y = ghash_update(H, Y, lenblock)
        return Y
    end

    -- ── inc32 ──────────────────────────────────────────────────────────────────
    -- Increment the rightmost 32 bits of a 16-byte counter block
    local function inc32(block)
        local ctr = string.unpack(">I4", block, 13)
        ctr = (ctr + 1) & 0xFFFFFFFF
        return string.sub(block, 1, 12) .. string.pack(">I4", ctr)
    end

    -- ── CTR encrypt ────────────────────────────────────────────────────────────
    -- Starting counter block ICB (J0 for tag, inc32(J0) for first plaintext block)
    local function gctr(key, icb, data)
        if #data == 0 then return "" end
        local out = {}
        local cb = icb
        local n = math.ceil(#data / 16)
        for i = 1, n do
            local block = string.sub(data, (i-1)*16 + 1, i*16)
            local ks = aes_block(key, cb)
            -- XOR
            local res = {}
            for j = 1, #block do
                res[j] = string.char(string.byte(block, j) ~ string.byte(ks, j))
            end
            out[i] = table.concat(res)
            cb = inc32(cb)
        end
        return table.concat(out)
    end

    -- ── IV counter ─────────────────────────────────────────────────────────────
    local _iv_counter = 0

    -- ── Public API ─────────────────────────────────────────────────────────────

    -- Encrypt: returns ciphertext || 16-byte tag
    function gcmlib.encrypt(key, iv12, plaintext, aad)
        aad = aad or ""
        -- H = AES_K(0^16)
        local H = aes_block(key, string.rep("\x00", 16))
        -- J0 = IV || 0x00000001
        local J0 = iv12 .. string.pack(">I4", 1)
        -- Encrypt plaintext with CTR starting at inc32(J0)
        local ciphertext = gctr(key, inc32(J0), plaintext)
        -- Compute tag: S = GHASH(H, A, C); T = GCTR(K, J0, S)
        local S = ghash(H, aad, ciphertext)
        local T = gctr(key, J0, S)
        return ciphertext .. T
    end

    -- Decrypt: returns plaintext, or nil if tag check fails
    function gcmlib.decrypt(key, iv12, ciphertext_with_tag, aad)
        aad = aad or ""
        if #ciphertext_with_tag < 16 then return nil end
        local ciphertext = string.sub(ciphertext_with_tag, 1, #ciphertext_with_tag - 16)
        local tag_recv   = string.sub(ciphertext_with_tag, #ciphertext_with_tag - 15)
        -- H = AES_K(0^16)
        local H = aes_block(key, string.rep("\x00", 16))
        -- J0 = IV || 0x00000001
        local J0 = iv12 .. string.pack(">I4", 1)
        -- Verify tag
        local S = ghash(H, aad, ciphertext)
        local T = gctr(key, J0, S)
        -- Constant-time compare
        local ok = true
        for i = 1, 16 do
            if string.byte(T, i) ~= string.byte(tag_recv, i) then
                ok = false
            end
        end
        if not ok then return nil end
        -- Decrypt
        return gctr(key, inc32(J0), ciphertext)
    end

    -- Generate a unique 12-byte IV
    function gcmlib.gen_iv()
        _iv_counter = _iv_counter + 1
        -- Use os.time (seconds) in upper 4 bytes, counter in next 4, zero in last 4
        return string.pack(">I4I4I4", os.time() & 0xFFFFFFFF, _iv_counter & 0xFFFFFFFF, 0)
    end

    -- Generate n pseudo-random bytes (simple PRNG, not cryptographically secure;
    -- used only for the 16-byte local nonce in session negotiation)
    function gcmlib.random_bytes(n)
        local out = {}
        local seed = os.time() + _iv_counter * 0x10001
        for i = 1, n do
            -- LCG step
            seed = (seed * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
            out[i] = string.char((seed >> 32) & 0xFF)
        end
        return table.concat(out)
    end
end
