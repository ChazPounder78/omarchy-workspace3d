.pragma library

// 4x4 transforms as flat row-major arrays of 16 numbers, column-vector
// convention (p' = M * p) so they drop straight into QML's Matrix4x4.
// mul(a, b) composes so that b applies to the point first.

function identity() {
  return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
}

function mul(a, b) {
  var out = new Array(16)
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      var sum = 0
      for (var k = 0; k < 4; k++) sum += a[r * 4 + k] * b[k * 4 + c]
      out[r * 4 + c] = sum
    }
  }
  return out
}

function translate(x, y, z) {
  return [1, 0, 0, x, 0, 1, 0, y, 0, 0, 1, z, 0, 0, 0, 1]
}

function scaleXY(s) {
  return [s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
}

function rotX(deg) {
  var a = deg * Math.PI / 180
  var c = Math.cos(a)
  var s = Math.sin(a)
  return [1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1]
}

function rotY(deg) {
  var a = deg * Math.PI / 180
  var c = Math.cos(a)
  var s = Math.sin(a)
  return [c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1]
}

// Row 2 scales clip.z down to 1/(20*d): the geometry transform lifts z by up
// to a full screen width, and clip.z must stay within +/- clip.w or the GPU
// depth-clips the page away entirely. Qt Quick has depth testing off, so a
// tiny monotonic z is all that is needed. Row 3 keeps the perspective divide.
function perspective(d) {
  var e = 1 / (20 * d)
  return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, e, 0, 0, 0, -1 / d, 1]
}

// Geometry transform for the outgoing page. dir is +1 when moving to a
// higher workspace, -1 when moving to a lower one.
//
// flip: the page pivots on its trailing vertical edge and swings its leading
// edge toward the viewer, like turning a page.
//
// flythrough: the page rushes at the camera with a slight tilt and lateral
// drift, growing until it passes the viewpoint.
//
// coverflow: the page rotates near its center while sliding and shrinking
// aside, like a cover on a shelf.
function geometry(style, dir, t, w, h) {
  var cx = w / 2
  var cy = h / 2

  if (style === "flythrough") {
    var d = Math.max(1, w * 1.1)
    // Cap the approach well short of the projection plane (w' = 1 - z/d > 0)
    // so overshooting easings and the tilt can never push vertices through
    // the camera; 0.5*d still gives a 2x zoom.
    var z = Math.min(0.5 * d, 0.55 * d * t)
    var tilt = -8 * dir * t
    var drift = -0.10 * dir * w * t
    return mul(translate(drift, 0, z),
        mul(translate(cx, cy, 0), mul(rotX(tilt), translate(-cx, -cy, 0))))
  }

  if (style === "coverflow") {
    var ang = -50 * dir * t
    var tx = -0.35 * dir * w * t
    var sc = Math.max(0.2, 1 - 0.12 * t)
    return mul(translate(tx, 0, 0),
        mul(translate(cx, cy, 0),
          mul(scaleXY(sc), mul(rotY(ang), translate(-cx, -cy, 0)))))
  }

  var px = dir >= 0 ? 0 : w
  var flipAng = -90 * dir * t
  return mul(translate(px, cy, 0), mul(rotY(flipAng), translate(-px, -cy, 0)))
}

// Full item transform: geometry, then a perspective projection whose camera
// sits at the center of the surface (d ~= 1.1 * width gives a ~48 degree
// field of view). t may overshoot slightly (OutBack etc.) and is clamped.
function build(style, dir, t, w, h) {
  if (w <= 0 || h <= 0) return identity()
  var clamped = Math.max(-0.1, Math.min(1.1, t))
  var d = Math.max(1, w * 1.1)
  var cx = w / 2
  var cy = h / 2
  var g = geometry(style, dir, clamped, w, h)
  var proj = mul(translate(cx, cy, 0), mul(perspective(d), translate(-cx, -cy, 0)))
  return mul(proj, g)
}

function pageOpacity(style, t) {
  var tt = Math.max(0, Math.min(1, t))
  var fadeStart = style === "flythrough" ? 0.35 : 0.5
  if (tt <= fadeStart) return 1
  return Math.max(0, 1 - (tt - fadeStart) / (1 - fadeStart))
}

function shadowOpacity(style, t) {
  if (style === "flythrough") return 0
  var tt = Math.max(0, Math.min(1, t))
  return 0.4 * tt
}
