# Sensor Device Notes

## DiFluid R2

DiFluid R2 reflectometers are matched separately from DiFluid scales by
advertised name and the R2 BLE service UUID, then exposed through the standard
`Sensor` abstraction.

After connection, skins can call the existing Sensors API `measure` command and
read TDS, temperature, refractive index, and status values from the sensor data
stream.

## SensorBasket serial telemetry

SensorBasket discovery accepts finite and non-finite numeric placeholders in all
four telemetry channels and tolerates firmware whitespace separators. The serial
adapter keeps the temperature, pressure, weight, and weight-flow keys aligned;
invalid channel readings are published as `null` rather than non-finite JSON
numbers.

The issue-reported telemetry included load-cell ADC saturation represented by a
non-finite reading and lines with doubled spaces after invalid values; these are
reported hardware/firmware observations, not independently captured here.
Previously, lowercase `nan` parsed as `null`, while uppercase `NaN` and
`Infinity` became non-finite doubles and could make JSON snapshot encoding fail.
They now all produce the same `null` channel value while preserving keys and
valid readings.
