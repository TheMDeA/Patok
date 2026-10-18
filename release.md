# Patok v1.0.3

Fixes the zoomed-in experience: the sharp-detail renderer, scale bar,
and UTM grid were all reading a frozen camera position.

## What's new
- "Open with Patok": import a PDF shared from another app (e.g. WhatsApp)
  straight into the library
- Library cards now show a thumbnail preview of each map
- Update downloads resume after a dropped connection instead of
  restarting from zero
- Sharp detail rendering now engages when zoomed in (previously never
  triggered due to the stale camera reading)
- Scale bar shows the correct distance at every zoom
- UTM grid spacing follows the actual visible area
- GPS status details tidied onto a single line
