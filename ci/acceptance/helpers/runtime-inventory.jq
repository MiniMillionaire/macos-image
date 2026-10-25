def runtime_id:
  "com.apple.CoreSimulator.SimRuntime." +
  (if .platform == "visionOS" then "xrOS" else .platform end) + "-" + (.version | gsub("\\."; "-"));

.runtimes as $available |
[$images[0][]] as $installed |
$requirements[0].runtimes as $expected |
if ($expected | length) == 0 or ($installed | length) != ($expected | length) or ($available | length) != ($expected | length) then
  error("Unexpected or duplicate simulator runtime installations")
else
  [$expected[] |
    . as $expected_runtime | runtime_id as $identifier |
    [$installed[] | select(.runtimeIdentifier == $identifier and .build == $expected_runtime.build)] as $matches |
    [$available[] | select(.identifier == $identifier and .buildversion == $expected_runtime.build)] as $runtimes |
    if ($matches | length) != 1 or ($runtimes | length) != 1 then
      error("Missing or duplicate simulator runtime: " + $identifier)
    elif $matches[0].state != "Ready" or $matches[0].version != $expected_runtime.version or
      $runtimes[0].isAvailable != true or $runtimes[0].version != $expected_runtime.version or
      ($runtimes[0].bundlePath | type) != "string" or ($runtimes[0].bundlePath | startswith("/")) != true then
      error("Simulator runtime is not available: " + $identifier)
    else
      {identifier:$identifier,build:$expected_runtime.build,version:$expected_runtime.version,
       kind:$matches[0].kind,bundlePath:$runtimes[0].bundlePath}
    end] | sort_by(.identifier)
end
