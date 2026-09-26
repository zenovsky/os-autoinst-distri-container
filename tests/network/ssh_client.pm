# openQA test
# Summary: OpenSSH (Client) — installation, password/key authentication,
# check for invalid key login restrictions, checks after
# service restarts, system reboots, and package updates.
# Source:
# Paired module: ssh_server.pm — runs on a second machine in the same
# job group:
# TEST=openssh
use Mojo::Base 'basetest';
use testapi;
use lockapi;
use mmapi;
use StepReport;

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

sub run {
    add_step_secret($test_pass);

    # --- Preconditions ---
    step 'P1. Network setup' => sub {
        run_cmd "Adding static connection ens4-static ($client_ip/15, gateway 172.16.2.2, DNS $dns_ip)" =>
          "nmcli con add type ethernet ifname ens4 con-name ens4-static "
          . "ipv4.addresses $client_ip/15 ipv4.gateway 172.16.2.2 "
          . "ipv4.dns $dns_ip ipv4.method manual";
        run_cmd "Activating connection ens4-static" => "nmcli con up ens4-static";
        run_cmd "Setting nameserver $dns_ip in /etc/resolv.conf" => "echo 'nameserver $dns_ip' > /etc/resolv.conf";
    };
    barrier_wait "net_ready";

    step 'P2. Ping server' => sub {
        run_cmd "Checking connectivity to the server $server_ip (4 ICMP echo requests)" => "ping -c 4 $server_ip";
    };

    barrier_wait "user_ready";

    # --- Step 1: Install the package ---
    step 'S01. Install the package' => sub {
        run_cmd "Installing the openssh package with dnf" => "dnf install -y openssh", timeout => 300;
    };

    # --- Step 2: sshd configuration ---
    step 'S02. sshd configuration' => sub {
        run_cmd "Checking that the effective sshd configuration uses port 22" => "sshd -T | grep 'port 22'";
    };

    # --- Step 3: Start the service ---
    step 'S03. Start the service' => sub {
        run_cmd "Starting the sshd service" => "systemctl start sshd";
        run_cmd "Checking that the sshd service is active" => "systemctl is-active sshd";
    };

    # --- Step 4: Autoload ---
    step 'S04. Autoload' => sub {
        run_cmd "Enabling the sshd service at boot and starting it now" => "systemctl enable --now sshd";
        run_cmd "Checking that the sshd service is enabled" => "systemctl is-enabled sshd";
    };

    # --- Step 5: Listening port ---
    step 'S05. Listening port' => sub {
        run_cmd "Checking that something listens on TCP port 22" => "ss -lntp | grep ':22'";
    };

    # --- Step 6: firewalld ---
    step 'S06. firewalld' => sub {
        run_cmd "Checking that firewalld allows the ssh service" => "firewall-cmd --list-services | grep 'ssh'";
    };
    barrier_wait "package_ready";

    # --- Step 7: Make sure port 22 is available on the server---
    step 'S07. Port 22 is available on the server' => sub {
        run_cmd "Scanning $server_ip:22 and looking for the OpenSSH banner" =>
          "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";
    };

    # --- Steps 8-10: Connecting with a password ---
    step 'S08-10. Connect with a password' => sub {
        step_log "Opening an SSH session to $test_user\@$server_ip";
        type_string "ssh -o StrictHostKeyChecking=no $test_user\@$server_ip\n";
        step_log "Waiting for the password prompt";
        assert_screen 'ssh-password-prompt', 30;
        step_log "Entering the password of $test_user";
        type_string "$test_pass\n";
        wait_still_screen(3);
        step_log "Running whoami and expecting $test_user";
        type_string "whoami\n";
        assert_screen 'whoami-is-test-user', 30;
        step_log "Printing \$HOME and expecting the home directory of $test_user";
        type_string "echo \"\$HOME\"\n";
        assert_screen 'home-is-test-user-dir', 30;
        step_log "Closing the SSH session";
        enter_cmd 'exit';
    };

    # --- Step 11: Generate a key ---
    step 'S11. Generate a key' => sub {
        run_cmd "Generating an ed25519 key pair ~/.ssh/id_ed25519_test without a passphrase" =>
          "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_test -N ''";
        run_cmd "Checking that the private and public key files exist" =>
          "ls -l ~/.ssh/id_ed25519_test ~/.ssh/id_ed25519_test.pub";
    };

    # --- Steps 12-13: Installing the public key on the server ---
    step 'S12-13. Install the public key on the server' => sub {
        step_log "Copying the public key to $test_user\@$server_ip with ssh-copy-id";
        type_string "ssh-copy-id -i ~/.ssh/id_ed25519_test.pub $test_user\@$server_ip\n";
        step_log "Waiting for the password prompt";
        assert_screen 'ssh-password-prompt', 30;
        step_log "Entering the password of $test_user";
        type_string "$test_pass\n";
        wait_still_screen(3);
    };
    barrier_wait "client_key_installed";

    # --- Step 14: Connecting via Public Key ---
    step 'S14. Connect with the public key' => sub {
        run_cmd "Logging in to $test_user\@$server_ip with the key (password authentication disabled) and running whoami" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'whoami'";
    };

    # --- Step 15: Connection with an invalid key should be rejected ---
    step 'S15. Invalid key is rejected' => sub {
        run_cmd "Generating a second key pair that is not installed on the server" =>
          "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wrong -N ''";
        run_cmd "Trying to log in with the wrong key and expecting 'Permission denied'" =>
          "ssh -i ~/.ssh/id_ed25519_wrong -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 2>&1 | grep -i 'Permission denied'";
    };
    barrier_wait "client_key_checks_done";

    # We wait for the server to restart sshd (step 16).
    barrier_wait "server_sshd_restarted";

    # --- Step 17: Verifying SSH after restarting the service ---
    step 'S17. SSH works after the service restart' => sub {
        run_cmd "Logging in with the key after the sshd restart on the server" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK'";
    };
    barrier_wait "server_rebooted";

    # --- Step 20: Verifying SSH after system reboot ---
    step 'S20. SSH works after the system reboot' => sub {
        run_cmd "Logging in with the key after the server reboot" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_REBOOT'";
    };
    barrier_wait "client_post_reboot_done";

    # We wait for the server to update sshd (step 21).
    barrier_wait "server_updated";

    # ---- Step 23: SSH session after package update on the server ---
    step 'S23. SSH works after the package update' => sub {
        run_cmd "Logging in with the key after the openssh update on the server" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_UPDATE'";
    };
    barrier_wait "client_final_checks_done";
}

