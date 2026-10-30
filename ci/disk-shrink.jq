def valid_disk_shrink:
  .version == 1 and .reserveBytes == 8589934592 and .stepBytes == 10000000000 and
  (.minimumBytes | type == "number" and . > 0 and . == floor) and
  .targetBytes == (((.minimumBytes + .reserveBytes) / .stepBytes | ceil) * .stepBytes) and
  .afterBytes == ((.targetBytes / 4096 | ceil) * 4096) and
  (.beforeBytes | type == "number") and .beforeBytes >= .afterBytes and
  (.diskState | type == "string" and length > 0);
