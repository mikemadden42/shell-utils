#!/bin/bash

# Replace with your desired date in the past (YYYY-MM-DD format)
past_date="2020-07-06"

# Get timestamps in seconds since epoch for today and past date
now_seconds=$(date +%s)
past_seconds=$(date +%s --date="$past_date")

# Calculate the difference in seconds
difference_seconds=$((now_seconds - past_seconds))

# Convert the difference to days (consider rounding behavior)
number_of_days=$((difference_seconds / (60 * 60 * 24)))

echo "There are $number_of_days days between today and '$past_date'."
