    -- shortcuts for easier to read formulas
    PI = math.pi
    sin = math.sin
    cos = math.cos
    tan = math.tan
    asin = math.asin
    atan = math.atan2
    acos = math.acos
    rad = PI / 180
    -- sun calculations are based on http://aa.quae.nl/en/reken/zonpositie.html formulas
    -- date/time constants and conversions
    dayMs = 1000 * 60 * 60 * 24
    J1970 = 2440588
    J2000 = 2451545

    function toJulian(date)
        return date / dayMs - 0.5 + J1970
    end
    function fromJulian(j)
        return (j + 0.5 - J1970) * dayMs
    end
    function toDays(date)
        return toJulian(date) - J2000
    end
    -- general calculations for position
    e = rad * 23.4397 -- obliquity of the Earth
    function rightAscension(l, b)
        return atan(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
    end
    function declination(l, b)
        return asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
    end
    function azimuth(H, phi, dec)
        return atan(sin(H), cos(H) * sin(phi) - tan(dec) * cos(phi))
    end
    function altitude(H, phi, dec)
        return asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(H))
    end
    function siderealTime(d, lw)
        return rad * (280.16 + 360.9856235 * d) - lw
    end
    function astroRefraction(h)
        if (h < 0) then -- the following formula works for positive altitudes only.
            h = 0 -- if h = -0.08901179 a div/0 would occur.
        end
        -- formula 16.4 of "Astronomical Algorithms" 2nd edition by Jean Meeus (Willmann-Bell, Richmond) 1998.
        -- 1.02 / tan(h + 10.26 / (h + 5.10)) h in degrees, result in arc minutes -> converted to rad:
        return 0.0002967 / math.tan(h + 0.00312536 / (h + 0.08901179))
    end
    -- general sun calculations
    function solarMeanAnomaly(d)
        return rad * (357.5291 + 0.98560028 * d)
    end
    function eclipticLongitude(M)
        local C = rad * (1.9148 * sin(M) + 0.02 * sin(2 * M) + 0.0003 * sin(3 * M)) -- equation of center
        local P = rad * 102.9372 -- perihelion of the Earth

        return M + C + P + PI
    end
    function sunCoords(d)
        M = solarMeanAnomaly(d)
        L = eclipticLongitude(M)
        return {
            dec = declination(L, 0),
            ra = rightAscension(L, 0)
        }
    end

    SunCalc = {}
    -- calculates sun position for a given date and latitude/longitude
    SunCalc.getPosition = function(date, lat, lng)
        lw = rad * -lng
        phi = rad * lat
        d = toDays(date)
        c = sunCoords(d)
        H = siderealTime(d, lw) - c.ra

        return {
            azimuth = azimuth(H, phi, c.dec),
            altitude = altitude(H, phi, c.dec)
        }
    end
    -- sun times configuration (angle, morning name, evening name)
    times = {
        {-0.833, "sunrise", "sunset"},
        {-0.3, "sunriseEnd", "sunsetStart"},
        {-6, "dawn", "dusk"},
        {-12, "nauticalDawn", "nauticalDusk"},
        {-18, "nightEnd", "night"},
        {6, "goldenHourEnd", "goldenHour"},
        {-4, "blueHourDawnEnd", "blueHourDusk"},
        {-8, "blueHourDawn", "blueHourDuskEnd"}
    }
    -- adds a custom time to the times config
    SunCalc.addTime = function(angle, riseName, setName)
        table.insert(times, {angle, riseName, setName})
    end
    -- calculations for sun times
    J0 = 0.0009
    function julianCycle(d, lw)
        return math.round(d - J0 - lw / (2 * PI))
    end
    function approxTransit(Ht, lw, n)
        return J0 + (Ht + lw) / (2 * PI) + n
    end
    function solarTransitJ(ds, M, L)
        return J2000 + ds + 0.0053 * sin(M) - 0.0069 * sin(2 * L)
    end
    function hourAngle(h, phi, d)
        return acos((sin(h) - sin(phi) * sin(d)) / (cos(phi) * cos(d)))
    end
    -- returns set time for the given sun altitude
    function getSetJ(h, lw, phi, dec, n, M, L)
        w = hourAngle(h, phi, dec)
        a = approxTransit(w, lw, n)
        return solarTransitJ(a, M, L)
    end
    -- calculates sun times for a given date and latitude/longitude
    SunCalc.getTimes = function(date, lat, lng)
        lw = rad * -lng
        phi = rad * lat

        d = toDays(date)
        n = julianCycle(d, lw)
        ds = approxTransit(0, lw, n)

        M = solarMeanAnomaly(ds)
        L = eclipticLongitude(M)
        dec = declination(L, 0)

        Jnoon = solarTransitJ(ds, M, L)

        i, len, time, Jset, Jrise = nil

        result = {
            solarNoon = fromJulian(Jnoon),
            nadir = fromJulian(Jnoon - 0.5)
        }

        for i = 1, table.length(times) do
            time = times[i]

            Jset = getSetJ(time[1] * rad, lw, phi, dec, n, M, L)
            Jrise = Jnoon - (Jset - Jnoon)

            result[time[2]] = fromJulian(Jrise)
            result[time[3]] = fromJulian(Jset)
        end

        return result
    end
    -- moon calculations, based on http://aa.quae.nl/en/reken/hemelpositie.html formulas
    function moonCoords(d) -- geocentric ecliptic coordinates of the moon
        L = rad * (218.316 + 13.176396 * d) -- ecliptic longitude
        M = rad * (134.963 + 13.064993 * d) -- mean anomaly
        F = rad * (93.272 + 13.229350 * d) -- mean distance

        l = L + rad * 6.289 * sin(M) -- longitude
        b = rad * 5.128 * sin(F) -- latitude
        dt = 385001 - 20905 * cos(M) -- distance to the moon in km

        return {
            ra = rightAscension(l, b),
            dec = declination(l, b),
            dist = dt
        }
    end
    SunCalc.getMoonPosition = function(date, lat, lng)
        lw = rad * -lng
        phi = rad * lat
        d = toDays(date)

        c = moonCoords(d)
        H = siderealTime(d, lw) - c.ra
        h = altitude(H, phi, c.dec)
        -- formula 14.1 of "Astronomical Algorithms" 2nd edition by Jean Meeus (Willmann-Bell, Richmond) 1998.
        pa = atan(sin(H), tan(phi) * cos(c.dec) - sin(c.dec) * cos(H))

        h = h + astroRefraction(h) -- altitude correction for refraction

        return {
            azimuth = azimuth(H, phi, c.dec),
            altitude = h,
            distance = c.dist,
            parallacticAngle = pa
        }
    end

    -- calculations for illumination parameters of the moon,
    -- based on http://idlastro.gsfc.nasa.gov/ftp/pro/astro/mphase.pro formulas and
    -- Chapter 48 of "Astronomical Algorithms" 2nd edition by Jean Meeus (Willmann-Bell, Richmond) 1998.
    SunCalc.getMoonIllumination = function(date)
        d = toDays(date)
        s = sunCoords(d)
        m = moonCoords(d)

        sdist = 149598000 -- distance from Earth to Sun in km

        phi = acos(sin(s.dec) * sin(m.dec) + cos(s.dec) * cos(m.dec) * cos(s.ra - m.ra))
        inc = atan(sdist * sin(phi), m.dist - sdist * cos(phi))
        angle = atan(cos(s.dec) * sin(s.ra - m.ra), sin(s.dec) * cos(m.dec) - cos(s.dec) * sin(m.dec) * cos(s.ra - m.ra))

        return {
            fraction = (1 + cos(inc)) / 2,
            phase = 0.5 + 0.5 * inc * (angle < 0 and -1 or 1) / math.pi,
            angle = angle
        }
    end
    function hoursLater(date, h)
        return date + h * dayMs / 24
    end
    -- calculations for moon rise/set times are based on http://www.stargazing.net/kepler/moonrise.html article
    SunCalc.getMoonTimes = function(date, lat, lng)
        t = date
        hc = 0.133 * rad
        h0 = SunCalc.getMoonPosition(t, lat, lng).altitude - hc
        h1, h2, rise, set, a, b, xe, ye, d, roots, x1, x2, dx = nil

        -- go in 2-hour chunks, each time seeing if a 3-point quadratic curve crosses zero (which means rise or set)
        for i = 1, 24, 2 do
            h1 = SunCalc.getMoonPosition(hoursLater(t, i), lat, lng).altitude - hc
            h2 = SunCalc.getMoonPosition(hoursLater(t, i + 1), lat, lng).altitude - hc

            a = (h0 + h2) / 2 - h1
            b = (h2 - h0) / 2
            xe = -b / (2 * a)
            ye = (a * xe + b) * xe + h1
            d = b * b - 4 * a * h1
            roots = 0

            if d >= 0 then
                dx = math.sqrt(d) / (math.abs(a) * 2)
                x1 = xe - dx
                x2 = xe + dx
                if math.abs(x1) <= 1 then
                    roots = roots + 1
                end
                if math.abs(x2) <= 1 then
                    roots = roots + 1
                end
                if x1 < -1 then
                    x1 = x2
                end
            end

            if roots == 1 then
                if h0 < 0 then
                    rise = i + x1
                else
                    set = i + x1
                end
            elseif roots == 2 then
                rise = i + (ye < 0 and x2 or x1)
                set = i + (ye < 0 and x1 or x2)
            end

            if rise and set then
                break
            end

            h0 = h2
        end

        result = {}

        if rise then
            result.rise = hoursLater(t, rise)
        end
        if set then
            result.set = hoursLater(t, set)
        end

        if not rise and not set then
            result[ye > 0 and "alwaysUp" or "alwaysDown"] = true
        end

        return result
    end
    -- ---------- NOT PART OF THE ORIGINAL SCRIPT - HAD TO BE ADDED FOR THE SCRIPT TO WORK IN LUA ----------
    function math.round(num, numDecimalPlaces)
        local mult = 10 ^ (numDecimalPlaces or 0)
        return math.floor(num * mult + 0.5) / mult
    end
    function table.length(T)
        local count = 0
        for _ in pairs(T) do
            count = count + 1
        end
        return count
    end
    --==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==--==
    function getKeysSortedByValue(tbl, sortFunction)
        local keys = {}
        for key in pairs(tbl) do
            table.insert(keys, key)
        end

        table.sort(
            keys,
            function(a, b)
                return sortFunction(tbl[a], tbl[b])
            end
        )

        return keys
    end

    table.reverse = function(t)
        local index = {}
        for k, v in pairs(t) do
            index[v] = k
        end
        return index
    end

    function formatTime(tm)
        return os.date("%H:%M", math.floor(tm / 1000))
    end

    local events = {
        ["nauticalDawn"] = 1,
        ["blueHourDawn"] = 2,
        ["dawn"] = 3,
        ["blueHourDawnEnd"] = 4,
        ["sunrise"] = 5,
        ["sunriseEnd"] = 6,
        ["goldenHourEnd"] = 7,  -- Morning
        ["solarNoon"] = 8,  -- Day
        ["goldenHour"] = 9, -- Evening
        ["sunsetStart"] = 10,
        ["sunset"] = 11,
        ["blueHourDusk"] = 12,
        ["dusk"] = 13,
        ["blueHourDuskEnd"] = 14,
        ["nauticalDusk"] = 15,
        ["night"] = 16, -- Night
        ["nadir"] = 17,
        ["nightEnd"] = 18
    }

    function dump(o)
        if type(o) == "table" then
            local s = "{ "
            for k, v in pairs(o) do
                if type(k) ~= "number" then
                    k = '"' .. k .. '"'
                end
                s = s .. "[" .. k .. "] = " .. dump(v) .. ","
            end
            return s .. "} "
        else
            return tostring(o)
        end
    end

    function toTime(t)
        for k, v in pairs(t) do
            -- print(k, v)
            t[k] = os.date('%H:%M', math.floor(v / 1000))
        end
        return t
    end

    local location = api.get("/panels/location")
    local lat = location[1].latitude
    local lon = location[1].longitude

    function QuickApp:sunCalc()
        local mDate = os.time() * 1000
        local sunTimes = SunCalc.getTimes(mDate, lat, lon)
        local sunrise, sunset, dawn, dusk =
            formatTime(sunTimes["sunrise"]),
            formatTime(sunTimes["sunset"]),
            formatTime(sunTimes["dawn"]),
            formatTime(sunTimes["dusk"])
        -- print(sunrise, sunset, dawn, dusk);

        fibaro.setGlobalVariable("Sunrise", sunrise)
        fibaro.setGlobalVariable("SunriseTwilight", dawn)
        
        fibaro.setGlobalVariable("SunsetTwilight", dusk)
        fibaro.setGlobalVariable("Sunset", sunset)

        self:updateView(
            "lblStatus",
            "text",
            "🌄" .. dawn .. "|" .. "🌅" .. sunrise .. "|" .. "🌇" .. sunset .. "|" .. "✨" .. dusk
        )
        local sortedKeys =
            getKeysSortedByValue(
            sunTimes,
            function(a, b)
                return a < b
            end 
        )
        local dayPart = nil
        for _, key in ipairs(sortedKeys) do
            if sunTimes[key] <= mDate then
                dayPart = key
            end
        end
        dayPart = dayPart or "night"
        dayPart = {dayPart = dayPart, dayPartIndex = events[dayPart], events = toTime(sunTimes)}
        self:updateProperty("userDescription", json.encode(dayPart))
        fibaro.setGlobalVariable("DayPart", string.upper(dayPart.dayPart))
        
        -- visual
        if events[dayPart.dayPart] == 7 then
            dayPart.dayPart = "Morning"
        elseif events[dayPart.dayPart] == 8 then
            dayPart.dayPart = "Day"
        end
        self:updateProperty("log", dayPart.dayPart)
    end

    function QuickApp:onInit()
        self:debug("onInit")
        self:updateProperty("deviceIcon", 1040)
        self:sunCalc()
        setInterval(
            function()
                self:sunCalc()
            end,
            1000 * 60 * 1
        )
    end