# Отчёт пишется и при успехе, и при падении.
sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
sub post_run_hook  { write_step_report('ssh_client') }

1;

# # openQA test
# # Summary: OpenSSH (Client) — installation, password/key authentication,
# # check for invalid key login restrictions, checks after
# # service restarts, system reboots, and package updates.
# # Source:
# # Paired module: ssh_server.pm — runs on a second machine in the same
# # job group:
# # TEST=openssh
# use Mojo::Base 'basetest';
# use testapi;
# use lockapi;
# use mmapi;
# use StepReport;

# my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
# my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
# my $dns_ip = get_var('DNS_IP');

# my $test_user = get_var('SSH_USER', 'ssh_test_user');
# my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

# sub run {
#     add_step_secret($test_pass);
 
#     # --- Preconditions ---
#     step 'P1. Network setup' => sub {
#         step_log "Adding static connection ens4-static ($client_ip/15, gateway 172.16.2.2, DNS $dns_ip)";
#         assert_script_run "nmcli con add type ethernet ifname ens4 con-name ens4-static "
#           . "ipv4.addresses $client_ip/15 ipv4.gateway 172.16.2.2 "
#           . "ipv4.dns $dns_ip ipv4.method manual";
#         step_log "Activating connection ens4-static";
#         assert_script_run "nmcli con up ens4-static";
#         step_log "Setting nameserver $dns_ip in /etc/resolv.conf";
#         assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";
#     };
#     barrier_wait "net_ready";
 
#     step 'P2. Ping server' => sub {
#         step_log "Checking connectivity to the server $server_ip (4 ICMP echo requests)";
#         assert_script_run "ping -c 4 $server_ip";
#     };
 
#     barrier_wait "user_ready";

#         # --- Step 1: Install the package ---
#     step 'S01. Install the package' => sub {
#         step_log "Installing the openssh package with dnf";
#         assert_script_run "dnf install -y openssh";
#     };
 
#     # --- Step 2: sshd configuration ---
#     step 'S02. sshd configuration' => sub {
#         step_log "Checking that the effective sshd configuration uses port 22";
#         assert_script_run "sshd -T | grep 'port 22'";
#     };
 
#     # --- Step 3: Start the service ---
#     step 'S03. Start the service' => sub {
#         step_log "Starting the sshd service";
#         assert_script_run "systemctl start sshd";
#         step_log "Checking that the sshd service is active";
#         assert_script_run "systemctl is-active sshd";
#     };
 
