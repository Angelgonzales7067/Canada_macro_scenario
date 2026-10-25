# Run the full pipeline: raw data -> quarterly dataset -> VAR scenarios.
# Run from the project folder (open Canada_macro_scenario.Rproj first).

source("R/01_data.R")        # writes data/processed/macro_q.csv
source("R/02_scenarios.R")   # writes output/scenario_results.csv, scenario_summary.csv, scenarios.png
