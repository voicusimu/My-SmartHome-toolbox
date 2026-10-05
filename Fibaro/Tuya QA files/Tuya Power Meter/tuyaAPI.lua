--------------------------------------------------------------------------------------------------------------------------
-- tuyAPI port lib v0.1 (c) tinman
-- a very basic version for now, tested with Ver 3.3 devices
--------------------------------------------------------------------------------------------------------------------------
local CommandType = {
  UDP = 0,
  AP_CONFIG = 1,
  ACTIVE = 2,
  BIND = 3,
  RENAME_GW = 4,
  RENAME_DEVICE = 5,
  UNBIND = 6,
  CONTROL = 7,
  STATUS = 8,
  HEART_BEAT = 9,
  DP_QUERY = 10,
  QUERY_WIFI = 11,
  TOKEN_BIND = 12,
  CONTROL_NEW = 13,
  ENABLE_WIFI = 14,
  DP_QUERY_NEW = 16,
  SCENE_EXECUTE = 17,
  DP_REFRESH = 18,
  UDP_NEW = 19,
  AP_CONFIG_NEW = 20,
  LAN_GW_ACTIVE = 240,
  LAN_SUB_DEV_REQUEST = 241,
  LAN_DELETE_SUB_DEV = 242,
  LAN_REPORT_SUB_DEV = 243,
  LAN_SCENE = 244,
  LAN_PUBLISH_CLOUD_CONFIG = 245,
  LAN_PUBLISH_APP_CONFIG = 246,
  LAN_EXPORT_APP_CONFIG = 247,
  LAN_PUBLISH_SCENE_PANEL = 248,
  LAN_REMOVE_GW = 249,
  LAN_CHECK_GW_UPDATE = 250,
  LAN_GW_UPDATE = 251,
  LAN_SET_GW_CHANNEL = 252
}

local HEADER_SIZE = 16

local function has_value(tab, val)
    for index, value in pairs(tab) do
        if value == val then
            return true
        end
    end
    return false
end

