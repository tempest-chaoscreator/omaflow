// Paths outside qml/. Quickshell turns a ".." URL into a black hole, so the
// repo root is taken from this file's own URL.

function strip(url) {
  var text = String(url || "")
  if (text.indexOf("file://") === 0) text = text.substring(7)
  try { text = decodeURIComponent(text) } catch (e) {}
  return text
}

function rootFile(relative) {
  var here = strip(Qt.resolvedUrl("RepoPath.js"))
  var cut = here.lastIndexOf("/qml/")
  var root = cut >= 0 ? here.substring(0, cut) : here
  return root + "/" + relative
}
