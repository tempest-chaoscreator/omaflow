.pragma library

function flavorText(mode, temp) {
  var t = Number(temp)
  if (isFinite(t) && t >= 88) return "Need a medkit"
  if (isFinite(t) && t >= 80) return "I'm on fire"
  var name = String(mode || "").replace(/^\s+|\s+$/g, "").toLowerCase()
  if (name === "silent") return "Silencer on"
  if (name === "static" || name === "fixed") return "Camping A"
  if (name === "performance") return "Rocket jump"
  if (name === "hell") return "Quad damage"
  if (name === "custom" || name) return "sv_cheats 1"
  return "Frag limit"
}
