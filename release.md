# Patok v1.0.4

Faster sharp-detail rendering when zoomed in.

## What's new
- Detail rendering is faster: the PDF stays open between renders instead
  of being re-parsed every time, pages render in parallel, and rapid
  pans settle briefly before re-rendering
