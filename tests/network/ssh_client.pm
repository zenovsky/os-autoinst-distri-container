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

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');
my $keyfile   = get_var('SSH_KEY_PATH', '~/.ssh/id_ed25519_test');

sub run {
    # --- Preconditions ---
    assert_script_run "nmcli con add type ethernet ifname ens4 con-name ens4-static "
      . "ipv4.addresses $client_ip/15 ipv4.gateway 172.16.2.2 "
      . "ipv4.dns $dns_ip ipv4.method manual";
    assert_script_run "nmcli con up ens4-static";
    assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";
    barrier_wait "net_ready";

    assert_script_run "ping -c 4 $server_ip";

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

    # --- Step 7: Make sure port 22 is available on the server---
    assert_script_run "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";

    # --- Steps 8-10: Connecting with a password ---
    type_string "ssh -o StrictHostKeyChecking=no $test_user\@$server_ip\n";
    assert_screen 'ssh-password-prompt', 30;
    type_string "$test_pass\n";
    wait_still_screen(3);
    type_string "whoami\n";
    assert_screen 'whoami-is-test-user', 30;
    type_string "echo \"\$HOME\"\n";
    assert_screen 'home-is-test-user-dir', 30;
    enter_cmd 'exit';

    # --- Step 11: Generate a key ---
    assert_script_run "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_test -N ''";
    assert_script_run "ls -l ~/.ssh/id_ed25519_test ~/.ssh/id_ed25519_test.pub";

    # --- Steps 12-13: Installing the public key on the server ---
    type_string "ssh-copy-id -i ~/.ssh/id_ed25519_test.pub $test_user\@$server_ip\n";
    assert_screen 'ssh-password-prompt', 30;
    type_string "$test_pass\n";
    wait_still_screen(3);
    barrier_wait "client_key_installed";

    # --- Step 14: Connecting via Public Key ---
    assert_script_run "ssh -i ~/.ssh/id_ed25519_test -o PasswordAuthentication=no "
      . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'whoami'";

    # # --- Step 15: Connection with an invalid key should be rejected ---
    assert_script_run "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wrong -N ''";
    assert_script_run "ssh -i ~/.ssh/id_ed25519_wrong -o PasswordAuthentication=no "
      . "-o StrictHostKeyChecking=no $test_user\@$server_ip 2>&1 | grep -i 'Permission denied'";
    barrier_wait "client_key_checks_done";

    # We wait for the server to restart sshd (step 16).
    barrier_wait "server_sshd_restarted";

    # --- Step 17: Verifying SSH after restarting the service ---
    my $ping_rc = script_run("ping -c 3 -W 2 $server_ip");
    script_run "ip link show ens4";
    script_run "ip addr show ens4";
    script_run "ip route";
    script_run "ip neigh show";
    # script_run "nmcli -f NAME,DEVICE,STATE,CONNECTION con show";
    die "ping to $server_ip failed, rc=" . (defined $ping_rc ? $ping_rc : 'undef') unless defined $ping_rc && $ping_rc == 0;

    assert_script_run "ssh -i $keyfile -o PasswordAuthentication=no "
      . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK'";
    # my $ok1 = script_output(
    #     "ssh -i $keyfile -o PasswordAuthentication=no "
    #   . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'echo SSH_OK'");
    # die "SSH check failed after service restart:\n$ok1"
    #   unless $ok1 =~ /SSH_OK/;

    # mutex_create('client_post_reboot_done');
    # mutex_wait('server_updated');

    # # --- Шаг 20: проверка SSH после перезагрузки системы ---
    # my $ok2 = script_output(
    #     "ssh -i $keyfile -o PasswordAuthentication=no "
    #   . "-o StrictHostKeyChecking=no $test_user\@$server_ip "
    #   . "'echo SSH_OK_AFTER_REBOOT'");
    # die "SSH check failed after system reboot:\n$ok2"
    #   unless $ok2 =~ /SSH_OK_AFTER_REBOOT/;

    # # --- Шаг 23: SSH-сессия после обновления пакета на сервере ---
    # my $ok3 = script_output(
    #     "ssh -i $keyfile -o PasswordAuthentication=no "
    #   . "-o StrictHostKeyChecking=no $test_user\@$server_ip "
    #   . "'echo SSH_OK_AFTER_UPDATE'");
    # die "SSH check failed after package update:\n$ok3"
    #   unless $ok3 =~ /SSH_OK_AFTER_UPDATE/;

    # mutex_create('client_final_checks_done');
}

sub test_flags {
    return {fatal => 1, milestone => 0};
}

1;