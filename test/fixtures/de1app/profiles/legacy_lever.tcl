advanced_shot {{exit_if 0 flow 4 volume 100 max_flow_or_pressure_range 0.6 transition fast popup {} exit_flow_under 0 temperature 91.5 weight 0.0 name {preinfusion start} pressure 1.1 sensor coffee pump pressure exit_type pressure_over exit_flow_over 6 exit_pressure_over 3.0 max_flow_or_pressure 0 exit_pressure_under 0 seconds 2} {exit_if 1 flow 4 volume 100 max_flow_or_pressure_range 0.6 transition fast popup {} exit_flow_under 0 temperature 91.5 weight 0.0 name preinfusion pressure 1.1 pump pressure sensor coffee exit_type pressure_over exit_flow_over 6 exit_pressure_over 3.0 max_flow_or_pressure 0 exit_pressure_under 0 seconds 3} {exit_if 0 volume 100 transition smooth exit_flow_under 0 temperature 92.0 name ramp pressure 9.0 sensor coffee pump pressure exit_flow_over 6 exit_pressure_over 11 seconds 20.0 exit_pressure_under 0}}
author Test Author
profile_title {Legacy Lever}
profile_notes {A pre-v2 profile that only exists as a legacy .tcl file.}
beverage_type espresso
settings_profile_type settings_2c
final_desired_shot_weight_advanced 36
final_desired_shot_volume_advanced 0
final_desired_shot_volume_advanced_count_start 0
tank_desired_water_temperature 0
