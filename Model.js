.pragma library

// Formatting and grouping for the pending-update panel. Kept out of the QML so
// the shapes here stay testable and the Panel stays layout.

function formatBytes(bytes) {
  if (!bytes || bytes <= 0)
    return ""
  var units = ["B", "KiB", "MiB", "GiB"]
  var value = bytes
  var i = 0
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024
    i++
  }
  return (i === 0 || value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[i]
}

function packageCount(data) {
  if (!data)
    return 0
  var n = (data.packages || []).length + (data.aur || []).length
  return n + (data.omarchy ? 1 : 0)
}

// One line of consequence, for the panel header and the bar tooltip. Size is
// what the update will pull down; count is what it will replace.
function summary(data) {
  if (!data)
    return ""
  var parts = []
  var n = packageCount(data)
  parts.push(n + (n === 1 ? " package" : " packages"))
  var size = formatBytes(data.totalBytes)
  if (size !== "")
    parts.push(size)
  return parts.join(" . ")
}

function needsReboot(data) {
  if (!data)
    return false
  return (data.packages || []).some(function (p) {
    return p.tag === "reboot"
  })
}

// The bar tooltip. Says what is waiting and what clicking will do, because the
// icon alone has never been able to say either.
function tooltip(data, loading) {
  if (loading)
    return "Checking what is pending..."
  if (!data)
    return "Pending Omarchy updates. Click to review."
  if (!data.ok)
    return data.error || "Could not read pending updates."
  var line = summary(data) + " pending"
  if (needsReboot(data))
    line += ", reboot after"
  return line + ". Click to review."
}

// Sections, most consequential first. A package with a tag changes something
// that is currently running; everything else lands quietly on disk.
function sections(data) {
  if (!data || !data.ok)
    return []
  var out = []
  var packages = data.packages || []

  var tagged = packages.filter(function (p) {
    return p.tag
  })
  if (tagged.length > 0)
    out.push({
      title: "NEEDS A RESTART",
      note: "These replace something that is running right now.",
      rows: tagged
    })

  var rest = packages.filter(function (p) {
    return !p.tag
  })
  if (rest.length > 0)
    out.push({
      title: "EVERYTHING ELSE",
      note: "",
      rows: rest
    })

  var aur = (data.aur || []).map(function (p) {
    return {
      name: p.name,
      from: p.from,
      to: p.to,
      repo: "aur",
      bytes: 0,
      tag: ""
    }
  })
  if (aur.length > 0)
    out.push({
      title: "AUR",
      note: "Built on your machine, not downloaded.",
      rows: aur
    })

  return out
}

// Right-hand label on a row. Size when known, otherwise the repo, so a row is
// never blank on the right while its neighbours are filled.
function rowMeta(row) {
  var size = formatBytes(row.bytes)
  if (size !== "")
    return size
  return row.repo || ""
}

function tagLabel(tag) {
  if (tag === "reboot")
    return "reboot"
  if (tag === "restart")
    return "restart"
  return ""
}
