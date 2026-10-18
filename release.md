# Patok v1.0.3

Fixes the zoomed-in experience: the sharp-detail renderer, scale bar,
and UTM grid were all reading a frozen camera position.

## What's new
- Sharp detail rendering now engages when zoomed in (previously never
  triggered due to the stale camera reading)
- Scale bar shows the correct distance at every zoom
- UTM grid spacing follows the actual visible area
- GPS status details tidied onto a single line
