#!/usr/bin/env bash
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
sudo safaridriver --enable

sudo install -d -m 0755 /usr/local/lib
guest_agent_path=$(realpath /opt/homebrew/bin/tart-guest-agent)

grant_tcc() {
  sudo sqlite3 "$1" <<SQL
INSERT OR REPLACE INTO access (
  service, client_type, client, auth_value, auth_reason, auth_version,
  indirect_object_identifier_type, indirect_object_identifier
) VALUES
('kTCCServiceAccessibility', 1, '/usr/libexec/sshd-keygen-wrapper', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServiceScreenCapture', 1, '/usr/libexec/sshd-keygen-wrapper', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServicePostEvent', 1, '/usr/libexec/sshd-keygen-wrapper', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServiceAppleEvents', 1, '/usr/libexec/sshd-keygen-wrapper', 2, 0, 1, 0, 'com.apple.systemevents'),
('kTCCServiceAppleEvents', 1, '/usr/libexec/sshd-keygen-wrapper', 2, 0, 1, 0, 'com.apple.Safari'),
('kTCCServiceAccessibility', 1, '/usr/bin/osascript', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServiceScreenCapture', 1, '/usr/bin/osascript', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServicePostEvent', 1, '/usr/bin/osascript', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServiceAppleEvents', 1, '/usr/bin/osascript', 2, 0, 1, 0, 'com.apple.systemevents'),
('kTCCServiceAppleEvents', 1, '/usr/bin/osascript', 2, 0, 1, 0, 'com.apple.Safari'),
('kTCCServiceAccessibility', 1, '$guest_agent_path', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServiceScreenCapture', 1, '$guest_agent_path', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServiceMicrophone', 1, '$guest_agent_path', 2, 0, 1, NULL, 'UNUSED'),
('kTCCServicePostEvent', 1, '$guest_agent_path', 2, 0, 1, NULL, 'UNUSED');
SQL
}

user_tcc=$(bash /tmp/macos-image-user-tcc-database.sh)
grant_tcc "/Library/Application Support/com.apple.TCC/TCC.db"
grant_tcc "$user_tcc"