#     # --- Step 4: Autoload ---
#     step 'S04. Autoload' => sub {
#         step_log "Enabling the sshd service at boot and starting it now";
#         assert_script_run "systemctl enable --now sshd";
#         step_log "Checking that the sshd service is enabled";
#         assert_script_run "systemctl is-enabled sshd";
#     };
 
#     # --- Step 5: Listening port ---
#     step 'S05. Listening port' => sub {
#         step_log "Checking that something listens on TCP port 22";
#         assert_script_run "ss -lntp | grep ':22'";
#     };
 
#     # --- Step 6: firewalld ---
#     step 'S06. firewalld' => sub {
#         step_log "Checking that firewalld allows the ssh service";
#         assert_script_run "firewall-cmd --list-services | grep 'ssh'";
#     };
#     barrier_wait "package_ready";
 
#     # --- Step 7: Make sure port 22 is available on the server---
#     step 'S07. Port 22 is available on the server' => sub {
#         step_log "Scanning $server_ip:22 and looking for the OpenSSH banner";
#         assert_script_run "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";
#     };
 
#     # --- Steps 8-10: Connecting with a password ---
#     step 'S08-10. Connect with a password' => sub {
#         step_log "Opening an SSH session to $test_user\@$server_ip";
#         type_string "ssh -o StrictHostKeyChecking=no $test_user\@$server_ip\n";
#         step_log "Waiting for the password prompt";
#         assert_screen 'ssh-password-prompt', 30;
#         step_log "Entering the password of $test_user";
#         type_string "$test_pass\n";
#         wait_still_screen(3);
#         step_log "Running whoami and expecting $test_user";
#         type_string "whoami\n";
#         assert_screen 'whoami-is-test-user', 30;
#         step_log "Printing \$HOME and expecting the home directory of $test_user";
#         type_string "echo \"\$HOME\"\n";
#         assert_screen 'home-is-test-user-dir', 30;
#         step_log "Closing the SSH session";
#         enter_cmd 'exit';
#     };
 
#     # --- Step 11: Generate a key ---
#     step 'S11. Generate a key' => sub {
#         step_log "Generating an ed25519 key pair ~/.ssh/id_ed25519_test without a passphrase";
#         assert_script_run "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_test -N ''";
#         step_log "Checking that the private and public key files exist";
#         assert_script_run "ls -l ~/.ssh/id_ed25519_test ~/.ssh/id_ed25519_test.pub";
#     };
 
#     # --- Steps 12-13: Installing the public key on the server ---
#     step 'S12-13. Install the public key on the server' => sub {
#         step_log "Copying the public key to $test_user\@$server_ip with ssh-copy-id";
#         type_string "ssh-copy-id -i ~/.ssh/id_ed25519_test.pub $test_user\@$server_ip\n";
#         step_log "Waiting for the password prompt";
#         assert_screen 'ssh-password-prompt', 30;
#         step_log "Entering the password of $test_user";
#         type_string "$test_pass\n";
#         wait_still_screen(3);
#     };
#     barrier_wait "client_key_installed";
 
#     # --- Step 14: Connecting via Public Key ---
#     step 'S14. Connect with the public key' => sub {
#         step_log "Logging in to $test_user\@$server_ip with the key (password authentication disabled) and running whoami";
#         assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#           . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'whoami'";
#     };
 
#     # --- Step 15: Connection with an invalid key should be rejected ---
#     step 'S15. Invalid key is rejected' => sub {
#         step_log "Generating a second key pair that is not installed on the server";
#         assert_script_run "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wrong -N ''";
#         step_log "Trying to log in with the wrong key and expecting 'Permission denied'";
#         assert_script_run "ssh -i ~/.ssh/id_ed25519_wrong -o PasswordAuthentication=no "
#           . "-o StrictHostKeyChecking=no $test_user\@$server_ip 2>&1 | grep -i 'Permission denied'";
#     };
#     barrier_wait "client_key_checks_done";
 
#     # We wait for the server to restart sshd (step 16).
#     barrier_wait "server_sshd_restarted";
 
#     # --- Step 17: Verifying SSH after restarting the service ---
#     step 'S17. SSH works after the service restart' => sub {
#         step_log "Logging in with the key after the sshd restart on the server";
#         assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#           . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK'";
#     };
#     barrier_wait "server_rebooted";
 
