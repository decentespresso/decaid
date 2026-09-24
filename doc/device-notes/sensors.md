# Sensor Device Notes

## DiFluid R2

DiFluid R2 reflectometers are matched separately from DiFluid scales by
advertised name and the R2 BLE service UUID, then exposed through the standard
`Sensor` abstraction.

After connection, skins can call the existing Sensors API `measure` command and
read TDS, temperature, refractive index, and status values from the sensor data
stream.
