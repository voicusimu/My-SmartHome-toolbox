import express from "express";

const app = express();

const SHELLY_IP = "192.168.100.102";
const THERM_ID = 0;
const PORT = 18080;

async function shellyGet(path) {
  const url = `http://${SHELLY_IP}${path}`;

  const res = await fetch(url, {
    method: "GET",
    signal: AbortSignal.timeout(5000)
  });

  if (!res.ok) {
    throw new Error(`Shelly HTTP ${res.status} for ${path}`);
  }

  return res.json();
}

async function shellySetConfig(configObject) {
  const config = encodeURIComponent(JSON.stringify(configObject));

  return shellyGet(
    `/rpc/Thermostat.SetConfig?id=${THERM_ID}&config=${config}`
  );
}

/*
 * Get thermostat state
 *
 * HomeKit states:
 *
 * TargetHeatingCoolingState
 *   0 = OFF
 *   1 = HEAT
 *
 * CurrentHeatingCoolingState
 *   0 = OFF
 *   1 = HEAT
 */
app.get("/status", async (req, res) => {
  try {
    const st = await shellyGet(
      `/rpc/Thermostat.GetStatus?id=${THERM_ID}`
    );

    res.json({
      targetHeatingCoolingState: st.enable ? 1 : 0,

      targetTemperature: Number(st.target_C),

      currentHeatingCoolingState:
        st.enable && st.output ? 1 : 0,

      currentTemperature: Number(st.current_C)
    });

  } catch (e) {
    console.error("GET /status:", e);
    res.status(500).json({
      error: String(e)
    });
  }
});


/*
 * Set target temperature
 *
 * Example:
 * /targetTemperature/23.5
 */
app.get("/targetTemperature", async (req, res) => {
  try {
    const value = Number(req.query.value);

    if (!Number.isFinite(value)) {
      return res.status(400).json({
        error: "Invalid temperature"
      });
    }

    // Sensible limits for the HomeKit thermostat
    if (value < 5 || value > 35) {
      return res.status(400).json({
        error: "Temperature must be between 5 and 35 C"
      });
    }

    const result = await shellySetConfig({
      target_C: value
    });

    res.json(result);

  } catch (e) {
    console.error("SET target temperature:", e);
    res.status(500).json({
      error: String(e)
    });
  }
});


/*
 * Set thermostat mode
 *
 * HomeKit:
 * 0 = OFF
 * 1 = HEAT
 *
 * Examples:
 * /targetHeatingCoolingState/0
 * /targetHeatingCoolingState/1
 */
app.get("/targetHeatingCoolingState", async (req, res) => {
  try {
    const value = Number(req.query.value);

    if (value !== 0 && value !== 1) {
      return res.status(400).json({
        error: "Only OFF (0) and HEAT (1) are supported"
      });
    }

    const result = await shellySetConfig({
      enable: value === 1
    });

    res.json(result);

  } catch (e) {
    console.error("SET thermostat state:", e);
    res.status(500).json({
      error: String(e)
    });
  }
});


app.listen(PORT, "0.0.0.0", () => {
  console.log(
    `Shelly thermostat proxy listening on port ${PORT}`
  );
});