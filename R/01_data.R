# =============================================================================
# 01_data.R — Build the quarterly macro dataset
#
# Input:  data/raw/*.csv        (downloaded manually; see data/raw/SOURCES.md)
# Output: data/processed/macro_q.csv
#
# Steps
#   1. Read each raw file and keep only the data rows (StatCan files have
#      footnotes and citation lines at the bottom).
#   2. Monthly series: average the levels over each quarter.
#   3. Put every series in model form:
#        oil                  100 x quarterly log change
#        gdp, us_gdp, cpi, hpi annualized q/q growth = 400 x quarterly log change
#        unemp, policy_rate   levels (%)
#   4. Trim to the policy-rate sample: full quarters only, starting 2009Q3.
#   5. Merge, add COVID dummies, check, and save.
#
# Growth rates are computed on the full history BEFORE trimming, so the first
# quarter of the sample (2009Q3) still has a growth rate (it needs 2009Q2).
# =============================================================================

library(dplyr)
library(readr)
library(lubridate)

raw_dir <- "data/raw"
out_dir <- "data/processed"


# --- Helpers -----------------------------------------------------------------

# StatCan CSVs end with footnotes and citations. Keep the header line plus
# only the lines that start with a date, then parse those as a CSV.
read_data_rows <- function(file, date_pattern) {
  con   <- file(file.path(raw_dir, file), encoding = "UTF-8-BOM")  # strips the BOM
  lines <- readLines(con, warn = FALSE)
  close(con)
  keep  <- c(lines[1], grep(date_pattern, lines, value = TRUE, useBytes = TRUE))
  read_csv(I(keep), col_types = cols(.default = col_character()),
           name_repair = "minimal") |>
    select(1, 2) |>                                   # date and value only
    setNames(c("date", "value"))
}

# "Jan-92" -> 1992-01-01. Uses month.abb (always English), so it works
# regardless of your computer's language settings.
parse_mon_yy <- function(x) {
  month <- match(substr(x, 1, 3), month.abb)
  yy    <- as.integer(substr(x, 5, 6))
  year  <- ifelse(yy >= 50, 1900 + yy, 2000 + yy)
  make_date(year, month, 1)
}

# "Q1 1992" -> 1992-01-01 (first day of the quarter)
parse_q_yyyy <- function(x) {
  q    <- as.integer(substr(x, 2, 2))
  year <- as.integer(substr(x, 4, 7))
  make_date(year, 3 * q - 2, 1)
}

# Average a monthly series over each calendar quarter. Only quarters with
# all three months are kept, so a half-finished quarter can't sneak in.
monthly_to_quarterly <- function(df) {
  df |>
    mutate(quarter = floor_date(date, "quarter")) |>
    group_by(quarter) |>
    summarise(n = n(), value = mean(value), .groups = "drop") |>
    filter(n == 3) |>
    select(quarter, value)
}

# Annualized quarterly growth, in %: 400 x change in log level
growth_ann <- function(x) 400 * (log(x) - lag(log(x)))


# --- 1. Quarterly series -----------------------------------------------------

# WTI: downloaded from FRED already averaged to quarters
oil <- read_csv(file.path(raw_dir, "wti.csv"), show_col_types = FALSE) |>
  transmute(quarter = as.Date(date),
            oil = 100 * (log(price) - lag(log(price))))

us_gdp <- read_csv(file.path(raw_dir, "us_gdp.csv"), show_col_types = FALSE) |>
  transmute(quarter = as.Date(observation_date),
            us_gdp  = growth_ann(GDPC1))

gdp <- read_data_rows("can_gdp.csv", "^Q[1-4] [0-9]{4}") |>
  transmute(quarter = parse_q_yyyy(date),
            level   = parse_number(value)) |>       # handles "1,139,828"
  arrange(quarter) |>
  transmute(quarter, gdp = growth_ann(level))


# --- 2. Monthly series -> quarterly averages -> model form -------------------

monthly_pattern <- "^[A-Z][a-z]{2}-[0-9]{2},"

read_monthly <- function(file) {
  read_data_rows(file, monthly_pattern) |>
    transmute(date = parse_mon_yy(date), value = as.numeric(value)) |>
    arrange(date) |>
    monthly_to_quarterly()
}

cpi <- read_monthly("ca_cpi.csv") |>
  transmute(quarter, cpi = growth_ann(value))

hpi <- read_monthly("ca_nhpi.csv") |>
  transmute(quarter, hpi = growth_ann(value))

unemp <- read_monthly("ca_unemp.csv") |>
  rename(unemp = value)


# --- 3. Policy rate (daily) -> quarterly average, full quarters only ----------

boc_daily <- read_csv(file.path(raw_dir, "boc_rate.csv"), show_col_types = FALSE) |>
  transmute(date = as.Date(date), policy_rate)

# A quarter counts as "full" if the data start within its first week and run
# to within its last week (allowing for weekends and holidays). This drops
# 2009Q2 (series starts Apr 21) and the current, unfinished quarter.
policy_rate <- boc_daily |>
  mutate(quarter = floor_date(date, "quarter")) |>
  group_by(quarter) |>
  summarise(first = min(date), last = max(date),
            policy_rate = mean(policy_rate), .groups = "drop") |>
  filter(first <= quarter + days(7),
         last  >= ceiling_date(quarter, "quarter") - days(8)) |>
  select(quarter, policy_rate)


# --- 4. Merge and trim to the policy-rate sample -----------------------------

macro <- policy_rate |>
  left_join(oil,    by = "quarter") |>
  left_join(us_gdp, by = "quarter") |>
  left_join(gdp,    by = "quarter") |>
  left_join(unemp,  by = "quarter") |>
  left_join(cpi,    by = "quarter") |>
  left_join(hpi,    by = "quarter") |>
  select(quarter, oil, us_gdp, gdp, unemp, cpi, policy_rate, hpi)

# Report quarters dropped at the end because a series isn't published yet
# (the "ragged edge": e.g. GDP comes out about two months after quarter-end)
incomplete <- macro |> filter(if_any(-quarter, is.na))
if (nrow(incomplete) > 0) {
  message("Dropping quarters with missing values (not yet published):")
  for (i in seq_len(nrow(incomplete))) {
    miss <- names(incomplete)[is.na(incomplete[i, ])]
    message("  ", format(incomplete$quarter[i]), ": ", paste(miss, collapse = ", "))
  }
}

macro <- macro |>
  filter(if_all(everything(), ~ !is.na(.x))) |>
  mutate(covid_q2 = as.integer(quarter == as.Date("2020-04-01")),
         covid_q3 = as.integer(quarter == as.Date("2020-07-01")))


# --- 5. Checks ---------------------------------------------------------------

expected <- seq(min(macro$quarter), max(macro$quarter), by = "quarter")
stopifnot(
  "Duplicate quarters"        = !anyDuplicated(macro$quarter),
  "Gaps between quarters"     = identical(macro$quarter, expected),
  "Sample should start 2009Q3" = min(macro$quarter) == as.Date("2009-07-01"),
  "COVID dummies not found"   = sum(macro$covid_q2) == 1 && sum(macro$covid_q3) == 1
)


# --- 6. Save -----------------------------------------------------------------

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
write_csv(macro, file.path(out_dir, "macro_q.csv"))

message(sprintf("Saved %s: %d quarters (%s to %s), %d columns",
                file.path(out_dir, "macro_q.csv"), nrow(macro),
                format(min(macro$quarter)), format(max(macro$quarter)),
                ncol(macro)))
