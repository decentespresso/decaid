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

The historical JavaScript port used milliseconds for event timestamps, converted elapsed time to seconds, retained the existing event fields, and reported `heatingRate: null` because this formulation did not calculate a slope.

## Dead guard finding

The publication guard at `skin.tcl:1005-1012` is not effective:

> `set force_update 1`
>
> `if {$ETA < $::streamline_start_heating_eta_previous || $force_update == 1} {`

Because `force_update` is assigned `1` immediately before the comparison at `skin.tcl:1005`, the never-increase branch cannot be selected. The plugin intentionally does not port this dead guard as written.

## Current estimator: recent rate

The plugin preserves session bookkeeping but no longer ports the whole-climb ETA. It seeds the session reference on the first below-target observation and resets it on `ready`, sleep, a target temperature change, or cooling 2 K below the session start. It records a trailing 18-second temperature series, requires at least eight samples, and uses the median of adjacent-interval slopes as the recent `heatingRate`. The published ETA is:

> `remaining = max(target_temperature - current_temperature, 0)`
>
> `ETA = clamp(round_to_tens(remaining / heatingRate), 5, 300)`

The `target_temperature - 10` offset is intentionally deleted. It was de1app's way of absorbing a slow tail, but it collapses the denominator near target. On a slow machine that reaches the countdown floor while several kelvin remain; on a fast machine it compresses the useful countdown into the last few round-to-tens steps. A trailing rate adapts to both heating speeds, and the payload's `heatingRate` now reports that rate in K/s. Until eight recent samples produce a positive median rate, the plugin publishes `insufficient_data`; `reached` remains unchanged.

## Deliberate deviation: active non-increasing ceiling

The plugin keeps an active ceiling for each heating session. The first published countdown after a heat-start reference is the ceiling; later estimates can only decrease or stay equal. The ceiling resets with the session reference on `ready`, sleep, target change, or the cooling reset.

This is stricter than de1app's live behavior and directly prevents the observed countdown jump from 30 seconds to 60 seconds. The cost is that a real slowdown cannot increase the displayed countdown, so the number can under-report remaining time until the next reset.
