def version:
  if type == "string" and test("^(0|[1-9][0-9]*)(\\.(0|[1-9][0-9]*)){0,2}$") then
    split(".") | map(tonumber) | (. + [0, 0, 0])[:3]
  else error("Invalid stable image version") end;

($candidate.os | version) as $next_os |
(.os | version) as $current_os |
if $next_os[0] != $current_os[0] then error("Image alias crosses macOS families")
elif $candidate.xcode != null then
  ($candidate.xcode | version) as $next_xcode |
  (.xcode | version) as $current_xcode |
  if $alias != "latest" and $next_xcode != $current_xcode then
    error("Xcode alias names a different compiler")
  else $next_os >= $current_os and $next_xcode >= $current_xcode end
elif .xcode != null then error("Non-Xcode alias has an Xcode identity")
else $next_os >= $current_os end
