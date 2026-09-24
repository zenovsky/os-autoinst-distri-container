# openQA test
#
# Summary: OpenSSH (Server) — installation, configuration, service restart,
# system reboot, package update.
# Source:
# Paired module: ssh_client.pm — runs on a second machine in the same
# job group:
# TEST=openssh
use Mojo::Base 'basetest';
use testapi;
use lockapi;
use mmapi;
use utils;
use network::ssh;

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

sub run {
    barrier_create "net_ready", 2;
    barrier_create "user_ready", 2;
    barrier_create "package_ready", 2;
    barrier_create "client_key_installed", 2;
    barrier_create "client_key_checks_done", 2;
    barrier_create "server_sshd_restarted", 2;
    barrier_create "server_rebooted", 2;
    barrier_create "client_post_reboot_done", 2;
    barrier_create "server_updated", 2;
    barrier_create "client_final_checks_done", 2;

    # --- Preconditions ---
    ssh_precondition_network_server();
    barrier_wait "net_ready";

    assert_script_run "ping -c 4 $client_ip";
    
    ssh_precondition_user();
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

    # wait for the client to install the public key (steps 11-13)
    barrier_wait "client_key_installed";

    # We wait until the client checks the login using the correct/incorrect key (steps 14-15)
    barrier_wait "client_key_checks_done";

    # --- Step 16: Restart the sshd service ---
    ssh_restart_service();
    barrier_wait "server_sshd_restarted";

    # --- Step 18: Server reboot ---
    # --- Step 19: Service is active after reboot ---
    ssh_reboot_and_login();
    barrier_wait "server_rebooted";

    # waiting for the client to complete the SSH check after the system reboot (step 20))
    barrier_wait "client_post_reboot_done";

    # --- Step 21: checking/installing the package update ---
    # --- Step 22: Service active after update ---
    ssh_update_package();
    barrier_wait "server_updated";

    # waiting for the client to complete the SSH check after the openssh update (step 23))
    barrier_wait "client_final_checks_done";

    # --- Step 27: Checking logs for errors ---
    ssh_check_journal();

    # --- Step 28: General status of the OS ---
    ssh_check_os_status();
}

sub test_flags {
    return {fatal => 1, milestone => 0};
}

1;