local function encrypt(data,base64,key,version)
    local keystring = padding.padPKCS7(key,16,true)
    local paddedkey = {string.byte(keystring,1,#keystring)}
    local paddedData = padding.padPKCS7(data)
    local cipher = aeslib.encryptString(paddedkey, paddedData, ciphermode.encryptECB)
    local encrypted = nil
    if (base64 == false) then 
        encrypted = cipher
    elseif (base64 == true) then
         encrypted = tools.bin2base64(cipher)
    else
         encrypted = tools.bin2base64(cipher)
    end
    return encrypted
end

local function decrypt(data,base64,key,version)
    local buffer
    if version ~= nil and version == "3.3" then
        tmpbuffer = string.sub(data,15+1)
    elseif version ~= nil and version == "3.1" then
        tmpbuffer = string.sub(data,19+1)
        base64 = true
    else 
        tmpbuffer = data
    end
    local encrypted
    if (base64 == false) then 
        encrypted = tmpbuffer
    elseif (base64 == true) then
         encrypted = tools.base642bin(tmpbuffer)
    else
         encrypted = tools.base642bin(tmpbuffer)
    end
    local keystring = padding.padPKCS7(key,16,true)
    local paddedkey = {string.byte(keystring,1,#keystring)}
    local retdata = aeslib.decryptString(paddedkey, encrypted, ciphermode.decryptECB)
    retdata = padding.unpadPKCS7(retdata)
    local success, res = pcall(json.decode, retdata)
    if success then
        return res
    else
        return retdata
    end
end

local function md5(data)
    local md5hash = tools.md5(data)
    return string.sub(md5hash, 8+1, 24)
end

local function parse(buffer,key,version)
    local payloaddata, leftover, commandByte, sequenceN = tuyAPI.parsePacket(buffer)
    payload = tuyAPI.getPayload(payloaddata,key,version)
    return payload, commandByte, sequenceN
end

local function parsePacket(buffer)
    -- Check for length: At minimum requires: prefix (4), sequence (4), command (4), length (4), CRC (4), and suffix (4) for 24 total bytes
    -- Messages from the device also include return code (4), for 28 total bytes
    local count = string.len(tostring(buffer))
    if count < 24 then return string.format("Packet too short. Length: %s",count) end

    payload = BinaryBuffer:new()
    payload.buffer = payload:alloc(count)
    payload:putData(buffer)
 
    local prefix = payload:readUInt32BE(0)
    if prefix ~= 0x000055AA then return "error prefix "..string.pack(">I",prefix) end

    local leftover = false
    local suffixLocation = string.find(payload:getData(),string.pack(">I",0x0000AA55),0,true) - 1
    if ((suffixLocation) ~= (count - 4)) then
        leftover = payload:slice(suffixLocation + 4)
        local xbuffer = payload:slice(0, suffixLocation + 4)
        payload.buffer = {}
        payload:putData(xbuffer)
    end

    -- sometimes when accessing data very fast, wrong buffer size is assigned
    -- let's try to calculate size once again and catch the error
    -- local suffix = payload:readUInt32BE(count - 4)
    -- if suffix ~= 0x0000AA55 then return "error suffix "..string.pack(">I",suffix) end
    tools.try(function()
        local countbroken = string.len(tostring(payload:getData()))
        local suffix = payload:readUInt32BE(countbroken - 4)
        if suffix ~= 0x0000AA55 then return "error suffix "..string.pack(">I",suffix) end
    end, function(e)
        -- 
    end)

    -- Get sequence number
    local sequenceN = payload:readUInt32BE(4);

    -- Get command byte
    local commandByte = payload:readUInt32BE(8);

    -- Get payload size
    local payloadSize = payload:readUInt32BE(12);
    if string.len(tostring(payload:getData())) - 8 < payloadSize then return "Packet missing payload: payload has length ".. payloadSize end

    -- Get the return code, 0 = success
    -- This field is only present in messages from the devices, absent in messages sent to device
    local returnCode = payload:readUInt32BE(16);
 
    -- Get the payload data, adjust per command type:
    --   STATUS (8)       : has return code (4 bytes) + version prefix → offset = 1
    --   DP_QUERY (10)    : no return code, version prefix stripped differently → offset = -14
    --   CONTROL_NEW (13) : no return code + version prefix → offset = -3
    --   DP_REFRESH (18)  : same as DP_QUERY → offset = -14
    local offset = 1
    if commandByte == 10 or commandByte == 18 then offset = -15 + 1 end
    if commandByte == 13 then offset = -3 end  -- CONTROL_NEW: no return code, has 3.3 version prefix
    local payloaddata = {}
    payloaddata = payload:slice(HEADER_SIZE + 4 + offset, HEADER_SIZE + payloadSize - 8)

    -- Adjust for messages lacking a return code
    --  if (returnCode & 0xFFFFFF00) then
    --      payloaddata = payload:slice(HEADER_SIZE + offset, HEADER_SIZE + payloadSize - 8)
    --  else 
    --      payloaddata = payload:slice(HEADER_SIZE + 4, HEADER_SIZE + payloadSize - 8)
    --  end
  
    -- Check CRC
    local expectedCrc = payload:readUInt32BE(HEADER_SIZE + payloadSize - 8)
    local computedCrc = tuyAPI.crc32(payload:slice(0, payloadSize + 8))
    if (expectedCrc ~= computedCrc) then
        return string.format("CRC mismatch: expected %s, was %s",expectedCrc,computedCrc)
    end

    return payloaddata, leftover, commandByte, sequenceN
end

local function getPayload(data,key,version)
    if string.len(tostring(data)) == 0 then return false end
    tools.try(function()
        data = tuyAPI.decrypt(data, false, key, version)
    end, function(e)
        data = tostring(data)
    end)
    return data
end 

local function encode(options)
    local buffer = nil
    -- Check command byte
    if not has_value(CommandType,options.commandByte) then
        return nil --"Command byte not defined"
    end
    if not type(options.data) == "string" then 
        payload = tostring(options.data)
    else
        payload = options.data
    end
    -- Protocol 3.3 is always encrypted
    if options.version == "3.3" then
        payload = encrypt(payload,false,options.key,"3.3")
        if (options.commandByte ~= CommandType.DP_QUERY and options.commandByte ~= CommandType.DP_REFRESH) then
            local payload33tmp = BinaryBuffer:new()
            payload33tmp.buffer = payload33tmp:alloc(string.len(tostring(payload)) + 15)
            payload33tmp.buffer[1] = string.byte("3")
            payload33tmp.buffer[2] = string.byte(".")
            payload33tmp.buffer[3] = string.byte("3")
            payload33tmp:putData(payload, 15)
            payload = payload33tmp:getData()
        end
    elseif options.encrypted then
        payload = encrypt(payload,true,options.key,"3.1")
        -- Create MD5 signature
        local payloadmd5 = md5('data=' .. payload .. 
          '||lpv=' .. options.version ..
          '||' .. options.key);
        -- Create byte buffer from hex data
        payload31tmp = BinaryBuffer:new()
        local ptmp = '3.1' .. tostring(payloadmd5) .. payload
        payload31tmp.buffer = payload31tmp:alloc(#ptmp)
        payload31tmp:putData(ptmp, 0)
        payload = payload31tmp:getData()
    end

    -- Allocate buffer with room for payload + 24 bytes for
    -- prefix, sequence, command, length, crc, and suffix
    local encbuffer = BinaryBuffer:new()
    encbuffer.buffer = encbuffer:alloc(string.len(tostring(payload)) + 24)
    -- Add prefix, command, and length
    encbuffer:writeUInt32BE(0x000055AA, 0)
    encbuffer:writeUInt32BE(options.commandByte, 8)
    encbuffer:writeUInt32BE(string.len(tostring(payload)) + 8, 12)

    if options.sequenceN then
        encbuffer:writeUInt32BE(options.sequenceN, 4)
    end

    -- Add payload, crc, and suffix
    encbuffer:putData(payload, 16)
    local calculatedCrc = tuyAPI.crc32(encbuffer:slice(1, string.len(tostring(payload)) + 16)) & 0xFFFFFFFF
    encbuffer:writeUInt32BE(calculatedCrc, string.len(tostring(payload)) + 16)
    encbuffer:writeUInt32BE(0x0000AA55, string.len(tostring(payload)) + 20)
    buffer = encbuffer:getData()
    return buffer
end

--------------------------------------------------------------------------------------------------------------------------
-- UDP key
--------------------------------------------------------------------------------------------------------------------------

local function genUDPkey()
    local UDP_KEY_STRING = 'yGAdlopoPVldABfn'
    local UDP_KEY = tools.md5(UDP_KEY_STRING)
    return UDP_KEY
end

--------------------------------------------------------------------------------------------------------------------------
-- tuya crc32
-- Reverse engineered by kueblc
--------------------------------------------------------------------------------------------------------------------------

local function crc32(bytes)
    local crc32Table = {
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA,
    0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
    0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988,
    0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
    0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE,
    0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
    0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC,
    0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
    0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172,
    0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
    0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940,
    0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
    0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116,
    0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
    0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924,
    0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
    0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A,
    0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
    0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818,
    0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
    0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E,
    0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
    0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C,
    0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
    0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2,
    0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
    0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0,
    0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
    0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086,
    0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
    0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4,
    0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
    0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A,
    0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
    0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8,
    0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
    0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE,
    0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
    0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC,
    0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
    0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252,
    0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
    0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60,
    0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
    0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236,
    0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
    0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04,
    0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
    0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A,
    0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
    0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38,
    0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
    0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E,
    0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
    0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C,
    0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
    0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2,
    0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
    0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0,
    0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
    0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6,
    0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
    0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94,
    0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D
    }
    
    local count = string.len(tostring(bytes))
    local crc = 0xFFFFFFFF
    local i = 1
    while count > 0 do
        local byte = string.byte(bytes, i)
        crc = (crc >> 8) ~ crc32Table[((crc ~ byte) & 0xFF)+1];
        i = i + 1
        count = count - 1
    end
    crc = crc ~ 0xFFFFFFFF
    -- dirty hack for bitop return number < 0 on HC3L / Yubii
    if crc < 0 then 
        crcx = string.unpack("j", string.pack("J", crc))
        return crcx
    end
    return crc
end

--------------------------------------------------------------------------------------------------------------------------
-- Protocol 3.5  (prefix 0x00006699 / suffix 0x00009966, AES-128-GCM, no CRC)
-- Requires: gcmlib.lua, sha256lib.lua
--------------------------------------------------------------------------------------------------------------------------

local PREFIX_6699 = string.pack(">I4", 0x00006699)
local SUFFIX_9966 = string.pack(">I4", 0x00009966)
local HEADER_SIZE_35 = 18  -- 4 prefix + 2 unknown + 4 seqno + 4 cmd + 4 length

-- Build a v3.5 GCM-encrypted packet.
-- options: { data (binary string), key (16-byte binary), commandByte (int), sequenceN (int) }
-- Returns: complete binary packet string
local function encode35(options)
    local iv       = gcmlib.gen_iv()           -- 12-byte unique IV
    local plaintext = options.data or ""
    local cmd      = options.commandByte
    local seqno    = options.sequenceN or 0
    -- msg_len = IV(12) + ciphertext(#plaintext) + GCM-tag(16)  [suffix is NOT counted]
    local msg_len  = 12 + #plaintext + 16
    -- 18-byte header:  prefix(4) + unknown(2) + seqno(4) + cmd(4) + length(4)
    local header   = PREFIX_6699 .. string.pack(">HI4I4I4", 0, seqno, cmd, msg_len)
    -- AAD = header bytes 5-18 (the 14 bytes that follow the 4-byte prefix)
    local aad      = string.sub(header, 5)
    -- GCM-encrypt; returns ciphertext || 16-byte auth tag
    local encrypted = gcmlib.encrypt(options.key, iv, plaintext, aad)
    return header .. iv .. encrypted .. SUFFIX_9966
end

-- Parse a v3.5 packet from buffer.
-- Returns: ciphertext_with_tag, aad, iv, cmd, seqno, err
-- On error: nil, nil, nil, nil, nil, "description"
local function parsePacket35(buffer)
    if #buffer < HEADER_SIZE_35 + 12 + 16 + 4 then
        return nil, nil, nil, nil, nil, "v3.5 packet too short (" .. #buffer .. " bytes)"
    end
    local prefix = string.unpack(">I4", buffer, 1)
    if prefix ~= 0x00006699 then
        return nil, nil, nil, nil, nil,
            string.format("Not a v3.5 packet (prefix 0x%08X)", prefix)
    end
    -- header bytes 5-18: unknown(2) + seqno(4) + cmd(4) + length(4)
    local _unknown, seqno, cmd, length = string.unpack(">HI4I4I4", buffer, 5)
    local aad = string.sub(buffer, 5, 18)        -- 14 bytes for AAD
    local iv  = string.sub(buffer, 19, 30)       -- 12 bytes
    -- ciphertext+tag length = length - 12(IV)   [suffix is NOT in length field]
    local ct_len = length - 12
    if ct_len < 16 then
        return nil, nil, nil, nil, nil,
            "v3.5 ciphertext+tag too short (" .. ct_len .. " bytes)"
    end
    local ciphertext_with_tag = string.sub(buffer, 31, 30 + ct_len)
    return ciphertext_with_tag, aad, iv, cmd, seqno, nil
end

-- Decrypt a v3.5 ciphertext+tag blob.
-- Returns: plaintext (binary string), nil
--      or  nil, "error description"
local function getPayload35(ciphertext_with_tag, aad, iv, key)
    local plaintext = gcmlib.decrypt(key, iv, ciphertext_with_tag, aad)
    if plaintext == nil then
        return nil, "GCM authentication failed (wrong key or tampered packet)"
    end
    return plaintext, nil
end

--------------------------------------------------------------------------------------------------------------------------
--
--------------------------------------------------------------------------------------------------------------------------

tuyAPI = {
   _VERSION     = "0.1",
   _DESCRIPTION = "LUA port for tuyAPI",
   _AUTHOR      = "tinman",
   _URL         = "https://github.com/codetheweb/tuyapi",
   _LICENSE     = "MIT (the same license as Lua itself)",
   UDP_KEY          = genUDPkey(),
   md5              = md5,        -- MD5
   crc32            = crc32,      -- tuya CRC32
   encrypt          = encrypt,    -- encrypt
   decrypt          = decrypt,    -- encrypt
   parse            = parse,
   parseRecursive   = parseRecursive,
   parsePacket      = parsePacket,
   getPayload       = getPayload,
   tuyaEncode       = encode,
   tuyaDecode       = decode,
   tuyaCommandType  = CommandType,
   -- v3.5 GCM functions
   encode35         = encode35,
   parsePacket35    = parsePacket35,
   getPayload35     = getPayload35,
}
