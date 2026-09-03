# Isaiah Lacet
# New Orleans AirBNB Price Transparency A/B Test


library(readr)
library(dplyr)
library(ggplot2)
library(stringr)

set.seed(123)

# Load Data #
nc_listings <- read.csv("new_orleans_airbnb_listings.csv")

listings <- nc_listings %>%
  mutate(
    price = as.numeric(gsub("[\\$,]", "", price)),
    rating = review_scores_rating,
    superhost = ifelse(host_is_superhost == "t",1,0),
    instant_book = ifelse(instant_bookable == "t",1,0)
  ) %>%
  filter(
    !is.na(id),
    !is.na(price),
    price > 0,
    !is.na(rating),
    rating > 0
  ) %>%
  select(
    id, price, rating,
    superhost, instant_book,
    room_type, number_of_reviews,
    reviews_per_month, availability_30
  )

n_sessions <- 50000

sessions <- data.frame(
  session_id = 1:n_sessions,
  
  # Randomly choose which listing a user views
  listing_id = sample(listings$id, n_sessions, replace = TRUE),
  
  # Random assignment to Control (A) vs Treatment (B)
  variant = sample(c("A", "B"), n_sessions, replace = TRUE)
)

# Attach listing features to each session row
experiment_data <- sessions %>%
  left_join(listings, by = c("listing_id" = "id"))

# ---------------------------
# Simulate "Started Checkout"
# ---------------------------
experiment_data <- experiment_data %>%
  mutate(
    prob_checkout = plogis(
      -2.1            
      - 0.001 * price  
      + 0.15 * rating   
      + 0.2 * instant_book
      + 0.2 * superhost
    ),
    started_checkout = rbinom(n(), size = 1, prob = prob_checkout)
  )

summary(experiment_data$prob_checkout)

# ---------------------------
# Simulate "Completed Booking" Conditional on Checkout
# ---------------------------
experiment_data <- experiment_data %>%
  mutate(
    base_completion_prob = 0.68,
    completion_prob = ifelse(
      variant == "B",
      base_completion_prob + 0.02,
      base_completion_prob
    ),
    completed_booking = ifelse(
      started_checkout == 1,
      rbinom(n(), size = 1, prob = completion_prob),
      0
    )
  )

# ---------------------------
# Experiment Integrity Checks
# ---------------------------

# Sample Ratio Mismatch (SRM): should be ~50/50
srm_table <- table(experiment_data$variant)
print(srm_table)
print(chisq.test(srm_table))

# Balance check
balance_check <- experiment_data %>%
  group_by(variant) %>%
  summarise(
    n = n(),
    mean_price = mean(price, na.rm = TRUE),
    mean_rating = mean(rating, na.rm = TRUE),
    pct_superhost = mean(superhost, na.rm = TRUE),
    pct_instant_book = mean(instant_book, na.rm = TRUE)
  )

print(balance_check)

# Price distribution by variant
ggplot(experiment_data, aes(x = price)) +
  geom_histogram(bins = 50) +
  facet_wrap(~variant, scales = "free_y") +
  labs(title = "Price Distribution by Variant", x = "Price", y = "Count")

# ---------------------------
# Metrics (Primary + Secondary)
# ---------------------------
metrics_by_variant <- experiment_data %>%
  group_by(variant) %>%
  summarise(
    sessions = n(),
    checkout_start_rate = mean(started_checkout),
    checkout_completion_rate = sum(completed_booking) / sum(started_checkout),
    checkout_dropoff_rate = 1 - (sum(completed_booking) / sum(started_checkout)),
    booking_conversion_rate = mean(completed_booking)
  )

print(metrics_by_variant)

# ---------------------------
# Statistical Tests
# ---------------------------

# Primary test: completion among checkout starters (B > A)
starters <- experiment_data %>% filter(started_checkout == 1)

primary_test <- prop.test(
  x = tapply(starters$completed_booking, starters$variant, sum),
  n = tapply(starters$completed_booking, starters$variant, length),
  alternative = "less"
)
print(primary_test)

# Secondary test: overall booking conversion (B > A)
secondary_test <- prop.test(
  x = tapply(experiment_data$completed_booking, experiment_data$variant, sum),
  n = tapply(experiment_data$completed_booking, experiment_data$variant, length),
  alternative = "less"
)
print(secondary_test)


# ---------------------------
# Bar Chart: Checkout Completion Rate (Primary Metric)
# ---------------------------
# Prep data for plotting
plot_df <- metrics_by_variant %>%
  select(variant, checkout_completion_rate) %>%
  mutate(
    variant = factor(variant, levels = c("A", "B")),
    rate_pct = checkout_completion_rate * 100
  )

# Calculate lift (B - A) in percentage points
lift_pp <- with(plot_df, rate_pct[variant == "B"] - rate_pct[variant == "A"])

# Bar chart
ggplot(plot_df, aes(x = variant, y = checkout_completion_rate)) +
  geom_col(width = 0.6) +
  geom_text(
    aes(label = sprintf("%.1f%%", rate_pct)),
    vjust = -0.6,
    size = 5
  ) +
  scale_y_continuous(
    labels = scales::percent_format(accuracy = 1),
    limits = c(0, max(plot_df$checkout_completion_rate) + 0.07)
  ) +
  labs(
    title = "Checkout Completion Rate by Variant",
    x = "Variant",
    y = "Checkout Completion Rate"
  ) +
  theme_minimal(base_size = 14)

# ---------------------------
# Logistic Regression (Precision / Controls)
# ---------------------------
# Model completion among starters as a function of treatment + listing controls.
starters <- starters %>% mutate(variant_B = ifelse(variant == "B", 1, 0))

model <- glm(
  completed_booking ~ variant_B + price + rating + superhost + instant_book,
  data = starters,
  family = binomial()
)

print(summary(model))


