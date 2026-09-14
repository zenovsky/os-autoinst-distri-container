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

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');

my $root_password = get_var('ROOT_PASSWORD', '12345678');

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
    assert_script_run "nmcli con add type ethernet ifname ens4 con-name ens4-static "
        . "ipv4.addresses $server_ip/15 ipv4.gateway 172.16.2.2 "
        . "ipv4.dns $dns_ip ipv4.method manual";
    assert_script_run "nmcli con up ens4-static";
    assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";
    barrier_wait "net_ready";

    assert_script_run "ping -c 4 $client_ip";
    
    assert_script_run "useradd -m -s /bin/bash $test_user";
    assert_script_run "echo '$test_user:$test_pass' | chpasswd";
    assert_script_run "chmod 777 /dev/ttyS0";
    barrier_wait "user_ready";

    # # --- Step 1: Install the package ---
    # assert_script_run "dnf install -y openssh";

    # --- Step 2: sshd configuration ---
    assert_script_run "sshd -T | grep 'port 22'";

    # --- Step 3: Start the service ---
    assert_script_run "systemctl start sshd";
    assert_script_run "systemctl is-active sshd";

    # --- Step 4: Autoload ---
    assert_script_run "systemctl enable --now sshd";
    assert_script_run "systemctl is-enabled sshd";

    # --- Step 5: Listening port ---
    assert_script_run "ss -lntp | grep ':22'";

    # --- Step 6: firewalld ---
    assert_script_run "firewall-cmd --list-services | grep 'ssh'";
    barrier_wait "package_ready";

    # wait for the client to install the public key (steps 11-13)
    barrier_wait "client_key_installed";

    # We wait until the client checks the login using the correct/incorrect key (steps 14-15)
    barrier_wait "client_key_checks_done";

    # --- Step 16: Restart the sshd service ---
    assert_script_run "systemctl restart sshd";
    assert_script_run "systemctl is-active sshd";
    barrier_wait "server_sshd_restarted";

    # --- Step 18: Server reboot ---
    enter_cmd "reboot";
    wait_still_screen(15);
    assert_screen 'console-root', 720;
    type_string 'root';
    send_key 'ret';
    wait_still_screen(3);
    type_string $root_password;
    send_key 'ret';
    assert_screen 'console-root-access', 720;

    # --- Step 19: Service is active after reboot ---
    assert_script_run "systemctl is-active sshd";
    barrier_wait "server_rebooted";

    # waiting for the client to complete the SSH check after the system reboot (step 20))
    barrier_wait "client_post_reboot_done";

    # --- Step 21: checking/installing the package update ---
    my $rc = script_run "dnf check-update openssh";
    if ($rc == 100) {
        # 100 = есть доступные обновления
        assert_script_run "dnf update -y openssh", timeout => 300;
    }
    elsif ($rc != 0) {
        die "dnf check-update failed with code $rc";
    }

    # --- Step 22: Service active after update ---
    assert_script_run "systemctl is-active sshd";
    barrier_wait "server_updated";

    # waiting for the client to complete the SSH check after the openssh update (step 23))
    barrier_wait "client_final_checks_done";

    # --- Step 27: Checking logs for errors ---
    my $logs = script_output "journalctl -u sshd --no-pager -n 100";
    die "sshd logs contain errors:\n$logs"
      if $logs =~ /Failed|fatal|error/i;

    # --- Step 28: General status of the OS ---
    assert_script_run "rpm -V openssh";
    assert_script_run "dnf check";
    assert_script_run "getenforce | grep 'Enforcing'";
    assert_script_run "ss -lntp | grep ':22'";
    assert_script_run "cat /proc/cmdline";
    assert_script_run "systemctl --failed | grep '0 loaded units listed'";
}

sub test_flags {
    return {fatal => 1, milestone => 0};
}

1;