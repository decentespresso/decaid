# Issue 1019 — de1app time-to-ready reference

## Canonical source

The bundled plugin ports the estimator in `/Users/vid/development/repos/de1app/de1plus/skins/Streamline/skin.tcl:955-1020`.
The skin records its reference on the `ready` substate, rather than when the machine first enters `heating`:

> `set ::streamline_start_heating_time [clock seconds]`
>
> `set ::streamline_start_heating_temp [group_head_heater_temperature]`

The not-ready calculation at `skin.tcl:968-1000` is:

> `set elapsed [expr {[clock seconds] - $::streamline_start_heating_time}]`
>
> `if {$elapsed == 0} { set elapsed 1 }`
>
> `set warmed [expr {[group_head_heater_temperature] - $::streamline_start_heating_temp}]`
>
> `if {$warmed < 1} { set warmed 1 }`
>
> `set togo [expr {([setting_espresso_temperature]-10) - [group_head_heater_temperature]}]`
>
> `if {$togo > 100} { set togo 100 }`
>
> `if {$togo < 1} { set togo 1 }`
>
> `set progress [expr {1.0*$warmed/$togo}]`
>
> `set ETA [round_to_tens [expr {int(1.0*$elapsed/$progress)}]]`
>
> `if {$ETA < 5} { set ETA 5 }`
>
> `if {$ETA > 300} { set ETA 300 }`

`round_to_tens` is defined in `/Users/vid/development/repos/de1app/de1plus/vars.tcl:1652-1658` as:

> `set x [expr {round($in / 10.0)*10}]`

The JavaScript port uses milliseconds for event timestamps, converts elapsed time to seconds, retains the existing event fields, and reports `heatingRate: null` because this formulation does not calculate a slope.

## Dead guard finding

The publication guard at `skin.tcl:1005-1012` is not effective:

> `set force_update 1`
>
> `if {$ETA < $::streamline_start_heating_eta_previous || $force_update == 1} {`

Because `force_update` is assigned `1` immediately before the comparison at `skin.tcl:1005`, the never-increase branch cannot be selected. The plugin intentionally does not port this dead guard as written.

## Deliberate deviation: active non-increasing ceiling

The plugin keeps an active ceiling for each heating session. The first published countdown after a heat-start reference is the ceiling; later estimates can only decrease or stay equal. The ceiling resets when the target changes or the machine sleeps, along with the ready reference.

This is stricter than de1app's live behavior and directly prevents the observed countdown jump from 30 seconds to 60 seconds. The cost is that a real slowdown cannot increase the displayed countdown, so the number can under-report remaining time until the next reset. `insufficient_data` remains reserved for missing references and non-heating machine states.
