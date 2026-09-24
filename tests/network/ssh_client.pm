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
use network::ssh;

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

sub run {
    # --- Preconditions ---
    ssh_precondition_network_client();
    barrier_wait "net_ready";

    assert_script_run "ping -c 4 $server_ip";

    barrier_wait "user_ready";

    # # --- Step 1: Install the package ---
    # ssh_install_package();

    # --- Step 2: sshd configuration ---
    ssh_check_config();

    # --- Step 3: Start the service ---
    ssh_start_service();

    # --- Step 4: Autoload ---
    ssh_enable_service();

    # --- Step 5: Listening port ---
    ssh_check_listening();

    # --- Step 6: firewalld ---
    ssh_check_firewall();
    barrier_wait "package_ready";

    # --- Step 7: Make sure port 22 is available on the server---
    ssh_check_server_port();

    # --- Steps 8-10: Connecting with a password ---
    ssh_login_password();

    # --- Step 11: Generate a key ---
    ssh_generate_key();

    # --- Steps 12-13: Installing the public key on the server ---
    ssh_copy_key();

    # --- Step 14: Connecting via Public Key ---
    ssh_login_key(command => 'whoami');

    # # --- Step 15: Connection with an invalid key should be rejected ---
    ssh_login_wrong_key_rejected();
    barrier_wait "client_key_checks_done";

    # We wait for the server to restart sshd (step 16).
    barrier_wait "server_sshd_restarted";

    # --- Step 17: Verifying SSH after restarting the service ---
    ssh_login_key(command => 'echo SSH_OK', expect => 'SSH_OK');
    barrier_wait "server_rebooted";

    # --- Step 20: Verifying SSH after system reboot ---
    ssh_login_key(command => 'echo SSH_OK_AFTER_REBOOT', expect => 'SSH_OK_AFTER_REBOOT');
    barrier_wait "client_post_reboot_done";

    # We wait for the server to update sshd (step 21).
    barrier_wait "server_updated";

    # ---- Step 23: SSH session after package update on the server ---
    ssh_login_key(command => 'echo SSH_OK_AFTER_UPDATE', expect => 'SSH_OK_AFTER_UPDATE');
    barrier_wait "client_final_checks_done";
}

sub test_flags {
    return {fatal => 1, milestone => 0};
}

1;