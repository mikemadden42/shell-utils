#!/bin/bash

POWER_SUPPLY_DIR="/sys/class/power_supply"

if [ ! -d "$POWER_SUPPLY_DIR" ]; then
	echo "Error: Power supply directory not found."
	exit 1
fi

echo "Scanning for batteries..."
echo "--------------------------------------------------"

found_battery=false

for bat_path in "$POWER_SUPPLY_DIR"/BAT*; do
	if [ -d "$bat_path" ]; then
		found_battery=true
		bat_name=$(basename "$bat_path")

		# --- Basic Stats ---
		# Cycle Count
		if [ -f "$bat_path/cycle_count" ]; then
			cycle_count=$(cat "$bat_path/cycle_count")
		else
			cycle_count="N/A"
		fi

		# Capacity % (Current charge level)
		if [ -f "$bat_path/capacity" ]; then
			capacity=$(cat "$bat_path/capacity")
		else
			capacity="N/A"
		fi

		# Status
		if [ -f "$bat_path/status" ]; then
			status=$(cat "$bat_path/status")
		else
			status="Unknown"
		fi

		# --- Health Calculation ---
		# Some drivers use 'energy', others use 'charge'. We check both.
		current_max=0
		design_max=0

		# Check for current maximum capacity
		if [ -f "$bat_path/energy_full" ]; then
			current_max=$(cat "$bat_path/energy_full")
		elif [ -f "$bat_path/charge_full" ]; then
			current_max=$(cat "$bat_path/charge_full")
		fi

		# Check for original design capacity
		if [ -f "$bat_path/energy_full_design" ]; then
			design_max=$(cat "$bat_path/energy_full_design")
		elif [ -f "$bat_path/charge_full_design" ]; then
			design_max=$(cat "$bat_path/charge_full_design")
		fi

		# Calculate Health Percentage
		if [ "$design_max" -gt 0 ] && [ "$current_max" -gt 0 ]; then
			# Using awk for floating point division to get 2 decimal places
			health_percent=$(awk "BEGIN {printf \"%.2f\", ($current_max / $design_max) * 100}")
		else
			health_percent="N/A"
		fi

		# --- Output ---
		echo "Battery:       $bat_name"
		echo "Status:        $status"
		echo "Current Level: $capacity%"
		echo "Cycle Count:   $cycle_count"
		echo "Health:        $health_percent% of original capacity"

		# Optional: Print raw numbers if health is available for debugging
		if [ "$health_percent" != "N/A" ]; then
			echo "  (Current Max: $current_max / Design Max: $design_max)"
		fi
		echo "--------------------------------------------------"
	fi
done

if [ "$found_battery" = false ]; then
	echo "No batteries found."
fi
