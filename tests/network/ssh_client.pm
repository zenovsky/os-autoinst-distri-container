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
use strict;
use warnings;

my $server_ip = get_var('SSH_SERVER_IP', '172.16.2.10');
my $client_ip = get_var('SSH_CLIENT_IP', '172.16.2.11');
my $dns_ip = get_var('DNS_IP');

my $test_user = get_var('SSH_USER', 'ssh_test_user');
my $test_pass = get_var('SSH_USER_PASSWORD', 'TestPassword123!');
my $keyfile   = get_var('SSH_KEY_PATH', '~/.ssh/id_ed25519_test');

sub script_start_io {
    my ($cmd, %args) = @_;

    my $marker = '; echo sioresult-$?-';

    if (is_serial_terminal) {
        wait_serial(serial_terminal::serial_term_prompt(), no_regex => 1,
            quiet => $args{quiet});
    }
    else {
        $cmd .= " >/dev/$serialdev";
        $marker .= " >/dev/$serialdev";
    }

    type_string($cmd . $marker);
    wait_serial($cmd . $marker, no_regex => 1, quiet => $args{quiet})
      if is_serial_terminal;
    type_string("\n");
}

sub script_finish_io {
    my %args = @_;
    my $exit_codes = $args{exitcodes};

    $args{timeout} //= $bmwqemu::default_timeout;

    my $res = wait_serial(qr/sioresult-\d+-/, timeout => $args{timeout},
        quiet => $args{quiet});
    return if !defined($exit_codes) && !defined($res);
    die 'Interactive command failed to exit' unless defined($res);

    $res =~ m/sioresult-(\d+)-/;
    my $ret = $1;
    die "Interactive command returned unexpected value $ret"
      if defined($exit_codes) && !grep { $_ == $ret } @$exit_codes;
    return $ret;
}


sub run {
    # --- Preconditions ---
    assert_script_run "ip addr add $client_ip/15 dev ens4";
    assert_script_run "ip link set ens4 up";
    assert_script_run "ip route add default via 172.16.2.2 dev ens4";
    assert_script_run "echo 'nameserver $dns_ip' > /etc/resolv.conf";

    # barrier_wait "net_ready";
    mutex_wait "net_ready";
    assert_script_run "ping -c 4 $server_ip";
    # barrier_wait "user_ready";
    mutex_wait "user_ready";

    # --- Step 1: Install the package ---
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
    mutex_wait "package_ready";

    # # # --- Step 7: Make sure port 22 is available on the server---
    # assert_script_run "ssh-keyscan -p 22 -T 2 $server_ip 2>&1 | grep -q OpenSSH";

    # --- Steps 8-10: Connecting with a password ---
    # type_string "ssh -o StrictHostKeyChecking=no $test_user\@$server_ip\n";
    # assert_screen 'ssh-password-prompt', 30;
    # type_string "$test_pass\n";
    # wait_still_screen(3);
    # assert_script_run "whoami | grep '$test_user'";
    # assert_script_run "echo \"\$HOME\" | grep '/home/$test_user'";
    # enter_cmd 'exit';

    # --- Steps 8-10: Connecting with a password (интерактивно) ---
    # Запускаем интерактивную SSH-сессию через script для получения псевдотерминала
    script_start_io("script -qe -c 'ssh -o StrictHostKeyChecking=no $test_user\@$server_ip' /dev/null");

    # Ожидаем запрос пароля (можно искать "password:" или "sword:" – зависит от локали)
    die "password prompt did not appear\n" unless wait_serial('sword:', timeout => 30);
    enter_cmd($test_pass);   # отправляем пароль (enter_cmd добавляет \n)

    # Ожидаем приглашение оболочки (обычно заканчивается на $ или #)
    # Можно также ожидать появление имени пользователя в приглашении, но проще дождаться любого промпта
    if (!wait_serial('\\$ ', timeout => 30) && !wait_serial('# ', timeout => 30)) {
        die "Shell prompt did not appear after password\n";
    }

    # Проверяем, что мы залогинились под нужным пользователем (whoami)
    type_string("whoami\n");
    wait_serial($test_user, timeout => 10) or die "whoami didn't return expected user '$test_user'";

    # Проверяем домашний каталог
    type_string("echo \$HOME\n");
    wait_serial("/home/$test_user", timeout => 10) or die "HOME is not '/home/$test_user'";

    # Выходим из SSH-сессии
    type_string("exit\n");

    # Дожидаемся завершения интерактивного процесса
    script_finish_io(timeout => 30, exitcodes => [0]);

    # --- Step 11: Generate a key ---
    assert_script_run "ssh-keygen -t ed25519 -f $keyfile -N ''";
    assert_script_run "ls -l $keyfile $keyfile.pub";

    # --- Steps 12-13: Installing the public key on the server ---
    type_string "ssh-copy-id -i $keyfile.pub $test_user\@$server_ip\n";
    assert_screen 'ssh-password-prompt', 30;
    type_string "$test_pass\n";
    wait_still_screen(3);

    barrier_wait "client_key_installed";
    # mutex_wait "client_key_installed";

    # --- Step 14: Connecting via Public Key ---
    my $key_auth_out = script_output(
        "ssh -i $keyfile -o PasswordAuthentication=no "
      . "-o StrictHostKeyChecking=no $test_user\@$server_ip 'whoami'");
    die "Public key auth failed, expected '$test_user':\n$key_auth_out"
      unless $key_auth_out =~ /^$test_user$/m;

    # --- Step 15: Connection with an invalid key should be rejected ---
    assert_script_run("ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wrong -N ''");
    my $wrong_key_out = script_output(
        "ssh -i ~/.ssh/id_ed25519_wrong -o PasswordAuthentication=no "
      . "-o StrictHostKeyChecking=no $test_user\@$server_ip 2>&1; true");
    die "Expected 'Permission denied' with wrong key, got:\n$wrong_key_out"
      unless $wrong_key_out =~ /Permission denied/;

    barrier_wait "client_key_checks_done";
    # mutex_wait "client_key_checks_done";

    # # ждём, пока сервер перезапустит sshd (шаг 16)
    # mutex_wait('server_sshd_restarted');

    # mutex_create('client_pre_reboot_done');
    # mutex_wait('server_rebooted');

    # # --- Шаг 17: проверка SSH после рестарта службы ---
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