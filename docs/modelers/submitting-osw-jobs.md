# Submitting OSW Jobs to OpenStudio Server

OpenStudio Server accepts building energy simulation work through its REST API.
The primary input format is an **OpenStudio Workflow (OSW)** file, which
describes the measures, weather file, seed model, and arguments for a run.

---

## What is an OSW File?

An OSW (OpenStudio Workflow) file is a JSON document that defines:
- The seed `.osm` building model
- The weather file (`.epw`)
- A sequence of OpenStudio Measures to apply
- The arguments for each measure

Example minimal OSW:

```json
{
  "seed_file": "baseline.osm",
  "weather_file": "USA_CO_Denver.Intl.AP.725650_TMY3.epw",
  "steps": [
    {
      "measure_dir_name": "reduce_lighting_loads_by_percentage",
      "arguments": {
        "lighting_power_reduction_percent": 25
      }
    }
  ]
}
```

---

## Submitting via the Web UI

1. Open the OpenStudio Server web interface at `http://<server-ip>:80`
2. Click **New Analysis**
3. Upload a ZIP file containing:
   - Your OSW file
   - The seed `.osm` model
   - The weather `.epw` file
   - Any custom measures
4. Configure the number of design alternatives (datapoints)
5. Click **Run Analysis**

---

## Submitting via Parametric Analysis Tool (PAT)

[PAT](https://github.com/NREL/OpenStudio-PAT) is the recommended GUI
for building modelers who want to run parametric sweeps without writing code.

1. Open PAT and create or open a project
2. Under **Server Settings**, enter `http://<server-ip>:80`
3. Define your measures and sampling method
4. Click **Run on Server**

PAT handles packaging the OSW, uploading it, and polling for results
automatically.

---

## Submitting via the REST API

For scripted or automated submissions, use the OpenStudio Server REST API directly.

**Upload and run an analysis:**

```bash
# Upload analysis ZIP
curl -X POST http://<server-ip>:80/analyses.json \
  -F "analysis[display_name]=My Parametric Study" \
  -F "analysis[upload]=@my_analysis.zip"

# Start the analysis (replace <analysis-id> with the returned ID)
curl -X POST http://<server-ip>:80/analyses/<analysis-id>/action.json \
  -d "analysis_action[action]=start"
```

**Poll for status:**

```bash
curl http://<server-ip>:80/analyses/<analysis-id>.json | python3 -m json.tool
```

**Download results:**

```bash
curl -O http://<server-ip>:80/analyses/<analysis-id>/download_data.csv
```

---

## Retrieving Results

Results are available through the web UI under the analysis detail page, or
via the API as CSV or JSON downloads.

For large parametric studies, results can also be accessed directly from
the MongoDB database. Contact your cluster admin for connection credentials.

---

## Next Steps

- [Quickstart Guide](quickstart.md) — deploy the server
- [Variable Reference](../variables.md) — tune worker count and resources
- [Infrastructure Docs](../infrastructure/) — NFS, Vault, autoscaling
