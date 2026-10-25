  [.[]] as $installed |
  [$installed[] | . as $image |
    [$requirements[0].runtimes[] |
      ("com.apple.CoreSimulator.SimRuntime." + (if .platform == "visionOS" then "xrOS" else .platform end) +
      "-" + (.version | gsub("\\."; "-"))) as $identifier |
      select($identifier == $image.runtimeIdentifier and .build == $image.build and .version == $image.version)] as $expected |
    select(.kind == "Legacy Download" or .state != "Ready" or ($expected | length) != 1 or
      ([$installed[] | select(.runtimeIdentifier == $image.runtimeIdentifier)] | length) != 1)] |
  if all(.[]; .deletable == true) then . else error("Cannot replace a simulator runtime") end
