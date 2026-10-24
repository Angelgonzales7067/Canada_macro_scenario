# =============================================================================
# 02_scenarios.R — VAR with oil and US GDP as external drivers, three scenarios
#
# Input:  data/processed/macro_q.csv   (from 01_data.R)
#         data/raw/wti.csv             (oil price LEVEL, to build the paths)
# Output: output/scenario_results.csv  (every quarter, every scenario)
#         output/scenario_summary.csv  (2027 averages, and gap vs baseline)
#         output/scenarios.png         (chart)
#
# How it works
#   Canadian variables (gdp, unemp, cpi, policy_rate, hpi) are explained by
#   their own past values plus oil and US GDP growth. Oil and US GDP are
#   "exogenous": we set their future paths by hand (the scenario), and the
#   model forecasts the Canadian variables conditional on those paths.
# =============================================================================

library(vars)      # load first: it attaches MASS, whose select() would hide dplyr's
library(dplyr)
library(readr)
library(tidyr)
library(ggplot2)

horizon  <- 9                                   # 2026Q3 to 2028Q3
quarters <- seq(as.Date("2026-07-01"), by = "quarter", length.out = horizon)


# --- 1. Scenarios: edit these numbers to change the story --------------------
# Oil: WTI level in US$/bbl, one value per quarter, 2026Q3 to 2028Q3.
# 2026Q3 is the actual average (87.12), so all scenarios start from it.
# US GDP: annualized q/q growth in %, one value per quarter.

oil_q3_actual <- 87.12

scenarios <- list(
  baseline = list(
    label  = "Baseline: oil eases to $75, US growth ~2%",
    oil    = c(oil_q3_actual, seq(84, 75, length.out = 5), 75, 75, 75),   # $75 by 2027Q4
    us_gdp = rep(2.0, horizon)
  ),
  upside = list(
    label  = "Upside: oil drifts to $70, US growth ~3%",
    oil    = seq(oil_q3_actual, 70, length.out = horizon),                 # $70 by 2028Q3
    us_gdp = rep(3, horizon)
  ),
  downside = list(
    label  = "Downside: US slowdown, oil demand falls, oil $50, US growth ~0.5%",
    oil    = c(oil_q3_actual, 68, rep(50, horizon - 2)),                   # $50 by 2027Q1
    us_gdp = rep(0.5, horizon)
  )
)


# --- 2. Data -----------------------------------------------------------------

macro <- read_csv("data/processed/macro_q.csv", show_col_types = FALSE) |>
  mutate(oil_l1 = lag(oil), us_gdp_l1 = lag(us_gdp)) |>
  filter(!is.na(oil_l1))                       # first quarter has no lag

endog_vars <- c("gdp", "unemp", "cpi", "policy_rate", "hpi")
exog_vars  <- c("oil", "oil_l1", "us_gdp", "us_gdp_l1", "covid_q2", "covid_q3")

y <- as.matrix(macro[, endog_vars])
x <- as.matrix(macro[, exog_vars])

# Last in-sample oil level (2026Q2), needed to turn the oil path into growth
wti <- read_csv("data/raw/wti.csv", show_col_types = FALSE)
oil_last_level <- wti$price[wti$date == max(macro$quarter)]


# --- 3. Estimate the VAR -----------------------------------------------------
# 1 lag: with ~67 quarters, more lags would eat the degrees of freedom.

fit <- VAR(y, p = 1, type = "const", exogen = x)
print(summary(fit)$varresult$gdp)                # GDP equation, for a look


# --- 4. Run each scenario ----------------------------------------------------

run_scenario <- function(s) {
  oil_growth <- 100 * diff(log(c(oil_last_level, s$oil)))   # same units as data
  x_future <- cbind(
    oil       = oil_growth,
    oil_l1    = c(tail(macro$oil, 1), head(oil_growth, -1)),
    us_gdp    = s$us_gdp,
    us_gdp_l1 = c(tail(macro$us_gdp, 1), head(s$us_gdp, -1)),
    covid_q2  = 0,
    covid_q3  = 0
  )
  fc <- predict(fit, n.ahead = horizon, dumvar = x_future)
  as_tibble(sapply(fc$fcst, function(v) v[, "fcst"])) |>
    mutate(quarter = quarters, oil_price = s$oil, us_gdp = s$us_gdp,
           .before = 1)
}

results <- lapply(names(scenarios), function(nm) {
  run_scenario(scenarios[[nm]]) |> mutate(scenario = nm, .before = 1)
}) |>
  bind_rows() |>
  # Judgment overlay: the policy rate can't go below its effective floor
  mutate(policy_rate = pmax(policy_rate, 0.25))


# --- 5. Summarise and save ---------------------------------------------------

dir.create("output", showWarnings = FALSE)
write_csv(results, "output/scenario_results.csv")

summary_2027 <- results |>
  filter(format(quarter, "%Y") == "2027") |>
  group_by(scenario) |>
  summarise(across(c(oil_price, us_gdp, all_of(endog_vars)), mean), .groups = "drop")

gap_vs_base <- summary_2027 |>
  mutate(across(-scenario, ~ .x - .x[scenario == "baseline"])) |>
  filter(scenario != "baseline") |>
  mutate(scenario = paste(scenario, "minus baseline"))

summary_out <- bind_rows(summary_2027, gap_vs_base) |>
  mutate(across(where(is.numeric), ~ round(.x, 2)))
write_csv(summary_out, "output/scenario_summary.csv")

cat("\n2027 averages (growth rates are annualized q/q, %):\n")
print(as.data.frame(summary_out))


# --- 6. Chart: history since 2021 (after the COVID swings) plus the three scenarios -------------------

labels <- c(gdp = "Real GDP growth (% q/q ann.)", unemp = "Unemployment rate (%)",
            cpi = "CPI inflation (% q/q ann.)", policy_rate = "Policy rate (%)",
            hpi = "New house prices (% q/q ann.)")

history <- macro |>
  filter(quarter >= as.Date("2021-01-01")) |>
  select(quarter, all_of(endog_vars)) |>
  pivot_longer(-quarter) |>
  mutate(scenario = "history")

# Connect each scenario line to the last actual quarter
last_actual <- history |> filter(quarter == max(quarter)) |> select(-scenario)

paths <- results |>
  select(scenario, quarter, all_of(endog_vars)) |>
  pivot_longer(-c(scenario, quarter)) |>
  bind_rows(tidyr::crossing(last_actual, scenario = names(scenarios)))

p <- ggplot() +
  geom_line(data = history, aes(quarter, value), colour = "grey45") +
  geom_line(data = paths, aes(quarter, value, colour = scenario), linewidth = 0.9) +
  facet_wrap(~ name, scales = "free_y", ncol = 2,
             labeller = labeller(name = labels)) +
  scale_colour_manual(values = c(baseline = "#1f5fa8", upside = "#2e8b57",
                                 downside = "#c0392b")) +
  labs(title = "Canada: macro paths under three oil and US growth scenarios",
       subtitle = "VAR(1) with WTI and US GDP as exogenous drivers; history in grey",
       x = NULL, y = NULL, colour = NULL) +
  theme_minimal(base_size = 11) +
  theme(legend.position = "bottom")

ggsave("output/scenarios.png", p, width = 9, height = 8, dpi = 150)
message("Saved output/scenario_results.csv, output/scenario_summary.csv, output/scenarios.png")
