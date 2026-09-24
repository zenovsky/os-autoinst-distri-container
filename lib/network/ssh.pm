package network::ssh;

# Шаги SSH-тестов для openQA (server + client).
#
# Любой параметр можно переопределить именованным аргументом:
#   ssh_precondition_network_client(client_ip => '10.0.0.5', iface => 'ens5');
#   ssh_login_key(command => 'echo SSH_OK', expect => 'SSH_OK');
# Приоритет: аргумент функции > переменная openQA > значение по умолчанию.

use strict;
use warnings;
use Exporter 'import';
use testapi;

our @EXPORT = qw(
  ssh_precondition_network ssh_precondition_network_server ssh_precondition_network_client
  ssh_precondition_user
  ssh_install_package ssh_check_config ssh_start_service ssh_enable_service
  ssh_check_listening ssh_check_firewall ssh_restart_service
  ssh_reboot_and_login ssh_update_package ssh_check_journal ssh_check_os_status
  ssh_check_server_port ssh_login_password ssh_generate_key ssh_copy_key
  ssh_login_key ssh_login_wrong_key_rejected
);

# ---------------------------------------------------------------------------
# Внутренние помощники
# ---------------------------------------------------------------------------

# Конфиг читается при КАЖДОМ вызове (а не при загрузке модуля),
# поэтому get_var видит актуальные переменные, а аргументы функции всё переопределяют.
sub _cfg {
    my (%args) = @_;
    my %cfg = (
        server_ip     => get_var('SSH_SERVER_IP',     '172.16.2.10'),
        client_ip     => get_var('SSH_CLIENT_IP',     '172.16.2.11'),
        dns_ip        => get_var('DNS_IP'),
        gateway       => get_var('SSH_GATEWAY',       '172.16.2.2'),
        iface         => get_var('SSH_IFACE',         'ens4'),
        prefix        => get_var('SSH_PREFIX',        15),
        user          => get_var('SSH_USER',          'ssh_test_user'),
        password      => get_var('SSH_USER_PASSWORD', 'TestPassword123!'),    # только для тестового стенда
        root_password => get_var('ROOT_PASSWORD',     $testapi::password),
        package       => get_var('SSH_PACKAGE',       'openssh'),
        port          => get_var('SSH_PORT',          22),
        key           => '~/.ssh/id_ed25519_test',
        wrong_key     => '~/.ssh/id_ed25519_wrong',
        # имена needle'ов
        needle_login           => 'console-root',
        needle_logged_in       => 'console-root-access',
        needle_password_prompt => 'ssh-password-prompt',
        needle_whoami          => 'whoami-is-test-user',
        needle_home            => 'home-is-test-user-dir',
    );
    return {%cfg, %args};
}

# Обёртка шага: лог начала/успеха, при ошибке - диагностика в UI и повторный die.
# Опция diag => 0 отключает сбор диагностики (для шагов внутри интерактивной ssh-сессии
# или во время перезагрузки, когда консоль не готова выполнять команды).
sub _step {
    my ($title, $code, %opt) = @_;
    diag("[ssh] START: $title");
    my $ok  = eval { $code->(); 1 };
    my $err = $@ || 'unknown error';
    if ($ok) {
        diag("[ssh] OK: $title");
        return 1;
    }
    my $ctx = 'diagnostics disabled for this step';
    if ($opt{diag} // 1) {
        $ctx = eval {
            script_output('ip -br a; ip r; cat /etc/resolv.conf; systemctl status sshd --no-pager -l; journalctl -u sshd --no-pager -n 30',
                timeout => 30, proceed_on_failure => 1);
        } // 'n/a (diagnostics failed)';
    }
    record_info("FAIL: $title", "$err\n\n$ctx", result => 'fail');
    die "[ssh] FAILED: $title: $err";
}

# ---------------------------------------------------------------------------
# Предусловия (server + client)
# ---------------------------------------------------------------------------

# Общая настройка сети: обязателен ip, остальное берётся из конфига.
sub ssh_precondition_network {
    my $c = _cfg(@_);
    die 'ssh_precondition_network: parameter "ip" is required' unless $c->{ip};
    die 'ssh_precondition_network: dns_ip is not set (DNS_IP variable or dns_ip argument)' unless $c->{dns_ip};

    _step "Configure static IP $c->{ip}/$c->{prefix} on $c->{iface}" => sub {
        assert_script_run "nmcli con add type ethernet ifname $c->{iface} con-name $c->{iface}-static "
          . "ipv4.addresses $c->{ip}/$c->{prefix} ipv4.gateway $c->{gateway} "
          . "ipv4.dns $c->{dns_ip} ipv4.method manual";
        assert_script_run "nmcli con up $c->{iface}-static";
    };

    _step 'Set resolv.conf' => sub {
        assert_script_run "echo 'nameserver $c->{dns_ip}' > /etc/resolv.conf";
    };
}

