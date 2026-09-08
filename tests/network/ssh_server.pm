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

sub run {
    # --- Preconditions ---
    assert_script_run "ip addr add $server_ip/15 dev ens4";
    assert_script_run "ip link set ens4 up";
    assert_script_run "ip route add default via 172.16.2.2 dev ens4";
    assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";

    # barrier_create "net_ready", 2;
    # barrier_create "user_ready", 2;
    mutex_create "net_ready";
    mutex_create "user_ready";

    # barrier_wait "net_ready";
    # mutex_wait "net_ready";
    assert_script_run "ping -c 4 $client_ip";
    
    assert_script_run "useradd -m -s /bin/bash $test_user";
    assert_script_run "echo '$test_user:$test_pass' | chpasswd";
    assert_script_run "chmod 777 /dev/ttyS0";
    # barrier_wait "user_ready";
    # mutex_wait "user_ready";

    # --- Step 1: Install the package ---
    # barrier_create "package_ready", 2;
    mutex_create "package_ready";
    assert_script_run "dnf install -y openssh";

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
    # barrier_wait "package_ready";
    # mutex_wait "package_ready";

    # wait for the client to install the public key (steps 11-13)
    # barrier_create "client_key_installed", 2;
    mutex_create "client_key_installed";
    # barrier_wait "client_key_installed";
    # mutex_wait "client_key_installed";

    # We wait until the client checks the login using the correct/incorrect key (steps 14-15)
    # barrier_create "client_key_checks_done", 2;
    mutex_create "client_key_checks_done";
    # barrier_wait "client_key_checks_done";
    # mutex_wait "client_key_checks_done";

    # # --- Шаг 16: перезапуск службы sshd ---
    # assert_script_run('systemctl restart sshd');
    # assert_script_run('systemctl is-active sshd');
    # mutex_create('server_sshd_restarted');

    # # ждём, пока клиент завершит проверку SSH после рестарта службы (шаг 17)
    # mutex_wait('client_pre_reboot_done');

    # # --- Шаг 18: перезагрузка сервера ---
    # enter_cmd('reboot');
    # $self->wait_boot;
    # select_console('root-console');

    # # --- Шаг 19: служба активна после ребута ---
    # assert_script_run('systemctl is-active sshd');
    # mutex_create('server_rebooted');

    # mutex_wait('client_post_reboot_done');

    # # --- Шаг 21: проверка/установка обновления пакета ---
    # my $update_out = script_output('dnf check-update openssh; true');
    # if ($update_out !~ /no updates|nothing to do/i) {
    #     assert_script_run('dnf update -y openssh', timeout => 300);
    # }

    # # --- Шаг 22: служба активна после обновления ---
    # assert_script_run('systemctl is-active sshd');
    # mutex_create('server_updated');

    # mutex_wait('client_final_checks_done');

    # # --- Шаг 27: проверка логов на ошибки ---
    # my $logs = script_output('journalctl -u sshd --no-pager -n 100');
    # die "sshd logs contain errors:\n$logs"
    #   if $logs =~ /Failed|fatal|error/i;

    # # --- Шаг 28: общее состояние ОС ---
    # assert_script_run('rpm -V openssh');
    # assert_script_run('dnf check');
    # assert_script_run("systemctl --failed | grep '0 loaded units listed'");
    # assert_script_run("getenforce | grep 'Enforcing'");
    # assert_script_run("ss -lntp | grep ':22'");

    # mutex_create('server_done');
}

sub test_flags {
    return {fatal => 1, milestone => 0};
}

1;