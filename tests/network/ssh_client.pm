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
    step 'Preconditions. Network setup' => sub {
        run_cmd "Adding static connection ens4-static ($client_ip/15, gateway 172.16.2.2, DNS $dns_ip)" =>
          "nmcli con add type ethernet ifname ens4 con-name ens4-static "
          . "ipv4.addresses $client_ip/15 ipv4.gateway 172.16.2.2 "
          . "ipv4.dns $dns_ip ipv4.method manual";
        run_cmd "Activating connection ens4-static" => "nmcli con up ens4-static";
        run_cmd "Setting nameserver $dns_ip in /etc/resolv.conf" => "echo 'nameserver $dns_ip' > /etc/resolv.conf";
    };

    barrier_wait "net_ready";

    step 'Preconditions. Ping server' => sub {
        run_cmd "Checking connectivity to the server $server_ip (4 ICMP echo requests)" => "ping -c 4 $server_ip";
    };

    barrier_wait "user_ready";

    # --- Step 1: Install the package opennsh ---
    step 'Step 1. Install the package openssh' => sub {
        run_cmd "Installing the openssh package with dnf" => "dnf install -y openssh", timeout => 300, quiet => 1;
    };

    # --- Step 2: sshd port configuration ---
    step 'Step 2. sshd port configuration' => sub {
        run_cmd "Checking that the effective sshd configuration uses port 22" => "sshd -T | grep 'port 22'";
    };

    # --- Step 3: Start the service ---
    step 'Step 3. Start the service' => sub {
        run_cmd "Starting the sshd service" => "systemctl start sshd";
        run_cmd "Checking that the sshd service is active" => "systemctl is-active sshd";
    };

    # --- Step 4: Enable sshd autostart ---
    step 'Step 4. Enable sshd autostart' => sub {
        run_cmd "Enabling the sshd service at boot and starting it now" => "systemctl enable --now sshd";
        run_cmd "Checking that the sshd service is enabled" => "systemctl is-enabled sshd";
    };

    # --- Step 5: sshd listens on port 22 ---
    step 'Step 5. sshd listens on port 22' => sub {
        run_cmd "Checking that something listens on TCP port 22" => "ss -lntp | grep ':22'";
    };

    # --- Step 6: Firewall allows ss ---
    step 'Step 6. Firewall allows ss' => sub {
        run_cmd "Checking that firewalld allows the ssh service" => "firewall-cmd --list-services | grep 'ssh'";
    };

    barrier_wait "package_ready";

    # --- Step 7: Make sure port 22 is available on the server---
    step 'Step 7. Port 22 is available on the server' => sub {
        run_cmd "Scanning $server_ip:22 and looking for the OpenSSH banner" =>
          "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";
    };

    # --- Step 8: Connecting with a password ---
    step 'Step 8. Password login and whoami/$HOME check' => sub {
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

    # --- Step 9: Generate a key ---
    step 'Step 9. Generate a key' => sub {
        run_cmd "Generating an ed25519 key pair ~/.ssh/id_ed25519_test without a passphrase" =>
          "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_test -N ''";
        run_cmd "Checking that the private and public key files exist" =>
          "ls -l ~/.ssh/id_ed25519_test ~/.ssh/id_ed25519_test.pub";
    };

    # --- Step 10: Installing the public key on the server ---
    step 'Step 10. Install the public key on the server' => sub {
        step_log "Copying the public key to $test_user\@$server_ip with ssh-copy-id";
        type_string "ssh-copy-id -i ~/.ssh/id_ed25519_test.pub $test_user\@$server_ip\n";
        step_log "Waiting for the password prompt";
        assert_screen 'ssh-password-prompt', 30;
        step_log "Entering the password of $test_user";
        type_string "$test_pass\n";
        wait_still_screen(3);
    };

    barrier_wait "client_key_installed";

    # --- Step 11: Key-based login (password auth disabled) ---
    step 'Step 11. Key-based login (password auth disabled)' => sub {
        run_cmd "Logging in to $test_user\@$server_ip with the key (password authentication disabled) and running whoami" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'whoami'";
    };

    # --- Step 12: Connection with an invalid key should be rejected ---
    step 'Step 12. Invalid key is rejected' => sub {
        run_cmd "Generating a second key pair that is not installed on the server" =>
          "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wrong -N ''";
        run_cmd "Trying to log in with the wrong key and expecting 'Permission denied'" =>
          "ssh -i ~/.ssh/id_ed25519_wrong -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 2>&1 | grep -i 'Permission denied'";
    };

    barrier_wait "client_key_checks_done";
    barrier_wait "server_sshd_restarted";

    # --- Step 13: Verifying SSH after restarting the service ---
    step 'Step 13. SSH works after the service restart' => sub {
        run_cmd "Logging in with the key after the sshd restart on the server" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK'";
    };

    barrier_wait "server_rebooted";

    # --- Step 14: Verifying SSH after system reboot ---
    step 'Step 14. SSH works after the system reboot' => sub {
        run_cmd "Logging in with the key after the server reboot" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_REBOOT'";
    };

    barrier_wait "client_post_reboot_done";
    barrier_wait "server_updated";

    # ---- Step 15: SSH session after package update on the server ---
    step 'Step 15. SSH works after the package update' => sub {
        run_cmd "Logging in with the key after the openssh update on the server" =>
          "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
          . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK_AFTER_UPDATE'";
    };

    barrier_wait "client_final_checks_done";
}

sub post_fail_hook { write_step_report('ssh_client', failed => 1) }
sub post_run_hook  { write_step_report('ssh_client') }

1;