#     # --- Step 20: Verifying SSH after system reboot ---
#     step 'S20. SSH works after the system reboot' => sub {
#         step_log "Logging in with the key after the server reboot";
#         assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#           . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_REBOOT'";
#     };
#     barrier_wait "client_post_reboot_done";
 
#     # We wait for the server to update sshd (step 21).
#     barrier_wait "server_updated";
 
#     # ---- Step 23: SSH session after package update on the server ---
#     step 'S23. SSH works after the package update' => sub {
#         step_log "Logging in with the key after the openssh update on the server";
#         assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#           . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_UPDATE'";
#     };
#     barrier_wait "client_final_checks_done";
    
# }
 
# # Отчёт пишется и при успехе, и при падении.
# sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
# sub post_run_hook  { write_step_report('ssh_client') }
 
# 1;

# sub run {
#     record_info "PRECONDITION";
#     # --- Preconditions ---
#     assert_script_run "nmcli con add type ethernet ifname ens4 con-name ens4-static "
#       . "ipv4.addresses $client_ip/15 ipv4.gateway 172.16.2.2 "
#       . "ipv4.dns $dns_ip ipv4.method manual";
#     assert_script_run "nmcli con up ens4-static";
#     assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";
#     barrier_wait "net_ready";

#     assert_script_run "ping -c 4 $server_ip";

#     barrier_wait "user_ready";

#     # # --- Step 1: Install the package ---
#     # assert_script_run "dnf install -y openssh";

#     # --- Step 2: sshd configuration ---
#     assert_script_run "sshd -T | grep 'port 22'";

#     # --- Step 3: Start the service ---
#     assert_script_run "systemctl start sshd";
#     assert_script_run "systemctl is-active sshd";

#     # --- Step 4: Autoload ---
#     assert_script_run "systemctl enable --now sshd";
#     assert_script_run "systemctl is-enabled sshd";

#     # --- Step 5: Listening port ---
#     assert_script_run "ss -lntp | grep ':22'";

#     # --- Step 6: firewalld ---
#     assert_script_run "firewall-cmd --list-services | grep 'ssh'";
#     barrier_wait "package_ready";

#     # --- Step 7: Make sure port 22 is available on the server---
#     assert_script_run "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";

#     # --- Steps 8-10: Connecting with a password ---
#     type_string "ssh -o StrictHostKeyChecking=no $test_user\@$server_ip\n";
#     assert_screen 'ssh-password-prompt', 30;
#     type_string "$test_pass\n";
#     wait_still_screen(3);
#     type_string "whoami\n";
#     assert_screen 'whoami-is-test-user', 30;
#     type_string "echo \"\$HOME\"\n";
#     assert_screen 'home-is-test-user-dir', 30;
#     enter_cmd 'exit';

#     # --- Step 11: Generate a key ---
#     assert_script_run "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_test -N ''";
#     assert_script_run "ls -l ~/.ssh/id_ed25519_test ~/.ssh/id_ed25519_test.pub";

#     # --- Steps 12-13: Installing the public key on the server ---
#     type_string "ssh-copy-id -i ~/.ssh/id_ed25519_test.pub $test_user\@$server_ip\n";
#     assert_screen 'ssh-password-prompt', 30;
#     type_string "$test_pass\n";
#     wait_still_screen(3);
#     barrier_wait "client_key_installed";

#     # --- Step 14: Connecting via Public Key ---
#     assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#       . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'whoami'";

#     # # --- Step 15: Connection with an invalid key should be rejected ---
#     assert_script_run "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wrong -N ''";
#     assert_script_run "ssh -i ~/.ssh/id_ed25519_wrong -o PasswordAuthentication=no "
#       . "-o StrictHostKeyChecking=no $test_user\@$server_ip 2>&1 | grep -i 'Permission denied'";
#     barrier_wait "client_key_checks_done";

#     # We wait for the server to restart sshd (step 16).
#     barrier_wait "server_sshd_restarted";

#     # --- Step 17: Verifying SSH after restarting the service ---
#     assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#       . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK'";
#     barrier_wait "server_rebooted";

#     # --- Step 20: Verifying SSH after system reboot ---
#     assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#       . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_REBOOT'";
#     barrier_wait "client_post_reboot_done";

#     # We wait for the server to update sshd (step 21).
#     barrier_wait "server_updated";

#     # ---- Step 23: SSH session after package update on the server ---
#     assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
#       . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_UPDATE'";
#     barrier_wait "client_final_checks_done";
# }

# sub test_flags {
#     return {fatal => 1, milestone => 0};
# }

# 1;