sub ssh_precondition_network_server {
    my %a = @_;
    my $c = _cfg(%a);
    return ssh_precondition_network(ip => $c->{server_ip}, %a);
}

sub ssh_precondition_network_client {
    my %a = @_;
    my $c = _cfg(%a);
    return ssh_precondition_network(ip => $c->{client_ip}, %a);
}

sub ssh_precondition_user {
    my $c = _cfg(@_);
    _step "Create test user $c->{user}" => sub {
        assert_script_run "useradd -m -s /bin/bash $c->{user}";
        assert_script_run "echo '$c->{user}:$c->{password}' | chpasswd";
        assert_script_run 'chmod 777 /dev/ttyS0';
    };
}

# ---------------------------------------------------------------------------
# Проверки пакета и сервиса sshd (общие для server и client)
# ---------------------------------------------------------------------------

sub ssh_install_package {
    my $c = _cfg(@_);
    _step "Install package $c->{package}" => sub {
        assert_script_run "dnf install -y $c->{package}", timeout => 300;
    };
}

sub ssh_check_config {
    my $c = _cfg(@_);
    _step "sshd config: port $c->{port}" => sub {
        assert_script_run "sshd -T | grep 'port $c->{port}'";
    };
}

sub ssh_start_service {
    _step 'Start sshd' => sub {
        assert_script_run 'systemctl start sshd';
        assert_script_run 'systemctl is-active sshd';
    };
}

sub ssh_enable_service {
    _step 'Enable sshd (autostart)' => sub {
        assert_script_run 'systemctl enable --now sshd';
        assert_script_run 'systemctl is-enabled sshd';
    };
}

sub ssh_check_listening {
    my $c = _cfg(@_);
    _step "sshd listens on port $c->{port}" => sub {
        assert_script_run "ss -lntp | grep ':$c->{port}'";
    };
}

sub ssh_check_firewall {
    _step 'firewalld allows ssh' => sub {
        assert_script_run "firewall-cmd --list-services | grep 'ssh'";
    };
}

sub ssh_restart_service {
    _step 'Restart sshd' => sub {
        assert_script_run 'systemctl restart sshd';
        assert_script_run 'systemctl is-active sshd';
    };
}

# ---------------------------------------------------------------------------
# Только server
# ---------------------------------------------------------------------------

sub ssh_reboot_and_login {
    my $c = _cfg(@_);
    _step 'Reboot and log in as root' => sub {
        enter_cmd 'reboot';
        wait_still_screen(15);
        assert_screen $c->{needle_login}, 720;
        type_string 'root';
        send_key 'ret';
        wait_still_screen(3);
        type_password $c->{root_password};
        send_key 'ret';
        assert_screen $c->{needle_logged_in}, 720;
    }, diag => 0;
    _step 'sshd is active after reboot' => sub {
        assert_script_run 'systemctl is-active sshd';
    };
}

# dnf check-update: 0 = обновлений нет, 100 = есть обновления, остальное = ошибка
sub ssh_update_package {
    my $c = _cfg(@_);
    _step "Update $c->{package} if available" => sub {
        my $rc = script_run "dnf check-update $c->{package}", timeout => 300;
        $rc //= -1;
        if ($rc == 100) {
            assert_script_run "dnf update -y $c->{package}", timeout => 300;
        }
        elsif ($rc != 0) {
            die "dnf check-update failed with code $rc";
        }
    };
    _step 'sshd is active after update' => sub {
        assert_script_run 'systemctl is-active sshd';
    };
}

# Ищем только записи уровня error и выше (-p err), иначе ложно срабатывают
# штатные "Failed publickey" от негативного теста с неверным ключом.
# journal_ignore => qr/.../ позволяет исключить известные безобидные строки.
sub ssh_check_journal {
    my $c = _cfg(@_);
    _step 'sshd journal has no errors' => sub {
        my $logs = script_output 'journalctl -u sshd -p err -b --no-pager -n 100', proceed_on_failure => 1;
        my @bad = grep { /\S/ && !/^-- / } split /\n/, $logs;
        @bad = grep { $_ !~ $c->{journal_ignore} } @bad if $c->{journal_ignore};
        die "sshd journal contains errors:\n" . join("\n", @bad) if @bad;
    };
}

sub ssh_check_os_status {
    my $c = _cfg(@_);
    my @checks = (
        "rpm -V $c->{package}",
        'dnf check',
        "getenforce | grep 'Enforcing'",
        "ss -lntp | grep ':$c->{port}'",
        'cat /proc/cmdline',
        "systemctl --failed | grep '0 loaded units listed'",
    );
    for my $cmd (@checks) {
        _step "OS check: $cmd" => sub { assert_script_run $cmd };
    }
}

# ---------------------------------------------------------------------------
# Только client
# ---------------------------------------------------------------------------

sub ssh_check_server_port {
    my $c = _cfg(@_);
    _step "Server $c->{server_ip}:$c->{port} is reachable (OpenSSH banner)" => sub {
        assert_script_run "ssh-keyscan -p $c->{port} -T 2 $c->{server_ip} 2>&1 | grep -q OpenSSH";
    };
}

# Интерактивный вход по паролю + проверка whoami/HOME по needle'ам.
sub ssh_login_password {
    my $c = _cfg(@_);
    _step "SSH password login as $c->{user}\@$c->{server_ip}" => sub {
        enter_cmd "ssh -o StrictHostKeyChecking=no $c->{user}\@$c->{server_ip}";
        assert_screen $c->{needle_password_prompt}, 30;
        type_password $c->{password};
        send_key 'ret';
        wait_still_screen(3);
        enter_cmd 'whoami';
        assert_screen $c->{needle_whoami}, 30;
        enter_cmd 'echo "$HOME"';
        assert_screen $c->{needle_home}, 30;
        enter_cmd 'exit';
    }, diag => 0;
}

sub ssh_generate_key {
    my $c = _cfg(@_);
    _step "Generate ed25519 key $c->{key}" => sub {
        assert_script_run "rm -f $c->{key} $c->{key}.pub";
        assert_script_run "ssh-keygen -t ed25519 -f $c->{key} -N ''";
        assert_script_run "ls -l $c->{key} $c->{key}.pub";
    };
}

sub ssh_copy_key {
    my $c = _cfg(@_);
    _step "ssh-copy-id $c->{key}.pub to $c->{user}\@$c->{server_ip}" => sub {
        enter_cmd "ssh-copy-id -o StrictHostKeyChecking=no -i $c->{key}.pub $c->{user}\@$c->{server_ip}";
        assert_screen $c->{needle_password_prompt}, 30;
        type_password $c->{password};
        send_key 'ret';
        wait_still_screen(3);
    }, diag => 0;
}

# Вход по ключу и выполнение команды на сервере.
#   command => 'echo SSH_OK'   (по умолчанию whoami)
#   expect  => 'SSH_OK'        (необязательно: проверить наличие строки в выводе)
sub ssh_login_key {
    my $c   = _cfg(@_);
    my $cmd = $c->{command} // 'whoami';
    my $ssh = "ssh -i $c->{key} -o PasswordAuthentication=no -o BatchMode=yes -o StrictHostKeyChecking=no "
      . "$c->{user}\@$c->{server_ip} '$cmd'";
    _step "SSH key login, command: $cmd" => sub {
        if (defined $c->{expect}) {
            my $out = script_output $ssh;
            die "Expected '$c->{expect}' in output, got: $out" unless $out =~ /\Q$c->{expect}\E/;
        }
        else {
            assert_script_run $ssh;
        }
    };
}

# Негативный тест: чужой ключ должен быть отклонён.
sub ssh_login_wrong_key_rejected {
    my $c = _cfg(@_);
    _step 'Login with wrong key is rejected' => sub {
        assert_script_run "rm -f $c->{wrong_key} $c->{wrong_key}.pub";
        assert_script_run "ssh-keygen -t ed25519 -f $c->{wrong_key} -N ''";
        assert_script_run "ssh -i $c->{wrong_key} -o PasswordAuthentication=no -o BatchMode=yes "
          . "-o StrictHostKeyChecking=no $c->{user}\@$c->{server_ip} 2>&1 | grep -i 'Permission denied'";
    };
}

1;